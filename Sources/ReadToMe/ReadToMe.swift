// Read To Me — a Mac app that turns photos of book pages into an audiobook (.m4b).
// Text is read with Apple's Vision framework and spoken with the built-in Mac voices,
// so everything runs on this Mac for free.

import SwiftUI
import AppKit
import Vision
import ImageIO
import UniformTypeIdentifiers

// MARK: - App

@main
struct ReadToMeApp: App {
    @StateObject private var model = BookModel()

    var body: some Scene {
        WindowGroup("Read To Me") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Model

enum Stage: Equatable {
    case idle
    case reading(done: Int, total: Int)
    case recording
    case finished(URL)
    case failed(String)
}

@MainActor
final class BookModel: ObservableObject {
    @Published var photos: [URL] = []
    @Published var text = ""
    @Published var stage: Stage = .idle
    @Published var voices: [String] = []
    @Published var voice = "Samantha"
    @Published var rate: Double = 180

    private var previewProcess: Process?
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    init() { loadVoices() }

    var isBusy: Bool {
        switch stage {
        case .reading, .recording: return true
        default: return false
        }
    }

    // Photos

    func add(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                found += contents.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            } else if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        let all = Set(photos).union(found)
        photos = all.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if case .finished = stage { stage = .idle }
    }

    func remove(_ url: URL) { photos.removeAll { $0 == url } }

    func reset() {
        photos = []
        text = ""
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

    // Step 1: read the text

    func readPages() {
        let pages = photos
        stage = .reading(done: 0, total: pages.count)
        Task {
            var texts: [String] = []
            for (i, url) in pages.enumerated() {
                let pageText = await Task.detached { cleanUp(recognizeLines(in: url)) }.value
                if !pageText.isEmpty { texts.append(pageText) }
                stage = .reading(done: i + 1, total: pages.count)
            }
            text = texts.joined(separator: "\n\n")
            stage = text.isEmpty ? .failed("No readable text was found in these photos. Try clearer, well-lit shots.") : .idle
        }
    }

    // Step 2: record the audiobook

    func createAudiobook() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .audio]
        panel.nameFieldStringValue = "My Audiobook.m4b"
        panel.message = "Where should the audiobook be saved?"
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        stopPreview()
        stage = .recording
        let text = self.text, voice = self.voice, rate = Int(self.rate)
        Task {
            do {
                let textURL = FileManager.default.temporaryDirectory.appendingPathComponent("ReadToMe-\(UUID().uuidString).txt")
                try text.write(to: textURL, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: textURL) }
                try? FileManager.default.removeItem(at: outURL)
                let status = await runSay(["-v", voice, "-r", "\(rate)", "-f", textURL.path,
                                           "-o", outURL.path, "--file-format=m4bf", "--data-format=aac"])
                stage = status == 0 ? .finished(outURL) : .failed("Recording failed. Try a different voice.")
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    // Voices

    func loadVoices() {
        let output = runSayCapturingOutput(["-v", "?"])
        // Joke/old voices that don't suit reading a book.
        let skip: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Fred",
                                 "Good News", "Jester", "Junior", "Kathy", "Organ", "Ralph", "Superstar",
                                 "Trinoids", "Whisper", "Wobble", "Zarvox"]
        var names: [String] = []
        for line in output.split(separator: "\n") {
            guard let hash = line.range(of: "#") else { continue }
            let parts = line[..<hash.lowerBound].split(separator: " ", omittingEmptySubsequences: true)
            guard let locale = parts.last, locale.hasPrefix("en_") else { continue }
            let name = parts.dropLast().joined(separator: " ")
            if !skip.contains(name) { names.append(name) }
        }
        func rank(_ name: String) -> Int {
            if name.contains("Premium") { return 0 }
            if name.contains("Enhanced") { return 1 }
            if name == "Samantha" { return 2 }
            return 3
        }
        voices = names.sorted { (rank($0), $0) < (rank($1), $1) }
        if !voices.contains(voice), let first = voices.first { voice = first }
    }

    func preview() {
        stopPreview()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-r", "\(Int(rate))",
                             "Hi! This is how I'll sound reading your book in the car."]
        try? process.run()
        previewProcess = process
    }

    func stopPreview() {
        previewProcess?.terminate()
        previewProcess = nil
    }
}

// MARK: - Text recognition

