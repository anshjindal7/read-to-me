// The window: three numbered steps (photos → text → voice) and a status area at the bottom.

import SwiftUI
import AppKit
import ImageIO

struct ContentView: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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

// MARK: - Step 1: photos

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
                QwenCheckToggle()
                HStack {
                    Text("\(model.photos.count) photo\(model.photos.count == 1 ? "" : "s")").foregroundStyle(.secondary)
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

struct QwenCheckToggle: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        if model.qwenInstalled {
            Toggle(isOn: $model.useQwenCheck) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Double-check with Qwen")
                    Text("Fixes misread words and catches leftover headers. About 15 seconds per page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
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
            Text("Photo \(page)").font(.caption).foregroundStyle(.secondary)
        }
        .task(id: url) {
            image = await Task.detached { thumbnail(for: url) }.value
        }
    }
}

private func thumbnail(for url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 300,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

// MARK: - Step 2: text

struct TextStep: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fix anything that looks wrong — this is exactly what will be read aloud.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.text)
                .font(.system(size: 14, design: .serif))
                .lineSpacing(4)
                .padding(8)
                .frame(minHeight: 220, maxHeight: 340)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            Text(lengthSummary).font(.caption).foregroundStyle(.secondary)
            CleanupSummary()
        }
    }

    private var lengthSummary: String {
        let words = model.text.split(whereSeparator: \.isWhitespace).count
        let minutes = max(1, words / 150)
        return "\(words) words · about \(minutes) min of audio"
    }
}

/// Shows what the cleanup removed and fixed, so nothing changes behind your back.
struct CleanupSummary: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        let removed = model.report.removedLines, fixed = model.report.fixedWords
        if !removed.isEmpty || !fixed.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(removed.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "minus.circle").foregroundStyle(.secondary)
                    }
                    ForEach(Array(fixed.enumerated()), id: \.offset) { _, fix in
                        Label("\(fix.from) → \(fix.to)", systemImage: "wand.and.stars").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text("Skipped \(removed.count) header/footer line\(removed.count == 1 ? "" : "s")"
                     + (fixed.isEmpty ? "" : " · fixed \(fixed.count) misread word\(fixed.count == 1 ? "" : "s")"))
                    .font(.callout)
            }
        }
    }
}

// MARK: - Step 3: voice

struct VoiceStep: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.qwenInstalled { QwenSetupCard() }

            HStack {
                Picker("Voice", selection: $model.voiceID) {
                    let qwen = model.voices.filter(\.isQwen), mac = model.voices.filter { !$0.isQwen }
                    if !qwen.isEmpty {
                        Section("Natural voices (Qwen)") { ForEach(qwen) { Text($0.label).tag($0.id) } }
                    }
                    Section("Mac voices") { ForEach(mac) { Text($0.label).tag($0.id) } }
                }
                .frame(maxWidth: 340)
                Button { model.preview() } label: {
                    if model.isPreparingPreview { ProgressView().controlSize(.small) }
                    else { Label("Preview", systemImage: "play.circle") }
                }
                .disabled(model.isPreparingPreview)
                Button { model.loadVoices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload voices after downloading new ones")
            }

            if model.voice?.isQwen == true {
                HStack {
                    Text("Style")
                    TextField("How should it sound?", text: $model.style)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 380)
                }
                Text("Describe the reading, e.g. “Slow and soothing” or “Lively, with feeling for the characters.”")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Speed")
                    Image(systemName: "tortoise").foregroundStyle(.secondary)
                    Slider(value: $model.rate, in: 120...280, step: 10).frame(maxWidth: 260)
                    Image(systemName: "hare").foregroundStyle(.secondary)
                }
            }

            HStack {
                if model.voice?.isQwen == true {
                    Text(qwenTimeEstimate).font(.caption).foregroundStyle(.secondary)
                }
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

    /// Qwen records at roughly twice real time on Apple Silicon.
    private var qwenTimeEstimate: String {
        let audioMinutes = Double(model.text.split(whereSeparator: \.isWhitespace).count) / 140  // Qwen reads ~140 wpm
        let minutes = max(1, Int((audioMinutes / 2).rounded()))
        return minutes < 90 ? "Recording takes about \(minutes) min" : "Recording takes about \(minutes / 60) h"
    }
}

struct QwenSetupCard: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Get natural voices with Qwen").font(.headline)
                Text("Free and private — runs entirely on this Mac. Also double-checks pages for misread words. One-time download of about 8 GB.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set Up Qwen") { model.setUpQwen() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - Status

struct StatusView: View {
    @EnvironmentObject var model: BookModel

    var body: some View {
        switch model.stage {
        case .idle:
            EmptyView()
        case let .settingUp(step):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Setting up Qwen: \(step) This can take a while the first time.")
            }
        case let .reading(what, done, total):
            VStack(alignment: .leading) {
                Text("\(what)… \(min(done + 1, total)) of \(total)")
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(.orange)
            }
        case let .recording(done, total):
            VStack(alignment: .leading) {
                if total > 0 {
                    Text("Recording your audiobook… \(Int(Double(done) / Double(total) * 100))%")
                    ProgressView(value: Double(done), total: Double(total)).tint(.orange)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Recording your audiobook… long books can take a few minutes.")
                    }
                }
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
                    Button("AirDrop to iPhone…") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url]) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.1)))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
