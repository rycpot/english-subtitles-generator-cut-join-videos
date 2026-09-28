import CryptoKit
import Foundation
import SubtitleCore

/// Saved in the work folder so an interrupted job can resume without
/// re-extracting audio or re-uploading finished parts.
struct ChunkPlan: Codable {
    struct Part: Codable {
        let file: String
        let start: Double
        let end: Double
        /// No sound worth sending (checked with the loudness pass).
        var silent = false
    }
    var version = 2
    var mimeType: String
    var duration: Double
    var track: String
    var parts: [Part]
}

/// Turns one video file into `<name>.srt`:
/// probe → extract mono 16 kHz audio → measure loudness → split into ≤30 s
/// parts at quiet moments → Groq translates each part to English → build and save the SRT.
final class Pipeline {
    /// Groq's free tier allows 20 requests a minute; stay just under it.
    static let minSecondsBetweenRequests: Double = 3.1
    /// Parts whose loudest moment is quieter than this are not uploaded.
    static let silenceThresholdDB: Double = -50

    let input: URL
    let ffmpeg: URL
    let settings: PipelineSettings
    let apiKey: String?
    let log: (LogLevel, String) -> Void
    let progress: (Double, String) -> Void
    /// Asks the user which audio track to use when there are several.
    /// Gets all tracks and the suggested one; returns nil to cancel.
    let chooseTrack: (([AudioStream], AudioStream) async -> AudioStream?)?

    init(input: URL, ffmpeg: URL, settings: PipelineSettings, apiKey: String?,
         log: @escaping (LogLevel, String) -> Void,
         progress: @escaping (Double, String) -> Void,
         chooseTrack: (([AudioStream], AudioStream) async -> AudioStream?)? = nil) {
        self.input = input
        self.ffmpeg = ffmpeg
        self.settings = settings
        self.apiKey = apiKey
        self.log = log
        self.progress = progress
        self.chooseTrack = chooseTrack
    }

    var outputURL: URL {
        input.deletingPathExtension().appendingPathExtension("srt")
    }

    /// Runs the whole job. With `prepareOnly`, stops after splitting the audio
    /// (used by the `--selftest` mode) and returns the work folder.
    @discardableResult
    func run(prepareOnly: Bool = false) async throws -> URL {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: input.path) else {
            throw SubtitleError(.inputUnreadable, input.path)
        }
        let info = try await probe()
        guard var track = info.preferredAudioStream() else { throw SubtitleError(.noAudioTrack) }
        if info.audioStreams.count > 1 {
            if let chooseTrack {
                guard let picked = await chooseTrack(info.audioStreams, track) else { throw CancellationError() }
                log(.info, "Using audio \(picked.summary)" + (picked == track ? "." : " (your choice)."))
                track = picked
            } else {
                log(.info, "Using audio \(track.summary) (first non-English track).")
            }
        }
        let workDir = try workFolder(track: track)
        let plan: ChunkPlan
        if let saved = loadPlan(in: workDir) {
            let done = saved.parts.indices.filter { fm.fileExists(atPath: resultURL(workDir, $0).path) }.count
            log(.info, "Resuming earlier job: \(done) of \(saved.parts.count) parts already done.")
            plan = saved
        } else {
            plan = try await prepare(workDir: workDir, info: info, track: track)
        }
        if prepareOnly { return workDir }

        guard let apiKey, !apiKey.isEmpty else { throw SubtitleError(.apiKeyMissing) }
        let progress = self.progress
        let client = GroqClient(apiKey: apiKey, log: log, status: { progress(0, $0) })

