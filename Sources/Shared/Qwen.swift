// Runs the Qwen models. They live in Python (MLX), so Swift starts `readtome_ai.py` as a separate
// process and reads its output line by line:
//   PROGRESS <done> <total>   → progress bar
//   RESULT <json>             → a page transcription
//
// Everything is installed by scripts/setup_qwen.sh into ~/Library/Application Support/ReadToMe:
//   venv/              Python environment with mlx-vlm (page reading) and mlx-audio (voice)
//   readtome_ai.py     the helper script
// The models themselves (~8 GB) are cached by Hugging Face in ~/.cache/huggingface.

import Foundation

enum Qwen {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ReadToMe")
    static let python = supportDir.appendingPathComponent("venv/bin/python")
    static let helper = supportDir.appendingPathComponent("readtome_ai.py")

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: helper.path)
    }

    /// Qwen3-TTS's built-in speakers that sound good reading English.
    static let voices: [(id: String, label: String)] = [
        ("ryan", "Ryan — Qwen, natural"),
        ("aiden", "Aiden — Qwen, natural"),
        ("serena", "Serena — Qwen, natural"),
        ("vivian", "Vivian — Qwen, natural"),
    ]
    static let defaultStyle = "Warm, calm audiobook narration."

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Qwen3-VL's transcription of each photo, in the same order.
    static func transcribe(_ photos: [URL], progress: @escaping (Int, Int) -> Void) async throws -> [String] {
        let job = FileManager.default.temporaryDirectory.appendingPathComponent("readtome-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: photos.map(\.path)).write(to: job)
        defer { try? FileManager.default.removeItem(at: job) }

        var texts = Array(repeating: "", count: photos.count)
        try await run(["transcribe", job.path], progress: progress) { json in
            if let result = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let index = result["photo"] as? Int, let text = result["text"] as? String, index < texts.count {
                texts[index] = text
            }
        }
        return texts
    }

    /// Narrates `text` into an .m4b audiobook with Qwen3-TTS.
    static func speak(_ text: String, voice: String, style: String, to output: URL,
                      progress: @escaping (Int, Int) -> Void) async throws {
        let textFile = FileManager.default.temporaryDirectory.appendingPathComponent("readtome-\(UUID().uuidString).txt")
        try text.write(to: textFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: textFile) }
        try? FileManager.default.removeItem(at: output)
        try await run(["speak", textFile.path, output.path, "--voice", voice, "--style", style], progress: progress) { _ in }
    }

    /// Starts the helper and feeds its PROGRESS / RESULT lines to the callbacks as they arrive.
    private static func run(_ arguments: [String], progress: @escaping (Int, Int) -> Void,
                            result: @escaping (String) -> Void) async throws {
        guard isInstalled else { throw Failure(message: "Qwen isn't set up yet. Run scripts/setup_qwen.sh first.") }
        let process = Process()
        process.executableURL = python
        process.arguments = [helper.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["HF_HUB_DISABLE_XET"] = "1"  // plain downloads; more reliable on flaky connections
        process.environment = environment

        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // Collect stderr in the background so a chatty library can't fill the pipe and stall Python.
        let errorLog = LogBuffer()
        errors.fileHandleForReading.readabilityHandler = { errorLog.append($0.availableData) }

        try process.run()
        for try await line in output.fileHandleForReading.bytes.lines {
            if line.hasPrefix("PROGRESS ") {
                let numbers = line.split(separator: " ").dropFirst().compactMap { Int($0) }
                if numbers.count == 2 { progress(numbers[0], numbers[1]) }
            } else if line.hasPrefix("RESULT ") {
                result(String(line.dropFirst("RESULT ".count)))
            }
        }
        process.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            let lastLines = errorLog.text.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw Failure(message: "Qwen stopped with an error:\n\(lastLines)")
        }
    }
}

/// Thread-safe text buffer for a process's error output.
private final class LogBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
