import AppKit
import Foundation
import SubtitleCore

struct LogLine: Identifiable {
    let id = UUID()
    let time: Date
    let level: LogLevel
    let text: String
}

/// Shown as a sheet when a file has several audio tracks.
struct TrackRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let streams: [AudioStream]
    let suggested: AudioStream
}

struct Job: Identifiable {
    enum Status: Equatable {
        case waiting
        case running
        case done(URL)
        case failed(String)
        case cancelled
    }
    let id = UUID()
    let url: URL
    var status: Status = .waiting
}

/// Queue of dropped files, processed one at a time.
@MainActor
final class JobQueue: ObservableObject {
    static let shared = JobQueue()

    @Published var jobs: [Job] = []
    @Published var log: [LogLine] = []
    @Published var progress: Double = 0
    @Published var step: String = "Drop a video file to start."
    @Published private(set) var isRunning = false
    @Published var apiKey: String? = APIKeyStore.load()
    @Published private(set) var trackRequest: TrackRequest?
    private var trackContinuation: CheckedContinuation<AudioStream?, Never>?

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "m4v", "mov", "avi", "webm", "wmv", "flv", "ts", "m2ts", "mts",
        "mpg", "mpeg", "vob", "3gp", "ogv", "divx",
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "wma", "mka", "ac3",
    ]

    private var worker: Task<Void, Never>?
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private lazy var logFile: FileHandle? = {
        let fm = FileManager.default
        try? fm.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
        let url = AppPaths.logs.appendingPathComponent("EnglishSubtitleMaker.log")
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()

    // MARK: Adding files

    func add(_ urls: [URL]) {
        var added = 0
        for url in expand(urls) {
            guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else {
                append(.warning, "Skipped \(url.lastPathComponent): not a video/audio file.")
                continue
            }
            if jobs.contains(where: { $0.url == url && ($0.status == .waiting || $0.status == .running) }) { continue }
            jobs.append(Job(url: url))
            added += 1
        }
        if added > 0 { startIfPossible() }
    }

    /// A dropped folder adds the videos directly inside it.
    private func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])) ?? []
            return items.filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }

    func clearFinished() {
        jobs.removeAll { if case .waiting = $0.status { return false }; if case .running = $0.status { return false }; return true }
    }

    // MARK: API key

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try APIKeyStore.save(trimmed)
            apiKey = trimmed
            append(.info, "API key saved. Checking it with Groq…")
            if !trimmed.hasPrefix("gsk_") {
                append(.warning, "Groq keys normally start with \"gsk_\". Double-check you copied the whole key.")
            }
            Task {
                if let err = await GroqClient(apiKey: trimmed, model: Groq.defaultModel, log: { _, _ in }).verifyKey() {
                    append(.error, err.description)
                    append(.detail, "→ \(err.code.hint)")
                } else {
                    append(.success, "Groq accepted the key.")
                    startIfPossible()
                }
            }
        } catch {
            append(.error, "Could not save the key: \(error.localizedDescription)")
        }
    }

    func removeKey() {
        APIKeyStore.delete()
        apiKey = nil
        append(.info, "API key removed.")
    }

    // MARK: Running

    func startIfPossible() {
        guard !isRunning, jobs.contains(where: { $0.status == .waiting }) else { return }
        guard apiKey != nil else {
            append(.error, "\(ErrorCode.apiKeyMissing.rawValue) \(ErrorCode.apiKeyMissing.title)")
            append(.detail, "→ \(ErrorCode.apiKeyMissing.hint) Files will start once the key is saved.")
            return
        }
        isRunning = true
        worker = Task { await runQueue() }
    }

    func cancel() {
        worker?.cancel()
        answerTrack(nil)
    }

    // MARK: Audio track choice

    func askForTrack(file: String, streams: [AudioStream], suggested: AudioStream) async -> AudioStream? {
        step = "Waiting for you to choose an audio track…"
        return await withCheckedContinuation { continuation in
            trackContinuation = continuation
            trackRequest = TrackRequest(fileName: file, streams: streams, suggested: suggested)
        }
    }

    /// nil cancels the job.
    func answerTrack(_ stream: AudioStream?) {
        trackRequest = nil
        let continuation = trackContinuation
        trackContinuation = nil
        continuation?.resume(returning: stream)
    }

    private func runQueue() async {
        defer {
            isRunning = false
            worker = nil
        }
        while let index = jobs.firstIndex(where: { $0.status == .waiting }) {
            if Task.isCancelled {
                for i in jobs.indices where jobs[i].status == .waiting { jobs[i].status = .cancelled }
                break
            }
            let job = jobs[index]
            jobs[index].status = .running
            progress = 0
            append(.info, "▶︎ \(job.url.lastPathComponent)")
            let status = await process(job.url)
            if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].status = status }
        }
        if !Task.isCancelled { step = "Finished. Drop more files any time." }
    }

    private func process(_ url: URL) async -> Job.Status {
        guard let ffmpeg = AppPaths.findFFmpeg() else {
            report(SubtitleError(.ffmpegMissing))
            return .failed(ErrorCode.ffmpegMissing.rawValue)
        }
        let started = Date()
        let pipeline = Pipeline(
            input: url, ffmpeg: ffmpeg, settings: .current(), apiKey: apiKey,
            log: { level, text in Task { @MainActor in JobQueue.shared.append(level, text) } },
            progress: { value, step in Task { @MainActor in JobQueue.shared.setProgress(value, step) } },
            chooseTrack: { streams, suggested in
                await JobQueue.shared.askForTrack(file: url.lastPathComponent, streams: streams, suggested: suggested)
            })
        do {
            let srt = try await pipeline.run()
            progress = 1
            let mins = Int(Date().timeIntervalSince(started) / 60)
            let secs = Int(Date().timeIntervalSince(started)) % 60
            append(.success, "✓ Saved \(srt.lastPathComponent) in \(mins) min \(secs) s. Open the video in VLC and the subtitles load automatically.")
            step = "Done: \(srt.lastPathComponent)"
            return .done(srt)
        } catch is CancellationError {
            report(SubtitleError(.cancelled))
            step = "Cancelled."
            return .cancelled
        } catch let error as SubtitleError {
            report(error)
            step = "Failed: \(error.code.rawValue) \(error.code.title)"
            return .failed(error.code.rawValue)
        } catch {
            report(SubtitleError(.unexpected, error.localizedDescription))
            step = "Failed: \(ErrorCode.unexpected.rawValue)"
            return .failed(ErrorCode.unexpected.rawValue)
        }
    }

    private func report(_ error: SubtitleError) {
        append(error.code == .cancelled ? .warning : .error, "✗ \(error.description)")
        append(.detail, "→ \(error.code.hint)")
    }

    // MARK: Log & progress

    func setProgress(_ value: Double, _ step: String) {
        guard isRunning else { return }
        progress = max(progress, value)
        if !step.isEmpty { self.step = step }
    }

    func append(_ level: LogLevel, _ text: String) {
        let line = LogLine(time: Date(), level: level, text: text)
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
        if let data = "\(timeFormatter.string(from: line.time)) \(text)\n".data(using: .utf8) {
            logFile?.write(data)
        }
    }

    func logText() -> String {
        log.map { "\(timeFormatter.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
    }

    func formattedTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    func clearResumeCache() {
        guard !isRunning else {
            append(.warning, "Stop the current job before clearing saved progress.")
            return
        }
        try? FileManager.default.removeItem(at: AppPaths.cache)
        append(.info, "Saved progress of unfinished jobs cleared.")
    }
}
