// Step 1 of the pipeline: photos → clean, narration-ready text.
//
//   recognizePages        Apple Vision finds every line of text and where it sits on the page.
//   applyQwenCheck        (optional, QwenCheck.swift) Qwen's transcription fixes misread words
//                         and points out scrap lines.
//   stripHeadersAndFooters  Rules drop running headers, footers and page numbers.
//   paragraphs(of:)       Lines become paragraphs; chapter headings get their own pause.
//   assembleBook          Pages are joined, mending sentences that run across a page turn.
//   cleanUpBook           Runs all of the above in order.

import Foundation
import Vision
import ImageIO

/// One line of text found on a page. `box` is in Vision's normalized coordinates:
/// 0...1 across the photo, with the origin at the bottom-left.
struct OCRLine {
    var text: String
    var box: CGRect
}

/// What the cleanup changed, so the app can show it and you can double-check.
struct CleanupReport {
    var removedLines: [String] = []
    var fixedWords: [(from: String, to: String)] = []
}

// MARK: - Recognition

/// Reads a photo and returns its pages (two for a two-page spread), each as lines from top to bottom.
func recognizePages(in url: URL) -> [[OCRLine]] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
    // Respect the photo's rotation so sideways phone shots still read correctly.
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = CGImagePropertyOrientation(rawValue: props?[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])

    let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
        guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        return OCRLine(text: text, box: observation.boundingBox)
    }
    return splitSpread(lines).map { $0.sorted { $0.box.midY > $1.box.midY } }.filter { !$0.isEmpty }
}

/// If the photo shows two facing pages, returns the left page then the right page.
private func splitSpread(_ lines: [OCRLine]) -> [[OCRLine]] {
    guard lines.count >= 8 else { return [lines] }
    var best: (gutter: CGFloat, crossing: Int)?
    for step in 35...65 {
        let gutter = CGFloat(step) / 100
        let left = lines.filter { $0.box.maxX <= gutter }.count
        let right = lines.filter { $0.box.minX >= gutter }.count
        let crossing = lines.count - left - right
        if left >= 3, right >= 3, best == nil || crossing < best!.crossing {
            best = (gutter, crossing)
        }
    }
    guard let best, Double(best.crossing) <= Double(lines.count) * 0.1 else { return [lines] }
    return [lines.filter { $0.box.midX < best.gutter }, lines.filter { $0.box.midX >= best.gutter }]
}

// MARK: - Page measurements

private func median(_ values: [CGFloat]) -> CGFloat {
    guard !values.isEmpty else { return 0 }
    return values.sorted()[values.count / 2]
}

/// Average width of one character — tracks font size far better than box height,
/// which jumps around with tall letters and descenders ("H", "g").
func letterWidth(_ line: OCRLine) -> CGFloat {
    line.box.width / CGFloat(max(line.text.count, 1))
}

/// Typical measurements of a page's body text. Anything that differs a lot from these
/// (bigger type, a wide gap, sitting outside the text column) is a heading or scrap.
struct PageLayout {
    let lineHeight: CGFloat
    let lineGap: CGFloat       // normal space between two lines of a paragraph
    let bodyLetter: CGFloat    // normal letter width = body font size
    let lineWidth: CGFloat     // a full line of body text
    let leftEdge: CGFloat
    let rightEdge: CGFloat

    init(_ lines: [OCRLine]) {
        let gaps = zip(lines, lines.dropFirst()).map { $0.box.minY - $1.box.maxY }
        lineHeight = median(lines.map(\.box.height))
        lineGap = median(gaps.filter { $0 > 0 })
        bodyLetter = median(lines.filter { $0.text.count > 20 }.map(letterWidth))
        lineWidth = median(lines.map(\.box.width))
        leftEdge = median(lines.map(\.box.minX))
        rightEdge = median(lines.map(\.box.maxX))
    }

    /// A gap clearly bigger than normal line spacing — what separates a header from the body.
    var bigGap: CGFloat { max(lineGap * 2, lineGap + lineHeight * 0.8) }

    func isBigType(_ line: OCRLine) -> Bool { letterWidth(line) > bodyLetter * 1.35 }

    /// Space between line `i` and its neighbour toward the middle of the page.
    func gapToBody(_ lines: [OCRLine], at i: Int) -> CGFloat {
        if i == 0, lines.count > 1 { return lines[0].box.minY - lines[1].box.maxY }
        if i == lines.count - 1, i > 0 { return lines[i - 1].box.minY - lines[i].box.maxY }
        return 0
    }

    /// Stray text from the facing page or the table sits outside the column of body text.
    func isOutsideColumn(_ line: OCRLine) -> Bool {
        line.box.maxX < leftEdge + lineWidth * 0.1 || line.box.minX > rightEdge - lineWidth * 0.1
    }
}

// MARK: - Headers, footers and page numbers

func isPageNumber(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).lowercased()
    if t.isEmpty { return true }
    if t.allSatisfy(\.isNumber) { return true }
    if t.count <= 6, t.allSatisfy({ "ivxlcdm".contains($0) }) { return true }  // roman numerals
    if t.hasPrefix("page "), t.dropFirst(5).allSatisfy(\.isNumber) { return true }
    return false
}

/// Letters only, lowercased — so "12  THE SILENT FOREST" and "The Silent Forest 13" match.
private func headerKey(_ text: String) -> String {
    String(text.lowercased().filter(\.isLetter))
}

