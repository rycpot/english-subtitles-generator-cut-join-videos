import Foundation

struct ProcessResult {
    let status: Int32
    let stderrLines: [String]

    var stderrTail: String {
        stderrLines.suffix(8).joined(separator: "\n")
    }
}

/// Runs a command-line tool, streaming its stdout/stderr line by line.
/// Cancelling the Swift task terminates the process.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String],
                    onStdoutLine: ((String) -> Void)? = nil,
                    onStderrLine: ((String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = LineCollector()
        let group = DispatchGroup()

        func attach(_ pipe: Pipe, isStderr: Bool) {
            group.enter()
            let splitter = LineSplitter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if let rest = splitter.finish() {
                        collector.emit(rest, isStderr: isStderr, onStdout: onStdoutLine, onStderr: onStderrLine)
                    }
                    group.leave()
                    return
                }
                for line in splitter.feed(chunk) {
                    collector.emit(line, isStderr: isStderr, onStdout: onStdoutLine, onStderr: onStderrLine)
                }
            }
        }
        attach(outPipe, isStderr: false)
        attach(errPipe, isStderr: true)

        group.enter()
        process.terminationHandler = { _ in group.leave() }

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                group.notify(queue: .global()) {
                    cont.resume(returning: ProcessResult(status: process.terminationStatus,
                                                         stderrLines: collector.stderrLines))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // A cancelled process exits with a signal; report that as cancellation.
        try Task.checkCancellation()
        return result
    }
}

/// Accumulates bytes and hands back complete lines. ffmpeg ends some status
/// lines with \r, so both \r and \n end a line.
private final class LineSplitter {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            if !lineData.isEmpty { lines.append(String(decoding: lineData, as: UTF8.self)) }
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        return lines
    }

    func finish() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer = Data() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Thread-safe store of stderr lines (bounded) and dispatch of callbacks.
private final class LineCollector {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 20_000

    var stderrLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func emit(_ line: String, isStderr: Bool,
              onStdout: ((String) -> Void)?, onStderr: ((String) -> Void)?) {
        if isStderr {
            lock.lock()
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
            lock.unlock()
            onStderr?(line)
        } else {
            onStdout?(line)
        }
    }
}
