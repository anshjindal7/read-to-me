// photo2audiobook — the command-line version of Read To Me. Same pipeline as the app.
//
// Usage:
//   photo2audiobook <folder-of-photos> [options]
//
// Options:
//   --voice NAME     a Qwen voice (ryan, aiden, serena, vivian) or a Mac voice ("Samantha")
//   --style TEXT     how a Qwen voice should read, e.g. "Slow and soothing"
//   --rate WPM       speed for Mac voices (default 180)
//   --no-qwen-check  skip Qwen's double-check of the pages (faster)
//   --out FILE       where to save the audiobook (default: <folder>/<folder>.m4b)

import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let qwenVoiceIDs = Set(Qwen.voices.map(\.id))
let voice = option("--voice") ?? (Qwen.isInstalled ? "ryan" : "Samantha")
let style = option("--style") ?? Qwen.defaultStyle
let rate = Int(option("--rate") ?? "180") ?? 180
let outOption = option("--out")
let qwenCheck = Qwen.isInstalled && !flag("--no-qwen-check")

guard let folderPath = args.first else {
    print("Usage: photo2audiobook <folder-of-photos> [--voice ryan] [--style \"...\"] [--rate 180] [--no-qwen-check] [--out book.m4b]")
    exit(1)
}
if qwenVoiceIDs.contains(voice), !Qwen.isInstalled {
    print("Qwen isn't set up yet. Run scripts/setup_qwen.sh first, or pick a Mac voice with --voice Samantha.")
    exit(1)
}

let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
let photos = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
guard !photos.isEmpty else {
    print("No photos found in \(folder.path)")
    exit(1)
}
print("Found \(photos.count) photo(s).")

do {
    // 1. Read the pages.
    var qwenTexts: [String]?
    if qwenCheck {
        print("Qwen is reading the pages (about 15 s each)...")
        qwenTexts = try await Qwen.transcribe(photos) { done, total in print("  \(done)/\(total)") }
    }
    print("Reading the pages with Apple Vision...")
    let (text, report) = cleanUpBook(photos.map(recognizePages(in:)), qwenTexts: qwenTexts)
    guard !text.isEmpty else {
        print("No readable text found in any photo.")
        exit(1)
    }
    print("Skipped \(report.removedLines.count) header/footer line(s): \(report.removedLines)")
    if !report.fixedWords.isEmpty {
        print("Fixed misread words: " + report.fixedWords.map { "\($0.from) → \($0.to)" }.joined(separator: ", "))
    }

    // Save the text so it can be checked or fixed by hand.
    let bookName = folder.lastPathComponent
    let textURL = folder.appendingPathComponent("\(bookName).txt")
    try text.write(to: textURL, atomically: true, encoding: .utf8)
    print("Saved text to \(textURL.path)")

    // 2. Record it.
    let output = outOption.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? folder.appendingPathComponent("\(bookName).m4b")
    print("Recording with \(voice)...")
    if qwenVoiceIDs.contains(voice) {
        try await Qwen.speak(text, voice: voice, style: style, to: output) { done, total in
            print("  \(done * 100 / max(total, 1))%")
        }
    } else {
        try await MacVoice.record(text, voice: voice, rate: rate, to: output)
    }
    print("Done! Audiobook saved to \(output.path)")
} catch {
    print(error.localizedDescription)
    exit(1)
}
