// The built-in macOS voices, through the `say` command. Instant and always available —
// the fallback when Qwen isn't set up.

import Foundation

enum MacVoice {
    /// English voices installed on this Mac, best first (Premium, then Enhanced, then the rest).
    static func installed() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        // Joke and very old voices that don't suit reading a book.
        let skip: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Fred",
                                 "Good News", "Jester", "Junior", "Kathy", "Organ", "Ralph", "Superstar",
                                 "Trinoids", "Whisper", "Wobble", "Zarvox"]
        var names: [String] = []
        // Each line looks like: "Samantha            en_US    # Hello! My name is Samantha."
        for line in output.split(separator: "\n") {
            guard let hash = line.range(of: "#") else { continue }
            let parts = line[..<hash.lowerBound].split(separator: " ")
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
        return names.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// Records `text` into an .m4b audiobook. `rate` is words per minute.
    static func record(_ text: String, voice: String, rate: Int, to output: URL) async throws {
        let textFile = FileManager.default.temporaryDirectory.appendingPathComponent("readtome-\(UUID().uuidString).txt")
        try text.write(to: textFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: textFile) }
        try? FileManager.default.removeItem(at: output)

        let status = await runSay(["-v", voice, "-r", "\(rate)", "-f", textFile.path,
                                   "-o", output.path, "--file-format=m4bf", "--data-format=aac"])
        if status != 0 { throw Qwen.Failure(message: "The Mac voice couldn't record. Try a different voice.") }
    }

    /// Speaks a short sample out loud. Returns the process so it can be stopped.
    static func preview(_ text: String, voice: String, rate: Int) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-r", "\(rate)", text]
        try? process.run()
        return process
    }

    private static func runSay(_ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }
}
