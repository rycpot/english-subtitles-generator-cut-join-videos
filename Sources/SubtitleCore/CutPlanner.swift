import Foundation

/// A keyframe (a point where a video can be cut without re-encoding), with its
/// display time (pts) and decode time (dts), in the file's own time base.
///
/// In "open GOP" video (common in films and trailers) the frames decoded right
/// after a keyframe can be shown before it and depend on the previous group.
/// `lead` is the earliest display time among the keyframe and those frames;
/// it equals `pts` when there are none.
public struct Keyframe: Equatable {
    public let pts: Double
    public let dts: Double
    public let lead: Double
    public init(pts: Double, dts: Double, lead: Double? = nil) {
        self.pts = pts
        self.dts = dts
        self.lead = lead ?? pts
    }
}

/// How one stretch of a cut is produced.
public enum CutPiece: Equatable {
    /// Re-encoded frame by frame: frames with start <= pts < end.
    case encode(start: Double, end: Double)
    /// Copied untouched: whole groups of pictures from keyframe `start` up to
    /// keyframe `end`. ffmpeg trims copied packets by decode time, so the
    /// keyframes' dts are kept too. `fromDTS` nil = from the file's start,
    /// `toDTS` nil = to the file's end.
    case copy(start: Double, end: Double, fromDTS: Double?, toDTS: Double?)

    public var start: Double {
        switch self {
        case .encode(let s, _), .copy(let s, _, _, _): return s
        }
    }

    public var end: Double {
        switch self {
        case .encode(_, let e), .copy(_, let e, _, _): return e
        }
    }

    public var duration: Double { end - start }

    public var isCopy: Bool {
        if case .copy = self { return true }
        return false
    }
}

public enum CutPlanner {
    /// Parses `ffprobe -show_entries packet=pts_time,dts_time,flags -of csv=p=0`
    /// (packets in decode order) and keeps the keyframes. The first packet often
    /// has no dts; it is then estimated from the pts-to-dts delay of the other
    /// keyframes. Frames decoded after a keyframe but shown before it set its `lead`.
    public static func parseKeyframes(_ csv: String) -> [Keyframe] {
        var raw: [(pts: Double, dts: Double?, lead: Double)] = []
        var delays: [Double] = []
        for line in csv.components(separatedBy: .newlines) {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard cols.count >= 3, let pts = Double(cols[0]) else { continue }
            guard cols[2].contains("K") else {
                if !raw.isEmpty, pts < raw[raw.count - 1].lead { raw[raw.count - 1].lead = pts }
                continue
            }
            let dts = Double(cols[1])
            raw.append((pts, dts, pts))
            if let dts { delays.append(pts - dts) }
        }
        delays.sort()
        let delay = delays.isEmpty ? 0 : delays[delays.count / 2]
        var seen = Set<Double>()
        return raw.compactMap { k in
            guard seen.insert(k.pts).inserted else { return nil }
            return Keyframe(pts: k.pts, dts: k.dts ?? k.pts - delay, lead: k.lead)
        }
        .sorted { $0.pts < $1.pts }
    }

    /// The display time of the first frame at or after `time`, from
    /// `ffprobe -show_entries packet=pts_time -of csv=p=0` output; nil if none.
    public static func firstFrame(atOrAfter time: Double, in csv: String) -> Double? {
        csv.components(separatedBy: .newlines)
            .compactMap { Double($0.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") }
            .filter { $0 >= time }
            .min()
    }

    /// Plans a frame-exact cut of start..<end (file time base) that copies as
    /// much as possible: the stretch between the first and last keyframe inside
    /// the range is copied, and only the frames before the first keyframe and
    /// from the last keyframe on are re-encoded. With open GOP, the copy leaves
    /// out the first keyframe's leading frames (the head covers them) and stops
    /// before the last keyframe's leading frames (the tail covers them).
    /// - Parameters:
    ///   - frameDuration: one frame, used for tolerances
    ///   - firstKeyframe: pts of the file's very first keyframe (a copy that
    ///     starts there needs no start trim)
    ///   - reachesFileEnd: the range runs to the end of the file, so the last
    ///     stretch can be copied to the end instead of re-encoded
    public static func plan(start s: Double, end e: Double, keyframes: [Keyframe], frameDuration fd: Double,
                            firstKeyframe: Double?, reachesFileEnd: Bool) -> [CutPiece] {
        let tol = fd * 0.01
        let inner = keyframes.filter { $0.pts >= s - tol && $0.pts <= e + tol }
        guard let k1 = inner.first else { return [.encode(start: s, end: e)] }
        let fromDTS: Double? = firstKeyframe.map { abs($0 - k1.pts) < tol } == true ? nil : k1.dts

        var pieces: [CutPiece] = []
        // A frame exists before k1 inside the range only if k1 is a whole frame after s.
        if k1.pts - s >= fd - tol { pieces.append(.encode(start: s, end: k1.pts)) }

        if reachesFileEnd {
            pieces.append(.copy(start: k1.pts, end: e, fromDTS: fromDTS, toDTS: nil))
            return pieces
        }
        let k2 = inner.last!
        guard k2.lead - k1.pts > tol else {
            // Only one keyframe inside: nothing worth copying.
            return [.encode(start: s, end: e)]
        }
        pieces.append(.copy(start: k1.pts, end: k2.lead, fromDTS: fromDTS, toDTS: k2.dts))
        if e - k2.lead > tol { pieces.append(.encode(start: k2.lead, end: e)) }
        return pieces
    }
}

public struct ChapterInfo: Equatable {
    public var start: Double
    public var end: Double
    public var title: String
    public init(start: Double, end: Double, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

public enum ChapterPlanner {
    /// Chapters for an output made of several ranges of source files, in order.
    /// Each range is given in its file's time base; chapters overlapping a range
    /// are clipped to it and moved to the output's timeline.
    public static func chapters(for ranges: [(chapters: [ChapterInfo], start: Double, end: Double)]) -> [ChapterInfo] {
        var result: [ChapterInfo] = []
        var offset = 0.0
        for range in ranges {
            for c in range.chapters where c.end > range.start && c.start < range.end {
                let s = max(c.start, range.start) - range.start + offset
                let e = min(c.end, range.end) - range.start + offset
                if e - s >= 0.5 { result.append(ChapterInfo(start: s, end: e, title: c.title)) }
            }
            offset += range.end - range.start
        }
        return result
    }

    /// An ffmpeg metadata file ("FFMETADATA1") with global tags and chapters.
    public static func ffmetadata(tags: [String: String], chapters: [ChapterInfo]) -> String {
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s {
                if "=;#\\\n".contains(ch) { out.append("\\") }
                out.append(ch)
            }
            return out
        }
        var text = ";FFMETADATA1\n"
        for (k, v) in tags.sorted(by: { $0.key < $1.key }) { text += "\(esc(k))=\(esc(v))\n" }
        for c in chapters {
            text += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int((c.start * 1000).rounded()))\nEND=\(Int((c.end * 1000).rounded()))\n"
            if !c.title.isEmpty { text += "title=\(esc(c.title))\n" }
        }
        return text
    }
}