/// Removes running headers, footers and page numbers from every page.
func stripHeadersAndFooters(_ pages: [[OCRLine]], report: inout CleanupReport) -> [[OCRLine]] {
    // Text that shows up at the top or bottom of more than one page is a running header/footer.
    var counts: [String: Int] = [:]
    for page in pages {
        let edgeLines = Array(page.prefix(2)) + Array(page.suffix(2))
        for key in Set(edgeLines.map { headerKey($0.text) }) where key.count >= 3 {
            counts[key, default: 0] += 1
        }
    }
    let recurring = Set(counts.filter { $0.value >= 2 }.keys)

    return pages.map { page in
        var lines = page
        let layout = PageLayout(page)

        func isEdgeJunk(_ index: Int) -> Bool {
            let line = lines[index]
            if isPageNumber(line.text) { return true }
            if layout.isBigType(line) { return false }  // bigger type = a real heading, keep it
            if recurring.contains(headerKey(line.text)) { return true }
            guard layout.gapToBody(lines, at: index) > layout.bigGap else { return false }
            let hasNumber = line.text.split(separator: " ").contains { isPageNumber(String($0)) }
            let letters = line.text.filter(\.isLetter)
            let allCaps = !letters.isEmpty && letters == letters.uppercased()
            return hasNumber || allCaps || letterWidth(line) < layout.bodyLetter * 0.9
        }

        for _ in 0..<2 {  // a header can be two lines, e.g. title + page number
            guard lines.count > 1, isEdgeJunk(0) else { break }
            report.removedLines.append(lines.removeFirst().text)
        }
        for _ in 0..<2 {
            guard lines.count > 1, isEdgeJunk(lines.count - 1) else { break }
            report.removedLines.append(lines.removeLast().text)
        }
        if lines.count == 1, isPageNumber(lines[0].text) {
            report.removedLines.append(lines.removeFirst().text)
        }
        return lines
    }
}

// MARK: - Paragraphs

private let sentenceEnders: Set<Character> = [".", "!", "?", "\"", "”", "’", "'", ":", ";", "…", ")"]

/// Adds `line` to `text`, re-joining words hyphenated across a line break ("won-" + "derful").
private func append(_ line: String, to text: inout String) {
    if text.hasSuffix("-"), let first = line.first, first.isLowercase {
        text.removeLast()
        text += line
    } else {
        text += text.isEmpty ? line : " " + line
    }
}

/// Groups a page's lines into paragraphs. Headings become their own paragraph ending in a period,
/// so the narrator pauses after "Chapter One" instead of running it into the next sentence.
func paragraphs(of lines: [OCRLine]) -> [String] {
    guard !lines.isEmpty else { return [] }
    let layout = PageLayout(lines)

    var result: [String] = []
    var current = ""
    func finish() {
        if !current.isEmpty { result.append(current) }
        current = ""
    }

    for (i, line) in lines.enumerated() {
        let next = i + 1 < lines.count ? lines[i + 1] : nil
        let endsSentence = line.text.last.map(sentenceEnders.contains) ?? false
        let isHeading = (line.text.count < 60 && layout.isBigType(line))
            || (next != nil && line.box.width < layout.lineWidth * 0.6 && line.text.count < 50 && !endsSentence
                && line.box.minY - next!.box.maxY > max(layout.lineGap * 2, layout.lineHeight))

        if isHeading {
            finish()
            result.append(endsSentence ? line.text : line.text + ".")
            continue
        }

        // A line indented past the left margin starts a new paragraph.
        if line.box.minX > layout.leftEdge + layout.lineWidth * 0.03 { finish() }
        append(line.text, to: &current)

        // A short line ending a sentence closes its paragraph.
        if line.box.width < layout.lineWidth * 0.8, endsSentence { finish() }
    }
    finish()
    return result
}

/// Joins pages into one text with blank lines between paragraphs. A sentence cut off at the
/// bottom of one page is joined to its ending on the next page.
func assembleBook(_ pages: [[String]]) -> String {
    var paragraphs: [String] = []
    for page in pages {
        for (i, paragraph) in page.enumerated() {
            if i == 0, var previous = paragraphs.last,
               let last = previous.last, !sentenceEnders.contains(last) {
                append(paragraph, to: &previous)
                paragraphs[paragraphs.count - 1] = previous
            } else {
                paragraphs.append(paragraph)
            }
        }
    }
    return paragraphs.joined(separator: "\n\n")
}

// MARK: - The whole pipeline

/// Recognized pages in, narration-ready text out. `photoPages` holds recognizePages' result for
/// each photo. Pass `qwenTexts` (one transcription per photo, from Qwen.transcribe) to also fix
/// misread words and catch scrap lines the rules miss. Uses the spellchecker, so call it on the main thread.
func cleanUpBook(_ photoPages: [[[OCRLine]]], qwenTexts: [String]? = nil) -> (text: String, report: CleanupReport) {
    var report = CleanupReport()
    var pages: [[OCRLine]] = []
    for (i, var photo) in photoPages.enumerated() {
        if let qwenTexts, i < qwenTexts.count, !qwenTexts[i].isEmpty {
            photo = applyQwenCheck(to: photo, transcription: qwenTexts[i], report: &report)
        }
        pages += photo
    }
    let clean = stripHeadersAndFooters(pages, report: &report)
    return (assembleBook(clean.map(paragraphs(of:))), report)
}