func recognizeLines(in url: URL) -> [String] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
    // Respect the photo's rotation so sideways phone shots still read correctly.
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = CGImagePropertyOrientation(rawValue: props?[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

/// Joins OCR lines into flowing prose: drops page numbers and re-joins hyphenated words.
func cleanUp(_ lines: [String]) -> String {
    var text = ""
    for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.allSatisfy({ $0.isNumber }) { continue }
        if text.hasSuffix("-"), let first = line.first, first.isLowercase {
            text.removeLast()
            text += line
        } else {
            text += text.isEmpty ? line : " " + line
        }
    }
    return text
}

// MARK: - `say` helpers

func runSay(_ arguments: [String]) async -> Int32 {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = arguments
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(returning: -1) }
    }
}

func runSayCapturingOutput(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                StepView(number: 1, title: "Add photos of your pages") { PhotosStep() }
                if !model.text.isEmpty {
                    StepView(number: 2, title: "Check the text") { TextStep() }
                    StepView(number: 3, title: "Pick a voice and make the audiobook") { VoiceStep() }
                }
                StatusView()
            }
            .padding(28)
        }
        .disabled(model.isBusy)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "headphones")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Read To Me").font(.largeTitle.bold())
                Text("Turn photos of your book into an audiobook for the car.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StepView<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.orange))
                Text(title).font(.title3.weight(.semibold))
            }
            content
        }
    }
}

struct PhotosStep: View {
    @EnvironmentObject var model: BookModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if model.photos.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Drop page photos or a folder here").font(.headline)
                        Text("Pages are read in filename order — take them in order on your phone.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Choose Photos…") { model.choosePhotos() }.controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(model.photos.enumerated()), id: \.element) { index, url in
                                PageThumbnail(url: url, page: index + 1)
                                    .contextMenu { Button("Remove Page") { model.remove(url) } }
                            }
                        }
                        .padding(12)
                    }
                    .frame(minHeight: 200)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .foregroundStyle(isTargeted ? Color.orange : Color.secondary.opacity(0.4))
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.add([url]) } }
                    }
                }
                return true
            }

            if !model.photos.isEmpty {
                HStack {
                    Text("\(model.photos.count) page\(model.photos.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Add More…") { model.choosePhotos() }
                    Button("Start Over") { model.reset() }
                    Spacer()
                    Button(model.text.isEmpty ? "Read Pages" : "Read Pages Again") { model.readPages() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.large)
                }
            }
        }
    }
}

struct PageThumbnail: View {
    let url: URL
    let page: Int
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(width: 110, height: 145)
            .shadow(radius: 2, y: 1)
            Text("Page \(page)").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: url) {
            image = await Task.detached { thumbnail(for: url) }.value
        }
    }
}

func thumbnail(for url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 300,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

struct TextStep: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fix any words the camera misread — this is exactly what will be spoken.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.text)
                .font(.system(size: 14, design: .serif))
                .lineSpacing(4)
                .padding(8)
                .frame(minHeight: 200, maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            let words = model.text.split(whereSeparator: \.isWhitespace).count
            Text("\(words) words · about \(max(1, Int((Double(words) / model.rate).rounded()))) min of audio")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct VoiceStep: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Voice", selection: $model.voice) {
                    ForEach(model.voices, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 320)
                Button { model.preview() } label: { Label("Preview", systemImage: "play.circle") }
                Button { model.loadVoices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload voices after downloading new ones")
            }
            HStack {
                Text("Speed")
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: $model.rate, in: 120...280, step: 10).frame(maxWidth: 260)
                Image(systemName: "hare").foregroundStyle(.secondary)
            }
            if !model.voices.contains(where: { $0.contains("Premium") || $0.contains("Enhanced") }) {
                Text("Tip: for a much more natural voice, download a free “Premium” voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, then click ↻.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { model.createAudiobook() } label: {
                    Label("Create Audiobook", systemImage: "waveform").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            }
        }
    }
}

struct StatusView: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        switch model.stage {
        case .idle:
            EmptyView()
        case let .reading(done, total):
            VStack(alignment: .leading) {
                Text("Reading page \(min(done + 1, total)) of \(total)…")
                ProgressView(value: Double(done), total: Double(total)).tint(.orange)
            }
        case .recording:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Recording your audiobook… long books can take a few minutes.")
            }
        case let .finished(url):
            VStack(alignment: .leading, spacing: 10) {
                Label("Your audiobook is ready!", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("AirDrop it to your iPhone — it opens in Apple Books and plays in the car.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Play") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("AirDrop to iPhone…") { airDrop(url) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.1)))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func airDrop(_ url: URL) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
    }
}