        var results: [ChunkResult] = []
        var previousText: String?
        var lastRequest: Date?
        let total = plan.parts.count
        for (i, part) in plan.parts.enumerated() {
            try Task.checkCancellation()
            let label = "Part \(i + 1)/\(total) (\(Self.clock(part.start))–\(Self.clock(part.end)))"
            if part.silent {
                previousText = nil
                continue
            }
            let resultFile = resultURL(workDir, i)
            var response: GroqVerboseResponse?
            if let data = try? Data(contentsOf: resultFile) {
                response = try? JSONDecoder().decode(GroqVerboseResponse.self, from: data)
            }
            if response == nil {
                progress(0.30 + 0.68 * Double(i) / Double(total),
                         "Translating part \(i + 1) of \(total) (\(Self.clock(part.start)))…")
                let file = workDir.appendingPathComponent(part.file)
                // Waits so requests stay under Groq's per-minute limit.
                func request(prompt: String?) async throws -> (Data, GroqVerboseResponse) {
                    if let lastRequest {
                        let wait = Self.minSecondsBetweenRequests - Date().timeIntervalSince(lastRequest)
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    }
                    lastRequest = Date()
                    let data = try await client.translateAudio(file: file, mimeType: plan.mimeType,
                                                               model: settings.model, prompt: prompt)
                    do {
                        return (data, try JSONDecoder().decode(GroqVerboseResponse.self, from: data))
                    } catch {
                        throw SubtitleError(.badResponse, String(decoding: data.prefix(300), as: UTF8.self))
                    }
                }
                var (data, reply) = try await request(prompt: previousText)
                // Whisper sometimes mistakes the language of a short part and
                // answers in Chinese, Japanese etc. Ask once more with an
                // English-only hint and no context from earlier parts.
                let ratio = Self.foreignRatio(reply)
                if ratio > 0.3 {
                    let (retryData, retry) = try await request(prompt: Self.englishHint)
                    let retryRatio = Self.foreignRatio(retry)
                    log(.detail, "\(label): came back \(Int(ratio * 100))% non-English; asked again → \(Int(retryRatio * 100))%.")
                    if retryRatio < ratio { (data, reply) = (retryData, retry) }
                }
                response = reply
                try? data.write(to: resultFile, options: .atomic)
            }
            let segments = response?.segments ?? []
            let lines = segments.compactMap(SubtitleBuilder.subtitleText)
            log(.detail, "\(label): \(lines.count) line\(lines.count == 1 ? "" : "s")"
                + (lines.count < segments.count ? " (\(segments.count - lines.count) left out)" : "")
                + ": \(lines.joined(separator: " / ").prefix(90))")
            // Give the next part the last English lines as context for names and
            // style (never foreign text, which would pull Whisper off course).
            let tail = lines.suffix(2).joined(separator: " ")
            previousText = tail.count < 10 ? nil : String(tail.suffix(300))
            results.append(ChunkResult(offset: part.start, length: part.end - part.start, segments: segments))
        }
        let silentCount = plan.parts.filter(\.silent).count
        log(.info, "Processed \(total - silentCount) parts" + (silentCount > 0 ? ", skipped \(silentCount) silent" : "") + ".")

