import AppKit
import Foundation
import SubtitleCore

/// One stretch of a source file to put in an output. Times are as the user
/// sees them: seconds from the start of the file.
struct MediaPiece {
    let url: URL
    let probe: ProbeResult
    let start: Double
    let end: Double

    var duration: Double { end - start }
    /// The same range in the file's own time base.
    var absStart: Double { start + probe.startTime }
    var absEnd: Double { end + probe.startTime }
    var reachesFileEnd: Bool { probe.duration > 0 && end >= probe.duration - probe.frameDuration / 2 }
}

/// Cutting and joining with ffmpeg without changing the video where possible.
///
/// - Smart (H.264, same format everywhere): whole groups of pictures between
///   keyframes are copied untouched; only the frames before the first and
///   after the last keyframe of each piece are re-encoded. Frame-exact.
/// - Exact (same format, other codecs): each piece's video is re-encoded with
///   the same codec at high quality; audio and subtitles are copied.
/// - Converted (different formats): everything is re-encoded to match the
///   first file (first audio track, no subtitles).
///
/// Audio and subtitle tracks, their languages, chapters and the title are
/// kept in the first two modes.
final class MediaTools {
    let ffmpeg: URL
    let ffprobe: URL
    let log: (LogLevel, String) -> Void
    let progress: (Double, String) -> Void

