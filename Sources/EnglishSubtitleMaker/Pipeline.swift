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
    }
    var version = 1
    var mimeType: String
    var duration: Double
    var track: String
    var parts: [Part]
}

/// Turns one video file into `<name>.en.srt`:
/// probe → extract mono 16 kHz audio → find pauses → split into ~10 min parts
/// → Groq translates each part to English → build and save the SRT.
final class Pipeline {
    static let partLength: Double = 600

    let input: URL
    let ffmpeg: URL
    let settings: PipelineSettings
    let apiKey: String?
    let log: (LogLevel, String) -> Void
    let progress: (Double, String) -> Void

    init(input: URL, ffmpeg: URL, settings: PipelineSettings, apiKey: String?,
         log: @escaping (LogLevel, String) -> Void,
         progress: @escaping (Double, String) -> Void) {
        self.input = input
        self.ffmpeg = ffmpeg
        self.settings = settings
        self.apiKey = apiKey
        self.log = log
        self.progress = progress
    }

    var outputURL: URL {
        input.deletingPathExtension().appendingPathExtension("en").appendingPathExtension("srt")
    }

    /// Runs the whole job. With `prepareOnly`, stops after splitting the audio
    /// (used by the `--selftest` mode) and returns the work folder.
    @discardableResult
    func run(prepareOnly: Bool = false) async throws -> URL {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: input.path) else {
            throw SubtitleError(.inputUnreadable, input.path)
        }
        let workDir = try workFolder()
        let plan: ChunkPlan
        if let saved = loadPlan(in: workDir) {
            let done = saved.parts.indices.filter { fm.fileExists(atPath: resultURL(workDir, $0).path) }.count
            log(.info, "Resuming earlier job: \(done) of \(saved.parts.count) parts already translated.")
            plan = saved
        } else {
            plan = try await prepare(workDir: workDir)
        }
        if prepareOnly { return workDir }

        guard let apiKey, !apiKey.isEmpty else { throw SubtitleError(.apiKeyMissing) }
        let client = GroqClient(apiKey: apiKey, model: settings.model, log: log)

        var results: [ChunkResult] = []
        var previousText: String?
        for (i, part) in plan.parts.enumerated() {
            try Task.checkCancellation()
            let label = "Part \(i + 1) of \(plan.parts.count) (\(Self.clock(part.start))–\(Self.clock(part.end)))"
            let resultFile = resultURL(workDir, i)
            var response: GroqVerboseResponse?
            if let data = try? Data(contentsOf: resultFile) {
                response = try? JSONDecoder().decode(GroqVerboseResponse.self, from: data)
                if response != nil { log(.detail, "\(label): already translated, skipping.") }
            }
            if response == nil {
                progress(0.30 + 0.68 * Double(i) / Double(plan.parts.count), "Translating \(label.lowercased())…")
                log(.info, "\(label): uploading to Groq…")
                let started = Date()
                let data = try await client.translate(file: workDir.appendingPathComponent(part.file),
                                                      mimeType: plan.mimeType, prompt: previousText)
                do {
                    response = try JSONDecoder().decode(GroqVerboseResponse.self, from: data)
                } catch {
                    let snippet = String(decoding: data.prefix(300), as: UTF8.self)
                    throw SubtitleError(.badResponse, snippet)
                }
                try? data.write(to: resultFile, options: .atomic)
                let lines = response?.segments?.count ?? 0
                log(.info, "\(label): done in \(Int(Date().timeIntervalSince(started))) s, \(lines) lines.")
            }
            let segments = response?.segments ?? []
            results.append(ChunkResult(offset: part.start, length: part.end - part.start, segments: segments))
            // Give the next part the last lines as context for names and style.
            let tail = segments.suffix(2).map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            previousText = tail.isEmpty ? nil : String(tail.suffix(300))
        }

        progress(0.99, "Writing subtitles…")
        let cues = SubtitleBuilder.buildCues(from: results)
        guard !cues.isEmpty else { throw SubtitleError(.noSpeech) }
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

    private func prepare(workDir: URL) async throws -> ChunkPlan {
        let fm = FileManager.default

        // 1. Probe
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
        guard let track = info.preferredAudioStream() else { throw SubtitleError(.noAudioTrack) }
        if info.audioStreams.count > 1 {
            log(.info, "Using audio \(track.summary) (first non-English track).")
        }

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

        // 3. Find pauses so parts are cut between sentences.
        log(.info, "Finding pauses in the dialogue…")
        let detect = try await runFFmpeg(["-hide_banner", "-nostdin", "-i", full.path,
                                          "-af", "silencedetect=noise=-30dB:d=0.35",
                                          "-progress", "pipe:1", "-nostats", "-f", "null", "-"],
                                         total: duration, range: (0.22, 0.27), step: "Finding pauses…")
        let silences = FFmpegOutput.parseSilences(detect.stderrLines, totalDuration: duration)
        let cuts = ChunkPlanner.cutPoints(duration: duration, silences: silences, target: Self.partLength)

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
        let avg = duration / Double(parts.count) / 60
        log(.info, "Split into \(parts.count) part\(parts.count == 1 ? "" : "s") (about \(Int(avg.rounded())) min each).")

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

    private func runFFmpeg(_ args: [String], captureStdout: Bool = false, total: Double? = nil,
                           range: (Double, Double)? = nil, step: String = "") async throws -> FFmpegRun {
        let stdoutBox = StringBox()
        let progress = self.progress
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(ffmpeg, args, onStdoutLine: { line in
                if captureStdout { stdoutBox.append(line) }
                if let total, total > 0, let range, let t = FFmpegOutput.progressSeconds(fromLine: line) {
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

    private func workFolder() throws -> URL {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: input.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(input.path)|\(size)|\(mtime)|\(settings.model)|\(settings.dialogueFocus)|v1"
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
              let plan = try? JSONDecoder().decode(ChunkPlan.self, from: data), plan.version == 1, !plan.parts.isEmpty
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