        progress(0.99, "Writing subtitles…")
        let cues = SubtitleBuilder.buildCues(from: results)
        guard !cues.isEmpty else { throw SubtitleError(.noSpeech) }
        if fm.fileExists(atPath: outputURL.path) {
            let backup = outputURL.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            if (try? fm.moveItem(at: outputURL, to: backup)) != nil {
                log(.info, "Existing \(outputURL.lastPathComponent) kept as \(backup.lastPathComponent).")
            }
        }
        do {
            try SubtitleBuilder.srt(from: cues).write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            throw SubtitleError(.writeFailed, "\(outputURL.path): \(error.localizedDescription)")
        }
        log(.detail, "\(cues.count) subtitle lines written.")
        try? fm.removeItem(at: workDir)
        return outputURL
    }

    // MARK: - Preparation

    /// Reads the file's length and audio tracks.
    private func probe() async throws -> MediaInfo {
        progress(0.01, "Reading file…")
        let probe = try await runFFmpeg(["-hide_banner", "-nostdin", "-i", input.path])
        let info = FFmpegOutput.parseMediaInfo(probe.stderrLines.joined(separator: "\n"))
        if info.audioStreams.isEmpty {
            if info.duration == nil {
                log(.detail, probe.stderrTail)
                throw SubtitleError(.inputUnreadable, "ffmpeg could not read this file")
            }
            throw SubtitleError(.noAudioTrack)
        }
        if let d = info.duration { log(.info, "Length: \(Self.clock(d)).") }
        for s in info.audioStreams { log(.detail, "Audio \(s.summary)") }
        return info
    }

    private func prepare(workDir: URL, info: MediaInfo, track: AudioStream) async throws -> ChunkPlan {
        let fm = FileManager.default

        // 2. Extract mono 16 kHz audio (what Whisper uses internally).
        let encoders = try await runFFmpeg(["-hide_banner", "-encoders"], captureStdout: true)
        let useMP3 = encoders.stdout.contains("libmp3lame")
        let ext = useMP3 ? "mp3" : "flac"
        let mime = useMP3 ? "audio/mpeg" : "audio/flac"
        let codecArgs = useMP3 ? ["-c:a", "libmp3lame", "-b:a", "64k"] : ["-c:a", "flac", "-sample_fmt", "s16"]
        let full = workDir.appendingPathComponent("full.\(ext)")

        func extract(centreOnly: Bool) async throws -> FFmpegRun {
            var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path,
                        "-map", "0:a:\(track.audioIndex)", "-vn", "-sn", "-dn"]
            if centreOnly { args += ["-af", "pan=mono|c0=FC"] }
            args += ["-ac", "1", "-ar", "16000"] + codecArgs + ["-progress", "pipe:1", "-nostats", full.path]
            return try await runFFmpeg(args, total: info.duration, range: (0.02, 0.22), step: "Extracting audio…")
        }
        let centreOnly = settings.dialogueFocus && track.hasCentreChannel
        if centreOnly { log(.info, "Surround track: using the centre (dialogue) channel.") }
        log(.info, "Extracting audio…")
        var result = try await extract(centreOnly: centreOnly)
        if result.status != 0 && centreOnly {
            log(.warning, "Centre-channel extraction failed; retrying with a normal mix.")
            result = try await extract(centreOnly: false)
        }
        guard result.status == 0, fm.fileExists(atPath: full.path) else {
            log(.detail, result.stderrTail)
            throw SubtitleError(.audioExtractFailed, "ffmpeg exit code \(result.status)")
        }

        let audioProbe = try await runFFmpeg(["-hide_banner", "-nostdin", "-i", full.path])
        guard let duration = FFmpegOutput.parseMediaInfo(audioProbe.stderrLines.joined(separator: "\n")).duration ?? info.duration,
              duration > 0 else {
            throw SubtitleError(.audioExtractFailed, "extracted audio has no length")
        }

        // 3. Measure loudness every 0.1 s to find the quiet moments between phrases.
        log(.info, "Measuring loudness to find pauses…")
        let envelope = try await runFFmpeg(["-hide_banner", "-nostdin", "-i", full.path,
                                            "-af", "asetnsamples=n=1600:p=0,astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=RMS_level,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
                                            "-f", "null", "-"],
                                           captureStdout: true, total: duration, range: (0.22, 0.27),
                                           step: "Finding pauses…", progressFromPTS: true)
        let loudness = FFmpegOutput.parseLoudness(envelope.stdout.components(separatedBy: "\n"))
        if loudness.isEmpty { log(.warning, "Could not measure loudness; cutting at fixed points.") }
        let cuts = ChunkPlanner.cutPoints(duration: duration, loudness: loudness)

        // 4. Split.
        progress(0.28, "Splitting audio…")
        var parts: [ChunkPlan.Part] = []
        if cuts.isEmpty {
            let only = "part_000.\(ext)"
            try? fm.removeItem(at: workDir.appendingPathComponent(only))
            try fm.moveItem(at: full, to: workDir.appendingPathComponent(only))
            parts = [ChunkPlan.Part(file: only, start: 0, end: duration)]
        } else {
            let list = workDir.appendingPathComponent("parts.csv")
            let split = try await runFFmpeg(["-hide_banner", "-nostdin", "-y", "-i", full.path,
                                             "-map", "0:a", "-c", "copy", "-f", "segment",
                                             "-segment_times", cuts.map { String(format: "%.3f", $0) }.joined(separator: ","),
                                             "-segment_list", list.path, "-segment_list_type", "csv",
                                             "-reset_timestamps", "1",
                                             workDir.appendingPathComponent("part_%03d.\(ext)").path])
            let csv = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
            parts = FFmpegOutput.parseSegmentList(csv).map { ChunkPlan.Part(file: $0.file, start: $0.start, end: $0.end) }
            guard split.status == 0, !parts.isEmpty,
                  parts.allSatisfy({ fm.fileExists(atPath: workDir.appendingPathComponent($0.file).path) }) else {
                log(.detail, split.stderrTail)
                throw SubtitleError(.audioSplitFailed, "ffmpeg exit code \(split.status)")
            }
            try? fm.removeItem(at: full)
        }
        let peaks = ChunkPlanner.peakLevels(loudness, parts: parts.map { ($0.start, $0.end) })
        for i in parts.indices {
            if let peak = peaks[i], peak < Self.silenceThresholdDB { parts[i].silent = true }
        }
        let longest = parts.map { $0.end - $0.start }.max() ?? 0
        let silentCount = parts.filter(\.silent).count
        log(.info, "Split into \(parts.count) part\(parts.count == 1 ? "" : "s") (longest \(Int(longest.rounded(.up))) s)"
            + (silentCount > 0 ? ", \(silentCount) silent." : "."))
        let requests = parts.count - silentCount
        let minutes = Double(requests) * Self.minSecondsBetweenRequests / 60
        log(.info, "Estimated time: about \(max(1, Int(minutes.rounded(.up)))) min (\(requests) requests to Groq).")

        let plan = ChunkPlan(mimeType: mime, duration: duration, track: track.summary, parts: parts)
        try JSONEncoder().encode(plan).write(to: workDir.appendingPathComponent("plan.json"), options: .atomic)
        return plan
    }

    // MARK: - Helpers

    private struct FFmpegRun {
        let status: Int32
        let stderrLines: [String]
        let stdout: String
        var stderrTail: String { stderrLines.suffix(8).joined(separator: "\n") }
    }

    /// - Parameter progressFromPTS: read progress from "pts_time:" lines
    ///   (the loudness pass prints those instead of `-progress` output).
    private func runFFmpeg(_ args: [String], captureStdout: Bool = false, total: Double? = nil,
                           range: (Double, Double)? = nil, step: String = "",
                           progressFromPTS: Bool = false) async throws -> FFmpegRun {
        let stdoutBox = StringBox()
        let progress = self.progress
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(ffmpeg, args, onStdoutLine: { line in
                if captureStdout { stdoutBox.append(line) }
                if let total, total > 0, let range,
                   let t = progressFromPTS ? Self.ptsTime(line) : FFmpegOutput.progressSeconds(fromLine: line) {
                    let frac = min(1, max(0, t / total))
                    progress(range.0 + (range.1 - range.0) * frac, step)
                }
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubtitleError(.ffmpegMissing, "cannot run \(ffmpeg.path): \(error.localizedDescription)")
        }
        return FFmpegRun(status: result.status, stderrLines: result.stderrLines, stdout: stdoutBox.value)
    }

    private func workFolder(track: AudioStream) throws -> URL {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: input.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(input.path)|\(size)|\(mtime)|\(settings.model)|\(settings.dialogueFocus)|track\(track.audioIndex)|v2"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let dir = AppPaths.cache.appendingPathComponent(String(hash), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw SubtitleError(.writeFailed, "cannot create work folder: \(error.localizedDescription)")
        }
        return dir
    }

    /// A saved plan is only usable if every part not yet translated still has its audio.
    private func loadPlan(in workDir: URL) -> ChunkPlan? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: workDir.appendingPathComponent("plan.json")),
              let plan = try? JSONDecoder().decode(ChunkPlan.self, from: data), plan.version == 2, !plan.parts.isEmpty
        else { return nil }
        for (i, part) in plan.parts.enumerated()
        where !fm.fileExists(atPath: resultURL(workDir, i).path)
            && !fm.fileExists(atPath: workDir.appendingPathComponent(part.file).path) {
            return nil
        }
        return plan
    }

    private func resultURL(_ workDir: URL, _ index: Int) -> URL {
        workDir.appendingPathComponent(String(format: "result_%03d.json", index))
    }

    private static func ptsTime(_ line: String) -> Double? {
        guard let r = line.range(of: "pts_time:") else { return nil }
        return Double(line[r.upperBound...].prefix { !$0.isWhitespace })
    }

    static let englishHint = "The following is the English translation of the dialogue in a film."

    /// Share of non-Latin letters across a reply's segments.
    static func foreignRatio(_ reply: GroqVerboseResponse) -> Double {
        let text = (reply.segments ?? []).map(\.text).joined(separator: " ")
        return SubtitleBuilder.foreignRatio(text)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

private final class StringBox {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) {
        lock.lock(); lines.append(s); lock.unlock()
    }
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