    init(ffmpeg: URL, ffprobe: URL,
         log: @escaping (LogLevel, String) -> Void, progress: @escaping (Double, String) -> Void) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.log = log
        self.progress = progress
    }

    static func make(log: @escaping (LogLevel, String) -> Void,
                     progress: @escaping (Double, String) -> Void) throws -> MediaTools {
        guard let ffmpeg = AppPaths.findFFmpeg() else { throw SubtitleError(.ffmpegMissing) }
        guard let ffprobe = AppPaths.findTool("ffprobe") else { throw SubtitleError(.ffprobeMissing) }
        return MediaTools(ffmpeg: ffmpeg, ffprobe: ffprobe, log: log, progress: progress)
    }

    // MARK: Reading files

    func probe(_ url: URL) async throws -> ProbeResult {
        let result = try await tool(ffprobe, ["-v", "error", "-show_streams", "-show_format", "-show_chapters",
                                              "-of", "json", url.path])
        guard result.status == 0, let probe = try? ProbeResult.decode(Data(result.stdout.utf8)) else {
            throw SubtitleError(.mediaUnreadable, "\(url.lastPathComponent): \(result.stderrTail)")
        }
        guard probe.video != nil else { throw SubtitleError(.mediaUnreadable, "\(url.lastPathComponent) has no video") }
        return probe
    }

    /// Keyframes around start...end (file time base).
    func keyframes(_ url: URL, from start: Double, to end: Double, videoIndex: Int) async throws -> [Keyframe] {
        let result = try await tool(ffprobe, ["-v", "error", "-select_streams", "\(videoIndex)",
                                              "-show_entries", "packet=pts_time,dts_time,flags", "-of", "csv=p=0",
                                              "-read_intervals", String(format: "%.3f%%%.3f", max(0, start - 20), end + 20),
                                              url.path])
        guard result.status == 0 else { throw SubtitleError(.mediaUnreadable, result.stderrTail) }
        return CutPlanner.parseKeyframes(result.stdout)
    }

    /// A small still of the frame at `time` (seconds from the file's start).
    func thumbnail(_ url: URL, at time: Double, videoIndex: Int) async -> NSImage? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        guard let result = try? await tool(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-v", "error",
                                                    "-ss", String(format: "%.3f", max(0, time)), "-i", url.path,
                                                    "-map", "0:\(videoIndex)", "-frames:v", "1",
                                                    "-vf", "scale=320:-2", "-q:v", "4", out.path]),
              result.status == 0 else { return nil }
        return NSImage(contentsOf: out)
    }

    // MARK: Making outputs

    /// The piece whose format everything is converted to when formats differ.
    static func autoTarget(_ pieces: [MediaPiece]) -> Int {
        JoinPlanner.bestTarget(pieces.map { ($0.probe.joinSignature, $0.duration, $0.probe.pixelCount) })
    }

    /// Writes `pieces`, in order, into one file at `output`. If their formats
    /// differ, all are converted to the format of piece `target` (default: auto).
    func render(_ pieces: [MediaPiece], to output: URL, target: Int? = nil) async throws {
        let pieces = try await pieces.asyncMap { try await snapped($0) }
        guard let first = pieces.first else { return }
        let work = AppPaths.cache.appendingPathComponent("tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let signature = first.probe.joinSignature
        if pieces.contains(where: { $0.probe.joinSignature != signature }) {
            let t = target.flatMap { pieces.indices.contains($0) ? $0 : nil } ?? Self.autoTarget(pieces)
            let match = pieces[t]
            let converted = pieces.filter { $0.probe.joinSignature != match.probe.joinSignature }.count
            log(.warning, "The pieces have different formats. Converting to piece \(t + 1)'s format (\(match.probe.formatSummary), \(match.url.lastPathComponent))"
                + (target == nil ? ", which makes up most of the running time" : "")
                + ". \(converted) piece\(converted == 1 ? "" : "s") differ; everything is re-encoded, only the first audio track is kept and subtitles are left out.")
            try await renderConverted(pieces, to: output, match: match.probe)
            return
        }
        if pieces.allSatisfy({ $0.probe.canSmartCut }) {
            do {
                try await renderAssembled(pieces, to: output, work: work, smart: true)
                return
            } catch let error as SmartCutCheckFailed {
                log(.warning, "The copied and re-encoded parts don't join cleanly (\(error.detail)). Redoing it frame-exact with full re-encoding.")
            }
        } else {
            let codec = first.probe.video?.codecName ?? "?"
            log(.info, "Video is \(codec), so the cut video is re-encoded at high quality (lossless copying is only used for H.264 and HEVC). Audio and subtitles are copied unchanged.")
        }
        try await renderAssembled(pieces, to: output, work: work, smart: false)
    }

    struct SmartCutCheckFailed: Error { let detail: String }

    /// Smart or exact: video pieces as MPEG-TS, other tracks copied per piece,
    /// then everything joined in one pass.
    private func renderAssembled(_ pieces: [MediaPiece], to output: URL, work: URL, smart: Bool) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let first = pieces[0].probe
        let hasOthers = !first.audio.isEmpty || !first.subtitles.isEmpty
        // .mkv cannot hold mp4's mov_text subtitles; use .mp4 for those pieces.
        let otherExt = first.subtitles.contains(where: { $0.codecName == "mov_text" }) ? "mp4" : "mkv"

        var videoList = ""
        var otherList = ""
        var junctions: [Junction] = []   // where a copied and an encoded part meet
        var outputTime = 0.0
        var step = 0
        let plans: [[CutPiece]] = try await pieces.asyncMap { piece in
            if !smart { return [.encode(start: piece.absStart, end: piece.absEnd)] }
            let v = piece.probe.video!
            let keys = try await keyframes(piece.url, from: piece.absStart, to: piece.absEnd, videoIndex: v.index)
            let firstKey = try await firstKeyframe(piece)
            return CutPlanner.plan(start: piece.absStart, end: piece.absEnd, keyframes: keys,
                                   frameDuration: piece.probe.frameDuration, firstKeyframe: firstKey,
                                   reachesFileEnd: piece.reachesFileEnd)
        }
        let totalSteps = plans.reduce(0) { $0 + $1.count } + pieces.count + 1

        for (p, piece) in pieces.enumerated() {
            let plan = plans[p]
            if smart {
                let copied = plan.filter(\.isCopy).reduce(0) { $0 + $1.duration }
                log(.detail, "Piece \(p + 1): \(TimeCode.format(piece.start))–\(TimeCode.format(piece.end)): "
                    + "\(Int((copied / max(piece.duration, 0.001) * 100).rounded()))% copied untouched, "
                    + "\(plan.filter { !$0.isCopy }.count) short re-encoded edge\(plan.filter { !$0.isCopy }.count == 1 ? "" : "s").")
            }
            for (i, cut) in plan.enumerated() {
                step += 1
                progress(Double(step) / Double(totalSteps), smart && cut.isCopy
                         ? "Copying piece \(p + 1) of \(pieces.count)…" : "Encoding piece \(p + 1) of \(pieces.count)…")
                let file = work.appendingPathComponent("v\(p)_\(i).ts")
                let what = smart ? "Encoding an edge of piece \(p + 1) of \(pieces.count)…" : "Encoding piece \(p + 1) of \(pieces.count)…"
                let report = reporter(what, from: cut.start, to: cut.end,
                                      progress: Double(step - 1) / Double(totalSteps)...Double(step) / Double(totalSteps))
                try await writeVideo(cut, of: piece, to: file, report: cut.isCopy ? nil : report)
                videoList += "file '\(file.path)'\nduration \(String(format: "%.6f", cut.duration))\n"
                if i > 0, plan[i - 1].isCopy != cut.isCopy {
                    junctions.append(Junction(output: outputTime, source: piece.url,
                                              sourceTime: cut.start - piece.probe.startTime))
                }
                outputTime += cut.duration
            }
            if hasOthers {
                step += 1
                let file = work.appendingPathComponent("o\(p).\(otherExt)")
                try await run(["-hide_banner", "-nostdin", "-y",
                               "-ss", String(format: "%.6f", max(0, piece.start - 10)), "-i", piece.url.path, "-copyts",
                               "-ss", String(format: "%.6f", piece.absStart), "-to", String(format: "%.6f", piece.absEnd),
                               "-map", "0:a?", "-map", "0:s?", "-c", "copy", "-map_chapters", "-1", file.path],
                              failure: .cutFailed)
                otherList += "file '\(file.path)'\nduration \(String(format: "%.6f", piece.duration))\n"
            }
        }

        // Chapters and the title, adjusted to the new timeline.
        let chapters = ChapterPlanner.chapters(for: pieces.map { ($0.probe.chapterList, $0.absStart, $0.absEnd) })
        let meta = work.appendingPathComponent("meta.txt")
        try ChapterPlanner.ffmetadata(tags: first.format.tags?.filter { $0.key.lowercased() == "title" } ?? [:],
                                      chapters: chapters).write(to: meta, atomically: true, encoding: .utf8)
        let vList = work.appendingPathComponent("video.txt")
        try videoList.write(to: vList, atomically: true, encoding: .utf8)

        var args = ["-hide_banner", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", vList.path]
        var maps = ["-map", "0:v"]
        var metaIndex = 1
        if hasOthers {
            let oList = work.appendingPathComponent("other.txt")
            try otherList.write(to: oList, atomically: true, encoding: .utf8)
            args += ["-f", "concat", "-safe", "0", "-i", oList.path]
            maps += ["-map", "1:a?"]
            maps += subtitleMaps(first, input: 1, output: output)
            metaIndex = 2
        }
        args += ["-f", "ffmetadata", "-i", meta.path] + maps
        args += ["-map_metadata", "\(metaIndex)", "-map_chapters", "\(metaIndex)", "-c", "copy"]
        if isMP4(output) {
            args += ["-c:s", "mov_text", "-movflags", "+faststart"]
            // Keep the source's time base: the MPEG-TS pieces use 1/90000, which
            // cannot hold 23.976 fps frame times exactly.
            if let tb = first.video?.timeBase, tb.hasPrefix("1/"), let scale = Int(tb.dropFirst(2)), scale > 0, scale != 90000 {
                args += ["-video_track_timescale", String(scale)]
            }
            if first.video?.codecName == "hevc" { args += ["-tag:v", "hvc1"] }
        }
        progress(Double(totalSteps - 1) / Double(totalSteps), "Joining…")
        try await run(args + [output.path], failure: .joinFailed)

        if smart, !junctions.isEmpty {
            progress(0.99, "Checking the joins…")
            if let problem = try await decodeProblem(output, at: junctions) {
                try? fm.removeItem(at: output)
                throw SmartCutCheckFailed(detail: problem)
            }
        }
    }

    /// One video stretch as MPEG-TS, copied or encoded.
    private func writeVideo(_ cut: CutPiece, of piece: MediaPiece, to file: URL,
                            report: ((String) -> Void)? = nil) async throws {
        let v = piece.probe.video!
        let fd = piece.probe.frameDuration
        let seek = String(format: "%.6f", max(0, cut.start - piece.probe.startTime - 10))
        var args = ["-hide_banner", "-nostdin", "-y", "-ss", seek, "-i", piece.url.path, "-copyts"]
        switch cut {
        case .copy(_, _, let fromDTS, let toDTS):
            if let fromDTS { args += ["-ss", String(format: "%.6f", fromDTS - fd / 4)] }
            if let toDTS { args += ["-to", String(format: "%.6f", toDTS - fd / 4)] }
            // dump_extra repeats the SPS/PPS on every keyframe: open-GOP files only
            // carry them before IDR frames, which a cut may not start at.
            // noise drops the frames shown before the first (key)frame: in open
            // GOP they need the previous group, and the re-encoded head has them.
            let annexB = v.codecName == "hevc" ? "hevc_mp4toannexb" : "h264_mp4toannexb"
            args += ["-map", "0:\(v.index)", "-c", "copy",
                     "-bsf:v", "\(annexB),dump_extra=freq=keyframe,noise=drop=lt(pts\\,startpts)"]
        case .encode(let start, let end):
            args += ["-map", "0:\(v.index)",
                     "-vf", String(format: "trim=start=%.6f:end=%.6f", start, end),
                     "-fps_mode", "passthrough"] + encoderArgs(for: piece.probe)
        }
        args += ["-an", "-sn", "-dn", "-f", "mpegts", file.path]
        try await run(args, failure: .cutFailed, report: report)
    }

    /// High-quality encoding that keeps the source's codec family.
    private func encoderArgs(for probe: ProbeResult) -> [String] {
        let v = probe.video!
        var args: [String]
        if v.codecName == "hevc" {
            let tenBit = (v.pixFmt ?? "").contains("10")
            args = ["-c:v", "libx265", "-preset", "fast", "-crf", "18",
                    "-pix_fmt", tenBit ? "yuv420p10le" : "yuv420p", "-x265-params", "log-level=error"]
        } else {
            args = ["-c:v", "libx264", "-preset", "medium", "-crf", "16", "-pix_fmt", "yuv420p"]
        }
        let colour: [(String, String?)] = [("-color_primaries", v.colorPrimaries), ("-color_trc", v.colorTransfer),
                                          ("-colorspace", v.colorSpace), ("-color_range", v.colorRange)]
        for (flag, value) in colour {
            if let value, !value.isEmpty, value != "unknown", value != "reserved" { args += [flag, value] }
        }
        return args
    }

    /// Different formats: decode everything and encode to the first file's
    /// size, frame rate and audio format in one pass.
    private func renderConverted(_ pieces: [MediaPiece], to output: URL, match: ProbeResult) async throws {
        let first = match
        let v = first.video!
        let w = v.width ?? 1280, h = v.height ?? 720
        let fps = v.rFrameRate ?? "25"
        let audio = first.audio.first
        let rate = Int(audio?.sampleRate ?? "") ?? 48000
        let layout: String
        switch audio?.channels ?? 2 {
        case 1: layout = "mono"
        case 6: layout = "5.1"
        case 8: layout = "7.1"
        default: layout = "stereo"
        }

        var args = ["-hide_banner", "-nostdin", "-y"]
        var filters: [String] = []
        var labels = ""
        for (i, piece) in pieces.enumerated() {
            args += ["-ss", String(format: "%.6f", piece.start), "-t", String(format: "%.6f", piece.duration), "-i", piece.url.path]
            let vi = piece.probe.video!.index
            filters.append("[\(i):\(vi)]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p,setpts=PTS-STARTPTS[v\(i)]")
            if let a = piece.probe.audio.first {
                filters.append("[\(i):\(a.index)]aresample=\(rate),aformat=sample_rates=\(rate):channel_layouts=\(layout),asetpts=PTS-STARTPTS[a\(i)]")
            } else {
                filters.append("anullsrc=r=\(rate):cl=\(layout),atrim=duration=\(String(format: "%.6f", piece.duration))[a\(i)]")
            }
            labels += "[v\(i)][a\(i)]"
        }
        filters.append("\(labels)concat=n=\(pieces.count):v=1:a=1[v][a]")
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]",
                 "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-c:a", "aac", "-b:a", "192k",
                 "-progress", "pipe:1", "-nostats"]
        if isMP4(output) { args += ["-movflags", "+faststart"] }
        let total = pieces.reduce(0) { $0 + $1.duration }
        let result = try await ProcessRunner.run(ffmpeg, args + [output.path],
                                                 onStdoutLine: reporter("Converting and joining…", from: 0, to: total,
                                                                        progress: 0...0.99))
        guard result.status == 0 else {
            log(.detail, result.stderrTail)
            throw SubtitleError(.joinFailed, "ffmpeg exit code \(result.status)")
        }
    }

    // MARK: Checks (used by the self-test)

    /// Display times of every frame of the main video.
    func framePTS(_ url: URL) async throws -> [Double] {
        let probe = try await probe(url)
        let result = try await tool(ffprobe, ["-v", "error", "-select_streams", "\(probe.video!.index)",
                                              "-show_entries", "packet=pts_time", "-of", "csv=p=0", url.path])
        return result.stdout.components(separatedBy: .newlines)
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }
            .sorted()
    }

    /// Errors from decoding the whole file.
    /// Length of the first audio stream from its decoded samples (raw .ac3
    /// files have no reliable stored duration).
    func audioLength(_ url: URL) async throws -> Double {
        let result = try await tool(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "frame=duration_time",
                                              "-of", "csv=p=0", url.path])
        return result.stdout.split(separator: "\n").compactMap { Double($0.split(separator: ",").first ?? "") }.reduce(0, +)
    }

    func decodeErrors(_ url: URL) async throws -> [String] {
        let result = try await tool(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-f", "null", "-"])
        return result.stderrLines.filter { !$0.contains("non monotonically increasing dts") }
    }

    // MARK: Helpers

    /// Turns ffmpeg `-progress` lines of an encode covering `from`...`to` (its
    /// output timestamps, seconds) into progress within `range` and a status
    /// with the percentage and the time left, so long encodes visibly move.
    func reporter(_ what: String, from: Double, to: Double, progress range: ClosedRange<Double>) -> (String) -> Void {
        let started = Date()
        let span = max(0.001, to - from)
        let progress = self.progress
        return { line in
            guard let t = FFmpegOutput.progressSeconds(fromLine: line) else { return }
            // Timestamps are kept (-copyts) in most encodes, but start at 0 in some.
            let done = min(1, max(0, (t >= from - 1 ? t - from : t) / span))
            guard done > 0 else { return }
            let elapsed = Date().timeIntervalSince(started)
            var text = "\(what) \(Int(done * 100))%"
            if elapsed > 5, done > 0.01, done < 1 {
                text += " · about \(Self.readable(elapsed * (1 - done) / done)) left"
            }
            progress(range.lowerBound + done * (range.upperBound - range.lowerBound), text)
        }
    }

    /// "2 h 05 min", "12 min", "40 s".
    static func readable(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return "\(Int((Double(s) / 60).rounded())) min" }
        return "\(max(1, s)) s"
    }

    /// Makes the Merge video: pictures shown over the audio, as a YouTube-ready
    /// 1080p H.264 .mp4, with live progress and the time left.
    func merge(_ spec: MergeSpec) async throws {
        progress(0.02, "Encoding the video…")
        try await run(spec.ffmpegArguments, failure: .joinFailed,
                      report: reporter("Encoding the video…", from: 0, to: spec.audioLength, progress: 0.02...0.99))
    }

    /// Copies one audio track of `piece` unchanged into `output` (its type
    /// chosen by `AudioFiles.fileExtension`). Accurate to one audio frame
    /// (a few hundredths of a second): the input is opened 10 s early, as a
    /// seek lands on a video keyframe and would keep the audio from there.
    func extractAudio(_ piece: MediaPiece, streamIndex: Int, to output: URL) async throws {
        let seek = max(0, piece.start - 10)
        try await run(["-hide_banner", "-nostdin", "-y",
                       "-ss", String(format: "%.6f", seek), "-i", piece.url.path,
                       "-ss", String(format: "%.6f", piece.start - seek), "-t", String(format: "%.6f", piece.duration),
                       "-map", "0:\(streamIndex)", "-c", "copy", "-vn", "-sn", "-dn",
                       "-map_metadata", "0", "-map_chapters", "-1", output.path],
                      failure: .cutFailed)
    }

    /// Moves a piece's start and end onto the first frame at or after them, so
    /// every part of a cut lasts exactly its frames: no timing gap where parts
    /// meet, and the output keeps the source's exact frame rate.
    private func snapped(_ piece: MediaPiece) async throws -> MediaPiece {
        guard let v = piece.probe.video else { return piece }
        let tol = piece.probe.frameDuration * 0.01
        func firstFrame(atOrAfter t: Double) async throws -> Double? {
            let result = try await tool(ffprobe, ["-v", "error", "-select_streams", "\(v.index)",
                                                  "-show_entries", "packet=pts_time", "-of", "csv=p=0",
                                                  "-read_intervals", String(format: "%.3f%%%.3f", max(0, t - 2), t + 2),
                                                  piece.url.path])
            guard result.status == 0 else { return nil }
            return CutPlanner.firstFrame(atOrAfter: t - tol, in: result.stdout)
        }
        let start = try await firstFrame(atOrAfter: piece.absStart) ?? piece.absStart
        let end = piece.reachesFileEnd ? piece.absEnd : (try await firstFrame(atOrAfter: piece.absEnd) ?? piece.absEnd)
        guard end > start else { return piece }
        return MediaPiece(url: piece.url, probe: piece.probe,
                          start: start - piece.probe.startTime, end: end - piece.probe.startTime)
    }

    private func firstKeyframe(_ piece: MediaPiece) async throws -> Double? {
        let v = piece.probe.video!
        let start = piece.probe.startTime
        return try await keyframes(piece.url, from: start, to: start + 1, videoIndex: v.index).first?.pts
    }

    /// Text subtitles for .mp4 (converted to mov_text); all subtitles otherwise.
    private func subtitleMaps(_ probe: ProbeResult, input: Int, output: URL) -> [String] {
        guard isMP4(output) else { return ["-map", "\(input):s?"] }
        return probe.subtitles.enumerated().flatMap { i, s in
            SubtitleCodecs.text.contains(s.codecName ?? "") ? ["-map", "\(input):s:\(i)"] : []
        }
    }

    private func isMP4(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    /// A place in the output where a copied and a re-encoded part meet, and the
    /// same moment in the source file (seconds from its start).
    struct Junction {
        let output: Double
        let source: URL
        let sourceTime: Double
    }

    /// Decodes a few seconds around each join and returns the first error, if any.
    /// Starting to decode in the middle of open-GOP video gives errors even in the
    /// untouched source, so errors the source shows at the same spot are ignored.
    private func decodeProblem(_ file: URL, at junctions: [Junction]) async throws -> String? {
        for j in junctions {
            let (status, errors) = try await windowErrors(file, around: j.output)
            if status != 0 { return "at \(TimeCode.format(j.output)): \(errors.first ?? "exit code \(status)")" }
            guard !errors.isEmpty else { continue }
            var expected = try await windowErrors(j.source, around: j.sourceTime).errors.map(Self.withoutPrefix)
            for error in errors {
                if let i = expected.firstIndex(of: Self.withoutPrefix(error)) {
                    expected.remove(at: i)
                } else {
                    return "at \(TimeCode.format(j.output)): \(error)"
                }
            }
        }
        return nil
    }

    /// Decoding errors in the 6 s of video around `time` (seconds from the file's start).
    private func windowErrors(_ file: URL, around time: Double) async throws -> (status: Int32, errors: [String]) {
        let result = try await tool(ffmpeg, ["-hide_banner", "-nostdin", "-v", "error",
                                             "-ss", String(format: "%.3f", max(0, time - 3)), "-i", file.path,
                                             "-t", "6", "-map", "0:v:0", "-f", "null", "-"])
        return (result.status, result.stderrLines.filter {
            !$0.contains("non monotonically increasing dts") && !$0.contains("Last message repeated")
        })
    }

    /// "[h264 @ 0x7f…] message" → "message", so errors from different runs compare equal.
    private static func withoutPrefix(_ line: String) -> String {
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return line }
        return line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)
    }

    struct ToolResult {
        let status: Int32
        let stdout: String
        let stderrLines: [String]
        var stderrTail: String { stderrLines.suffix(6).joined(separator: "\n") }
    }

    private func tool(_ exe: URL, _ args: [String]) async throws -> ToolResult {
        let out = LineBuffer()
        let result = try await ProcessRunner.run(exe, args, onStdoutLine: { out.append($0) })
        return ToolResult(status: result.status, stdout: out.text, stderrLines: result.stderrLines)
    }

    private func run(_ args: [String], failure: ErrorCode, report: ((String) -> Void)? = nil) async throws {
        let result: ToolResult
        if let report {
            let r = try await ProcessRunner.run(ffmpeg, ["-progress", "pipe:1", "-nostats"] + args, onStdoutLine: report)
            result = ToolResult(status: r.status, stdout: "", stderrLines: r.stderrLines)
        } else {
            result = try await tool(ffmpeg, args)
        }
        guard result.status == 0 else {
            log(.detail, result.stderrTail)
            throw SubtitleError(failure, "ffmpeg exit code \(result.status)")
        }
    }
}

private final class LineBuffer {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
