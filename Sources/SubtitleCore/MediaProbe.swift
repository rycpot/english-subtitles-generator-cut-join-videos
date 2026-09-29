import Foundation

/// `ffprobe -show_streams -show_format -show_chapters -of json` output.
public struct ProbeResult: Decodable {
    public var streams: [ProbeStream]
    public var format: ProbeFormat
    public var chapters: [ProbeChapter]?

    public static func decode(_ data: Data) throws -> ProbeResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProbeResult.self, from: data)
    }
}

public struct ProbeStream: Decodable, Equatable {
    public var index: Int
    public var codecType: String?
    public var codecName: String?
    public var width: Int?
    public var height: Int?
    public var pixFmt: String?
    public var rFrameRate: String?
    public var avgFrameRate: String?
    public var timeBase: String?
    public var sampleAspectRatio: String?
    public var sampleRate: String?
    public var channels: Int?
    public var channelLayout: String?
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorSpace: String?
    public var colorRange: String?
    public var disposition: [String: Int]?
    public var tags: [String: String]?

    /// Cover art. (The snake-case key conversion also renames dictionary keys.)
    public var isAttachedPicture: Bool { disposition?["attachedPic"] == 1 || disposition?["attached_pic"] == 1 }
}

public struct ProbeFormat: Decodable {
    public var startTime: String?
    public var duration: String?
    public var formatName: String?
    public var tags: [String: String]?
}

public struct ProbeChapter: Decodable {
    public var startTime: String
    public var endTime: String
    public var tags: [String: String]?
}

public extension ProbeResult {
    /// The main picture stream (cover art in some .mkv files is also "video").
    var video: ProbeStream? {
        streams.first { $0.codecType == "video" && !$0.isAttachedPicture }
    }

    var audio: [ProbeStream] { streams.filter { $0.codecType == "audio" } }
    var subtitles: [ProbeStream] { streams.filter { $0.codecType == "subtitle" } }

    /// Where the file's timestamps start; user times are relative to this.
    var startTime: Double { Double(format.startTime ?? "") ?? 0 }
    var duration: Double { Double(format.duration ?? "") ?? 0 }

    var frameRate: Double? { Self.rate(video?.rFrameRate) ?? Self.rate(video?.avgFrameRate) }
    var frameDuration: Double { 1 / (frameRate ?? 25) }

    var chapterList: [ChapterInfo] {
        (chapters ?? []).compactMap { c in
            guard let s = Double(c.startTime), let e = Double(c.endTime) else { return nil }
            return ChapterInfo(start: s, end: e, title: c.tags?["title"] ?? "")
        }
    }

    /// Smart cutting (copy between keyframes, re-encode only the edges) is
    /// verified for 8-bit 4:2:0 H.264 and 8/10-bit 4:2:0 HEVC at a constant frame rate.
    var canSmartCut: Bool {
        guard let v = video else { return false }
        let formats: [String: Set<String>] = ["h264": ["yuv420p", "yuvj420p"], "hevc": ["yuv420p", "yuv420p10le"]]
        guard let allowed = formats[v.codecName ?? ""], allowed.contains(v.pixFmt ?? "") else { return false }
        guard let r = Self.rate(v.rFrameRate) else { return false }
        if let a = Self.rate(v.avgFrameRate), abs(a - r) / r > 0.01 { return false }
        return true
    }

    /// Everything that must be equal for files to be joined without
    /// re-encoding them to a common format.
    var joinSignature: JoinSignature {
        JoinSignature(
            video: video.map { [$0.codecName ?? "", "\($0.width ?? 0)x\($0.height ?? 0)", $0.pixFmt ?? "",
                                Self.rate($0.rFrameRate).map { String(format: "%.3f", $0) } ?? "",
                                $0.sampleAspectRatio ?? "1:1"] } ?? [],
            audio: audio.map { [$0.codecName ?? "", $0.sampleRate ?? "", "\($0.channels ?? 0)"] },
            subtitles: subtitles.map { $0.codecName ?? "" })
    }

    static func rate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0, parts[0] > 0 { return parts[0] / parts[1] }
        if parts.count == 1, parts[0] > 0 { return parts[0] }
        return nil
    }
}

public struct JoinSignature: Hashable {
    public let video: [String]
    public let audio: [[String]]
    public let subtitles: [String]

    /// Human-readable differences from another file, for the log.
    public func differences(from other: JoinSignature) -> [String] {
        var out: [String] = []
        let names = ["codec", "size", "pixel format", "frame rate", "aspect"]
        for (i, name) in names.enumerated() where i < video.count && i < other.video.count && video[i] != other.video[i] {
            out.append("video \(name) \(other.video[i]) vs \(video[i])")
        }
        if audio != other.audio { out.append("audio tracks differ") }
        if subtitles != other.subtitles { out.append("subtitle tracks differ") }
        return out
    }
}

public extension ProbeStream {
    /// "Track 2 · eng · 5.1 · eac3 · default", for picking an audio track.
    var audioLabel: String {
        var parts: [String] = []
        if let lang = tags?["language"], !lang.isEmpty, lang != "und" { parts.append(lang) }
        if let title = tags?["title"], !title.isEmpty { parts.append(title) }
        if let layout = channelLayout, !layout.isEmpty {
            parts.append(layout)
        } else if let ch = channels {
            parts.append("\(ch) ch")
        }
        if let codec = codecName { parts.append(codec) }
        if disposition?["default"] == 1 { parts.append("default") }
        return parts.joined(separator: " · ")
    }
}

public enum AudioFiles {
    /// The file type that holds an audio stream of `codec` unchanged.
    public static func fileExtension(forCodec codec: String?) -> String {
        switch codec ?? "" {
        case "aac", "alac": return "m4a"
        case "mp3": return "mp3"
        case "ac3": return "ac3"
        case "eac3": return "eac3"
        case "flac": return "flac"
        case "opus": return "opus"
        case "vorbis": return "ogg"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_u8": return "wav"
        default: return "mka"   // Matroska holds any audio (DTS, TrueHD, …)
        }
    }
}

public enum SubtitleCodecs {
    /// Text subtitles that .mp4 can carry (as mov_text).
    public static let text: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]
}

public enum JoinPlanner {
    /// Which piece's format the others should be converted to when formats
    /// differ: the format that makes up most of the running time (so the least
    /// video is converted), and on a tie the one with more pixels.
    public static func bestTarget(_ pieces: [(signature: JoinSignature, duration: Double, pixels: Int)]) -> Int {
        guard !pieces.isEmpty else { return 0 }
        var time: [JoinSignature: Double] = [:]
        for p in pieces { time[p.signature, default: 0] += p.duration }
        return pieces.indices.max { a, b in
            let ta = time[pieces[a].signature] ?? 0, tb = time[pieces[b].signature] ?? 0
            if abs(ta - tb) > 0.001 { return ta < tb }
            if pieces[a].pixels != pieces[b].pixels { return pieces[a].pixels < pieces[b].pixels }
            return a > b   // earlier piece wins a full tie
        } ?? 0
    }
}

public extension ProbeResult {
    var pixelCount: Int { (video?.width ?? 0) * (video?.height ?? 0) }

    /// "1920×1080, 23.976 fps, h264"
    var formatSummary: String {
        guard let v = video else { return "no video" }
        let fps = frameRate.map { String(format: $0.rounded() == $0 ? "%.0f" : "%.3f", $0) } ?? "?"
        return "\(v.width ?? 0)×\(v.height ?? 0), \(fps) fps, \(v.codecName ?? "?")"
    }
}
