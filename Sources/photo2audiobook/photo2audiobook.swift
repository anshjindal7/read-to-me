// photo2audiobook — turn photos of book pages into an audiobook (.m4b).
//
// Usage:
//   ./photo2audiobook <folder-of-photos> [--voice "Samantha"] [--rate 180] [--out book.m4b]
//
// Photos are read in filename order (IMG_0001, IMG_0002, ...), so take them in page order.
// Everything runs on this Mac for free: Apple's Vision framework reads the text,
// and the built-in `say` voices speak it.

import Foundation
import Vision
import ImageIO

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
let voice = option("--voice")
let rate = option("--rate") ?? "180"
let outOption = option("--out")

guard let folderPath = args.first else {
    print("Usage: ./photo2audiobook <folder-of-photos> [--voice \"Samantha\"] [--rate 180] [--out book.m4b]")
    exit(1)
}
let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)

// MARK: - Find photos

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

guard !files.isEmpty else {
    print("No photos found in \(folder.path)")
    exit(1)
}
print("Found \(files.count) page photo(s).")

// MARK: - Read text from each photo

func recognizeLines(in url: URL) -> [String] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("  ! Could not open \(url.lastPathComponent)")
        return []
    }
    // Respect the photo's rotation so sideways phone shots still read correctly.
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let rawOrientation = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do {
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
    } catch {
        print("  ! Text recognition failed for \(url.lastPathComponent): \(error.localizedDescription)")
        return []
    }
    // Vision returns lines in reading order (top to bottom).
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

/// Joins OCR lines into flowing prose: drops page numbers and re-joins hyphenated words.
func cleanUp(_ lines: [String]) -> String {
    var text = ""
    for raw in lines {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.allSatisfy({ $0.isNumber }) { continue }  // page numbers
        if text.hasSuffix("-"), let first = line.first, first.isLowercase {
            text.removeLast()  // "won-" + "derful" -> "wonderful"
            text += line
        } else {
            text += text.isEmpty ? line : " " + line
        }
    }
    return text
}

var pages: [String] = []
for (i, file) in files.enumerated() {
    print("Reading page \(i + 1)/\(files.count): \(file.lastPathComponent)")
    let pageText = cleanUp(recognizeLines(in: file))
    if pageText.isEmpty { print("  ! No text found on this page") }
    pages.append(pageText)
}
let fullText = pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
guard !fullText.isEmpty else {
    print("No readable text found in any photo.")
    exit(1)
}

// Save the text so it can be checked or fixed by hand.
let bookName = folder.lastPathComponent
let textURL = folder.appendingPathComponent("\(bookName).txt")
try fullText.write(to: textURL, atomically: true, encoding: .utf8)
print("Saved text to \(textURL.path)")

// MARK: - Speak it into an audiobook file

let outURL = outOption.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? folder.appendingPathComponent("\(bookName).m4b")
print("Recording audio (this takes a little while for long books)...")

let say = Process()
say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
var sayArgs = ["-r", rate, "-f", textURL.path, "-o", outURL.path, "--file-format=m4bf", "--data-format=aac"]
if let voice { sayArgs += ["-v", voice] }
say.arguments = sayArgs
try say.run()
say.waitUntilExit()

guard say.terminationStatus == 0 else {
    print("Audio recording failed. If you passed --voice, check the name with: say -v '?'")
    exit(1)
}
print("Done! Audiobook saved to \(outURL.path)")
