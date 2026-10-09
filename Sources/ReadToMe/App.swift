// Read To Me — the Mac app. This file holds the app's state and the actions behind each button;
// Views.swift draws the window. The real work lives in Sources/Shared:
//   PageText.swift   photos → clean text (Apple Vision + rules)
//   QwenCheck.swift  cross-checks that text against Qwen's reading of the photos
//   Qwen.swift       runs the Qwen models (page reading and natural voices)
//   MacVoice.swift   the built-in Mac voices

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ReadToMeApp: App {
    @StateObject private var model = BookModel()

    var body: some Scene {
        WindowGroup("Read To Me") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
    }
}

/// A narrator: either a Qwen voice or a built-in Mac voice.
struct Voice: Hashable, Identifiable {
    let id: String
    let label: String
    let isQwen: Bool
}

enum Stage: Equatable {
    case idle
    case settingUp(String)
    case reading(String, done: Int, total: Int)
    case recording(done: Int, total: Int)  // total 0 = no progress available (Mac voices)
    case finished(URL)
    case failed(String)
}

@MainActor
final class BookModel: ObservableObject {
    @Published var photos: [URL] = []
    @Published var text = ""
    @Published var report = CleanupReport()
    @Published var stage: Stage = .idle

    @Published var qwenInstalled = Qwen.isInstalled
    @Published var useQwenCheck = Qwen.isInstalled
    @Published var voices: [Voice] = []
    @Published var voiceID = ""
    @Published var rate: Double = 180          // Mac voices: words per minute
    @Published var style = Qwen.defaultStyle   // Qwen voices: how to read
    @Published var isPreparingPreview = false

    private var previewProcess: Process?
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    init() {
        refreshHelper()
        loadVoices()
    }

    var voice: Voice? { voices.first { $0.id == voiceID } }

    var isBusy: Bool {
        switch stage {
        case .settingUp, .reading, .recording: return true
        default: return false
        }
    }

    // MARK: Photos

    func add(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                found += contents.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            } else if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        // Filename order = the order the phone took them in.
        photos = Set(photos).union(found).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        if case .finished = stage { stage = .idle }
    }

    func remove(_ url: URL) { photos.removeAll { $0 == url } }

    func reset() {
        photos = []
        text = ""
        report = CleanupReport()
        stage = .idle
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        panel.message = "Choose photos of your book pages (or a folder of them)"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    // MARK: Step 1 — read the pages

    func readPages() {
        let photos = self.photos
        let withQwen = useQwenCheck && qwenInstalled
        Task {
            let activity = keepAwake("Reading book pages")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                // Qwen first (slow, ~15 s a page), then Apple Vision (fast).
                var qwenTexts: [String]?
                if withQwen {
                    stage = .reading("Qwen is reading the pages", done: 0, total: photos.count)
                    qwenTexts = try await Qwen.transcribe(photos) { done, total in
                        Task { @MainActor in self.stage = .reading("Qwen is reading the pages", done: done, total: total) }
                    }
                }
                var photoPages: [[[OCRLine]]] = []
                for (i, url) in photos.enumerated() {
                    stage = .reading("Reading the pages", done: i, total: photos.count)
                    photoPages.append(await Task.detached { recognizePages(in: url) }.value)
                }
                let result = cleanUpBook(photoPages, qwenTexts: qwenTexts)
                text = result.text
                report = result.report
                stage = text.isEmpty ? .failed("No readable text was found in these photos. Try clearer, well-lit shots.") : .idle
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Step 2 — record the audiobook

    func createAudiobook() {
        guard let voice else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .audio]
        panel.nameFieldStringValue = "My Audiobook.m4b"
        panel.message = "Where should the audiobook be saved?"
        guard panel.runModal() == .OK, let output = panel.url else { return }

        stopPreview()
        let text = self.text, style = self.style, rate = Int(self.rate)
        stage = .recording(done: 0, total: 0)
        Task {
            let activity = keepAwake("Recording an audiobook")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                if voice.isQwen {
                    try await Qwen.speak(text, voice: voice.id, style: style, to: output) { done, total in
                        Task { @MainActor in self.stage = .recording(done: done, total: total) }
                    }
                } else {
                    try await MacVoice.record(text, voice: voice.id, rate: rate, to: output)
                }
                stage = .finished(output)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Voices

    func loadVoices() {
        qwenInstalled = Qwen.isInstalled
        let qwen = qwenInstalled ? Qwen.voices.map { Voice(id: $0.id, label: $0.label, isQwen: true) } : []
        let mac = MacVoice.installed().map { Voice(id: $0, label: $0, isQwen: false) }
        voices = qwen + mac
        if voice == nil { voiceID = voices.first?.id ?? "" }
    }

    func preview() {
        guard let voice else { return }
        stopPreview()
        let sample = "Hi! This is how I'll sound reading your book in the car."
        if !voice.isQwen {
            previewProcess = MacVoice.preview(sample, voice: voice.id, rate: Int(rate))
            return
        }
        // Qwen needs a few seconds to load and generate, then we play the result.
        isPreparingPreview = true
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("readtome-preview.m4b")
        let style = self.style
        Task {
            defer { isPreparingPreview = false }
            do {
                try await Qwen.speak(sample, voice: voice.id, style: style, to: file) { _, _ in }
                let player = Process()
                player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                player.arguments = [file.path]
                try player.run()
                previewProcess = player
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func stopPreview() {
        previewProcess?.terminate()
        previewProcess = nil
    }

    // MARK: Qwen setup

    /// Runs scripts/setup_qwen.sh (bundled in the app) and shows its STEP lines as progress.
    func setUpQwen() {
        guard let script = Bundle.main.url(forResource: "setup_qwen", withExtension: "sh") else {
            stage = .failed("Setup script missing from the app. Rebuild with ./build.sh.")
            return
        }
        stage = .settingUp("Starting setup")
        Task {
            let activity = keepAwake("Downloading Qwen models")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var lastError = "Setup failed."
            do {
                try process.run()
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if line.hasPrefix("STEP ") { stage = .settingUp(String(line.dropFirst(5)) + "…") }
                    if line.hasPrefix("ERROR: ") { lastError = String(line.dropFirst(7)) }
                }
                process.waitUntilExit()
            } catch {
                lastError = error.localizedDescription
            }
            loadVoices()
            if qwenInstalled, process.terminationStatus == 0 {
                useQwenCheck = true
                voiceID = Qwen.voices[0].id
                stage = .idle
            } else {
                stage = .failed(lastError)
            }
        }
    }

    /// Keeps the helper in Application Support in step with the one bundled in this build of the app.
    private func refreshHelper() {
        guard Qwen.isInstalled, let bundled = Bundle.main.url(forResource: "readtome_ai", withExtension: "py") else { return }
        try? FileManager.default.removeItem(at: Qwen.helper)
        try? FileManager.default.copyItem(at: bundled, to: Qwen.helper)
    }

    /// Stops the Mac from sleeping mid-book (screen can still turn off).
    private func keepAwake(_ reason: String) -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }
}
