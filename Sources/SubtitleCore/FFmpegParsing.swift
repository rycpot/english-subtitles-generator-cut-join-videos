import Foundation

public struct AudioStream: Equatable {
    /// Position among the audio streams only (used as `-map 0:a:N`).
    public let audioIndex: Int
    public let language: String?
    public let title: String?
    /// The text after "Audio:", e.g. "aac (LC), 48000 Hz, 5.1, fltp (default)".
    public let details: String
    public let isDefault: Bool
    /// Channel layout name as ffmpeg prints it ("stereo", "5.1(side)", "6 channels"...).
    public let layout: String?

    /// True when the layout has a named front-centre channel, where film dialogue lives.
    public var hasCentreChannel: Bool {
        guard let layout = layout?.lowercased() else { return false }
        return ["5.0", "5.1", "6.0", "6.1", "7.0", "7.1", "3.0", "3.1", "4.0", "4.1"].contains { layout.hasPrefix($0) }
    }

    public var isEnglish: Bool {
        guard let lang = language?.lowercased() else { return false }
        return lang == "eng" || lang == "en"
    }

    public var summary: String {
        var parts = ["track \(audioIndex + 1)"]
        parts.append(language ?? "unknown language")
        if let title, !title.isEmpty { parts.append("\"\(title)\"") }
        if let layout { parts.append(layout) }
        if isDefault { parts.append("default") }
        return parts.joined(separator: ", ")
    }
}

public struct MediaInfo: Equatable {
    public var duration: Double?
    public var audioStreams: [AudioStream]

    /// A foreign-language film often also carries an English dub. Prefer the
    /// first track that is not tagged English; otherwise the default track.
    public func preferredAudioStream() -> AudioStream? {
        if let foreign = audioStreams.first(where: { !$0.isEnglish }) { return foreign }
        return audioStreams.first(where: { $0.isDefault }) ?? audioStreams.first
    }
}

/// Loudness of a short slice of audio (0.1 s) starting at `time`.
public struct LoudnessSample: Equatable {
    public let time: Double
    public let db: Double
    public init(time: Double, db: Double) {
        self.time = time
        self.db = db
    }
}

public enum FFmpegOutput {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let durationRegex = regex(#"Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)"#)
    // Handles both "Stream #0:1(eng): Audio:" and "Stream #0:1[0x1100](eng): Audio:".
    private static let audioStreamRegex = regex(#"^\s*Stream #\d+:\d+(?:\[0x[0-9a-fA-F]+\])?(?:\(([A-Za-z]+)\))?(?:\[0x[0-9a-fA-F]+\])?:\s*Audio:\s*(.+)$"#)
    private static let anyStreamRegex = regex(#"^\s*Stream #\d+:\d+"#)
    private static let titleRegex = regex(#"^\s+title\s*:\s*(.+)$"#)

    private static func captures(_ re: NSRegularExpression, in line: String) -> [String?]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, options: [], range: range) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let sr = Range(r, in: line) else { return nil }
            return String(line[sr])
        }
    }

    /// Parses the stderr of `ffmpeg -hide_banner -i FILE`.
    public static func parseMediaInfo(_ output: String) -> MediaInfo {
        var info = MediaInfo(duration: nil, audioStreams: [])
        var lastAudio: (language: String?, details: String)?
        var lastTitle: String?

        func flush() {
            guard let a = lastAudio else { return }
            info.audioStreams.append(AudioStream(
                audioIndex: info.audioStreams.count,
                language: (a.language?.lowercased() == "und") ? nil : a.language,
                title: lastTitle,
                details: a.details,
                isDefault: a.details.contains("(default)"),
                layout: channelLayout(fromDetails: a.details)))
            lastAudio = nil
            lastTitle = nil
        }

        for line in output.components(separatedBy: .newlines) {
            if info.duration == nil, let c = captures(durationRegex, in: line),
               let h = Double(c[0] ?? ""), let m = Double(c[1] ?? ""), let s = Double(c[2] ?? "") {
                info.duration = h * 3600 + m * 60 + s
                continue
            }
            if let c = captures(audioStreamRegex, in: line) {
                flush()
                lastAudio = (c[0], (c[1] ?? "").trimmingCharacters(in: .whitespaces))
                continue
            }
            if captures(anyStreamRegex, in: line) != nil {
                flush()
                continue
            }
            if lastAudio != nil, lastTitle == nil, let c = captures(titleRegex, in: line) {
                lastTitle = c[0]?.trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return info
    }

    /// "aac (LC), 48000 Hz, 5.1(side), fltp (default)" -> "5.1(side)"
    static func channelLayout(fromDetails details: String) -> String? {
        let parts = details.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let hz = parts.firstIndex(where: { $0.hasSuffix(" Hz") }), hz + 1 < parts.count else { return nil }
        return parts[hz + 1]
    }

    /// Parses the output of the loudness pass
    /// (`asetnsamples,astats,ametadata=print:key=lavfi.astats.Overall.RMS_level`):
    /// pairs of "frame:N pts:... pts_time:T" and "lavfi.astats.Overall.RMS_level=DB".
    /// Silence ("-inf") becomes -120 dB.
    public static func parseLoudness(_ lines: [String]) -> [LoudnessSample] {
        var samples: [LoudnessSample] = []
        var time: Double?
        for line in lines {
            if let r = line.range(of: "pts_time:") {
                let rest = line[r.upperBound...].prefix { !$0.isWhitespace }
                time = Double(rest)
            } else if let r = line.range(of: "RMS_level="), let t = time {
                let value = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                let db = Double(value).map { $0.isFinite ? max($0, -120) : -120 } ?? -120
                samples.append(LoudnessSample(time: t, db: db))
                time = nil
            }
        }
        return samples
    }

    /// Reads a `-progress pipe:1` line and returns the position in seconds.
    public static func progressSeconds(fromLine line: String) -> Double? {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        // out_time_ms is (historically, confusingly) also microseconds.
        case "out_time_us", "out_time_ms":
            guard let us = Double(parts[1]), us >= 0 else { return nil }
            return us / 1_000_000
        default:
            return nil
        }
    }

    /// Parses a `-segment_list_type csv` file: "chunk_000.mp3,0.000000,596.016000".
    public static func parseSegmentList(_ csv: String) -> [(file: String, start: Double, end: Double)] {
        csv.components(separatedBy: .newlines).compactMap { line in
            let cols = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3, let s = Double(cols[cols.count - 2]), let e = Double(cols[cols.count - 1]) else { return nil }
            return (cols[0..<(cols.count - 2)].joined(separator: ","), s, e)
        }
    }
}
