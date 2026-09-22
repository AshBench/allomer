import Darwin
import Foundation

enum ExternalTool {
    @discardableResult
    static func run(_ executable: URL, arguments: [String], workDirectory: URL,
                    currentDirectory: URL? = nil, timeout: TimeInterval = 120,
                    captureOutput: Bool = false, outputFile: URL? = nil,
                    outputLimit: Int = 1_048_576, workDirectoryByteLimit: Int? = nil) throws -> Data {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, outputLimit > 0, outputLimit < Int.max,
              workDirectoryByteLimit.map({ $0 > 0 }) ?? true,
              !(captureOutput && outputFile != nil) else {
            throw ConversionError.message("The converter timeout and output settings are invalid.")
        }
        let log = workDirectory.appendingPathComponent("tool-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw ConversionError.message("The converter log could not be created.")
        }
        let errors = try FileHandle(forWritingTo: log)
        let capture = outputFile ?? workDirectory.appendingPathComponent("stdout-\(UUID().uuidString).log")
        var capturedOutput: FileHandle?
        defer {
            try? errors.close()
            try? capturedOutput?.close()
            try? FileManager.default.removeItem(at: log)
            if captureOutput, outputFile == nil {
                try? FileManager.default.removeItem(at: capture)
            }
        }
        if captureOutput || outputFile != nil {
            let descriptor = open(capture.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            capturedOutput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory ?? workDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = capturedOutput ?? FileHandle.nullDevice
        process.standardError = errors
        process.qualityOfService = .utility
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = workDirectory.path
        if executable.path == "/usr/bin/file" { environment["MAGIC"] = "/usr/share/file/magic" }
        if executable.lastPathComponent == "ffmpeg", arguments.contains("libsvtav1") {
            environment["SVT_LOG"] = "1"
            environment.removeValue(forKey: "SVT_LOG_FILE")
        }
        process.environment = environment
        func directoryLimitExceeded() -> Bool {
            guard let limit = workDirectoryByteLimit else { return false }
            let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: Array(keys)) else {
                return true
            }
            var total = 0
            for file in files {
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      let size = values.fileSize, size >= 0, size <= limit - total else { return true }
                total += size
            }
            return false
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let deadline = DispatchTime.now() + timeout
        var stopReason: String?
        while finished.wait(timeout: min(deadline, .now() + 0.25)) == .timedOut {
            let size = (try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let outputSize = (try? capture.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if Task.isCancelled {
                stopReason = "Conversion cancelled."
            } else if DispatchTime.now() >= deadline {
                stopReason = "The converter exceeded its time limit."
            } else if size > 1_048_576 || outputSize > outputLimit {
                stopReason = "The converter exceeded its output size limit."
            } else if directoryLimitExceeded() {
                stopReason = "The generated files exceed their size limit or could not be checked."
            }
            if stopReason != nil {
                if process.isRunning {
                    process.terminate()
                    if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit()
                break
            }
        }
        try Task.checkCancellation()
        if let stopReason { throw ConversionError.message(stopReason) }
        guard !directoryLimitExceeded() else {
            throw ConversionError.message("The generated files exceed their size limit or could not be checked.")
        }
        guard ((try? capture.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= outputLimit else {
            throw ConversionError.message("The converter exceeded its output size limit.")
        }
        // FFmpeg can report damaged input while still exiting successfully. Ignore only the
        // unrelated VideoToolbox driver lookup printed by macOS 14.
        var logLevel: String?
        for (flag, value) in zip(arguments, arguments.dropFirst()) where flag == "-v" || flag == "-loglevel" {
            logLevel = value
        }
        var reportedError = false
        if ["ffmpeg", "ffprobe"].contains(executable.lastPathComponent),
           ["error", "fatal", "panic"].contains(logLevel ?? "") {
            let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
            reportedError = text.split(whereSeparator: \Character.isNewline).contains { line in
                let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !message.isEmpty && !(message.hasPrefix("IOServiceMatchingfailed for: Apple")
                    && message.hasSuffix("ScalerCSCDriver"))
            }
        }
        guard process.terminationStatus == 0, !reportedError else {
            let reader = try FileHandle(forReadingFrom: log)
            defer { try? reader.close() }
            let end = try reader.seekToEnd()
            try reader.seek(toOffset: end > 8192 ? end - 8192 : 0)
            let detail = String(decoding: try reader.read(upToCount: 8192) ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = reportedError ? "reported an error" : "failed (\(process.terminationStatus))"
            throw ConversionError.message("\(executable.lastPathComponent) \(reason). \(detail)")
        }
        guard captureOutput else { return Data() }
        let reader = try FileHandle(forReadingFrom: capture)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: outputLimit + 1) ?? Data()
        guard data.count <= outputLimit else {
            throw ConversionError.message("The converter result exceeds the diagnostic limit.")
        }
        return data
    }
}
