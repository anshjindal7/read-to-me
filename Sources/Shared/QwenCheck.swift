// Cross-checks Apple Vision's reading of a photo against Qwen's transcription of the same photo.
//
// Two independent readers rarely make the same mistake, so wherever they disagree we look closer.
// Qwen is never allowed to rewrite the book; it can only:
//   • fix a word — when Apple's word is misspelled, Qwen's is a real word, and they look alike
//   • flag a scrap line — when Qwen left the line out AND it sits apart from the body text
//     at the top or bottom of the page, or outside the text column

import AppKit

/// One word of Apple's text, remembering which line it came from.
private struct VisionWord {
    let page: Int
    let line: Int
    let index: Int      // position of the word within its line
    let key: String     // lowercased letters and digits, used for matching
}

/// Lowercased letters and digits only, so "Hello," and “hello” match.
private func matchKey(_ word: Substring) -> String {
    String(word.lowercased().filter { $0.isLetter || $0.isNumber })
}

/// Splits "“Hello,”" into ("“", "Hello", ",”") so a fix can keep the original punctuation.
private func splitPunctuation(_ word: String) -> (lead: String, core: String, trail: String) {
    let chars = Array(word)
    guard let first = chars.firstIndex(where: { $0.isLetter || $0.isNumber }),
          let last = chars.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return ("", word, "") }
    return (String(chars[..<first]), String(chars[first...last]), String(chars[(last + 1)...]))
}

private func isMisspelled(_ word: String) -> Bool {
    let hasLetters = word.contains(where: \.isLetter)
    if hasLetters, word.contains(where: \.isNumber) { return true }  // "1ighthouse", "c0at"
    guard hasLetters else { return false }
    return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location != NSNotFound
}

/// 0...1 — how alike two words are, by edit distance.
private func similarity(_ a: String, _ b: String) -> Double {
    let a = Array(a), b = Array(b)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var row = Array(0...b.count)
    for i in 1...a.count {
        var previous = row[0]
        row[0] = i
        for j in 1...b.count {
            let current = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
            previous = current
        }
    }
    return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
}

/// Longest common subsequence: pairs of (visionIndex, qwenIndex) for words both readers agree on.
private func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
    guard !a.isEmpty, !b.isEmpty else { return [] }
    var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
    }
    var pairs: [(Int, Int)] = []
    var i = 0, j = 0
    while i < a.count, j < b.count {
        if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
        else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
        else { j += 1 }
    }
    return pairs
}

/// `pages` are the pages Vision found in one photo (two for a spread); `transcription` is Qwen's text for that photo.
func applyQwenCheck(to pages: [[OCRLine]], transcription: String, report: inout CleanupReport) -> [[OCRLine]] {
    var pages = pages

    // Every word from both readers, in reading order.
    var visionWords: [VisionWord] = []
    for (p, page) in pages.enumerated() {
        for (l, line) in page.enumerated() {
            for (w, word) in line.text.split(separator: " ").enumerated() {
                let key = matchKey(word)
                if !key.isEmpty { visionWords.append(VisionWord(page: p, line: l, index: w, key: key)) }
            }
        }
    }
    let qwenWords = transcription.split(whereSeparator: \.isWhitespace).filter { !matchKey($0).isEmpty }
    let pairs = align(visionWords.map(\.key), qwenWords.map { matchKey($0) })

    // 1. Fix words. Between two agreed words, a same-length run of disagreements is a set of
    //    one-for-one swaps ("weatbered" ↔ "weathered").
    var fixes: [(VisionWord, String)] = []
    let anchors = [(-1, -1)] + pairs + [(visionWords.count, qwenWords.count)]
    for (start, end) in zip(anchors, anchors.dropFirst()) {
        let visionGap = (start.0 + 1)..<end.0
        let qwenGap = (start.1 + 1)..<end.1
        guard !visionGap.isEmpty, visionGap.count == qwenGap.count, visionGap.count <= 3 else { continue }
        for (v, q) in zip(visionGap, qwenGap) {
            let visionWord = visionWords[v]
            let line = pages[visionWord.page][visionWord.line]
            let original = String(line.text.split(separator: " ")[visionWord.index])
            let replacement = splitPunctuation(String(qwenWords[q])).core
            let core = splitPunctuation(original).core
            if isMisspelled(core), !isMisspelled(replacement), similarity(core.lowercased(), replacement.lowercased()) >= 0.6 {
                fixes.append((visionWord, replacement))
            }
        }
    }
    for (word, replacement) in fixes {
        var parts = pages[word.page][word.line].text.split(separator: " ").map(String.init)
        let (lead, core, trail) = splitPunctuation(parts[word.index])
        parts[word.index] = lead + replacement + trail
        pages[word.page][word.line].text = parts.joined(separator: " ")
        report.fixedWords.append((core, replacement))
    }

    // 2. Drop scrap lines: Qwen skipped (almost) all of it, and its position marks it as not body text.
    var matchedPerLine: [String: Int] = [:], totalPerLine: [String: Int] = [:]
    let matched = Set(pairs.map(\.0))
    for (i, word) in visionWords.enumerated() {
        let id = "\(word.page)-\(word.line)"
        totalPerLine[id, default: 0] += 1
        if matched.contains(i) { matchedPerLine[id, default: 0] += 1 }
    }
    for p in pages.indices {
        let layout = PageLayout(pages[p])
        let edgeLines = Set([0, 1, pages[p].count - 2, pages[p].count - 1].filter { $0 >= 0 })
        var drop = IndexSet()
        for l in edgeLines where l < pages[p].count {
            let id = "\(p)-\(l)"
            let coverage = Double(matchedPerLine[id] ?? 0) / Double(max(totalPerLine[id] ?? 0, 1))
            let line = pages[p][l]
            let apart = layout.gapToBody(pages[p], at: l) > layout.bigGap || layout.isOutsideColumn(line)
            if coverage < 0.34, apart, !layout.isBigType(line) || isPageNumber(line.text) {
                drop.insert(l)
            }
        }
        for l in drop.reversed() {
            report.removedLines.append(pages[p].remove(at: l).text)
        }
    }
    return pages
}
