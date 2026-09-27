import Foundation

public struct Cue: Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One uploaded part: where it starts in the film, how long it is, and what Groq returned.
public struct ChunkResult {
    public let offset: Double
    public let length: Double
    public let segments: [GroqSegment]
    public init(offset: Double, length: Double, segments: [GroqSegment]) {
        self.offset = offset
        self.length = length
        self.segments = segments
    }
}

public enum SubtitleBuilder {
    public static let maxLineLength = 42
    public static let maxLines = 2

    /// Phrases Whisper is known to invent over music or silence.
    static let hallucinationPatterns = [
        "thanks for watching", "thank you for watching", "please subscribe", "like and subscribe",
        "subscribe to", "amara.org", "subtitles by", "subtitled by", "transcribed by",
        "translated by", "captions by", "www.", ".com",
    ]

    public static func isLikelyHallucination(_ s: GroqSegment) -> Bool {
        let text = normalized(s.text)
        if text.isEmpty { return true }
        if hallucinationPatterns.contains(where: { text.contains($0) }) { return true }
        // OpenAI's own heuristic for "this was silence": probably no speech and low confidence.
        if let nsp = s.noSpeechProb, let lp = s.avgLogprob, nsp > 0.6, lp < -1.0 { return true }
        // Very repetitive text ("la la la la ...") compresses unusually well.
        if let cr = s.compressionRatio, cr > 2.6 { return true }
        return false
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: ".")).inverted)
            .joined()
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    public static func cleaned(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func buildCues(from chunks: [ChunkResult]) -> [Cue] {
        var cues: [Cue] = []
        for chunk in chunks {
            for seg in chunk.segments where !isLikelyHallucination(seg) {
                let text = cleaned(seg.text)
                let start = chunk.offset + min(max(0, seg.start), chunk.length)
                var end = chunk.offset + min(max(0, seg.end), chunk.length)
                if end <= start { end = start + 1.5 }
                // Whisper sometimes repeats the same line across adjacent segments.
                if let last = cues.last, normalized(last.text) == normalized(text), start - last.end < 1.5 {
                    cues[cues.count - 1].end = max(last.end, end)
                    continue
                }
                cues.append(Cue(start: start, end: end, text: text))
            }
        }
        cues.sort { $0.start < $1.start }
        return fixTiming(cues.flatMap(splitLong))
    }

    /// Splits a cue whose text does not fit two lines into several cues,
    /// sharing the time in proportion to text length.
    static func splitLong(_ cue: Cue) -> [Cue] {
        let limit = maxLineLength * maxLines
        guard cue.text.count > limit else { return [cue] }
        var pieces: [String] = []
        var current = ""
        for word in cue.text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > limit, !current.isEmpty {
                pieces.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let total = Double(pieces.reduce(0) { $0 + $1.count })
        var t = cue.start
        return pieces.map { piece in
            let d = (cue.end - cue.start) * Double(piece.count) / total
            defer { t += d }
            return Cue(start: t, end: t + d, text: piece)
        }
    }

    static func fixTiming(_ input: [Cue]) -> [Cue] {
        var cues = input
        for i in cues.indices {
            let chars = Double(cues[i].text.count)
            // Don't leave a short line up for a long pause: cap by reading time.
            let maxDuration = min(8.0, max(3.0, chars / 12.0 + 2.0))
            cues[i].end = min(cues[i].end, cues[i].start + maxDuration)
            // Give very short lines at least one second, if the next allows.
            cues[i].end = max(cues[i].end, cues[i].start + 1.0)
            if i + 1 < cues.count, cues[i].end > cues[i + 1].start - 0.05 {
                cues[i].end = max(cues[i].start + 0.3, cues[i + 1].start - 0.05)
            }
        }
        return cues
    }

    /// Wraps text into at most two lines, breaking near the middle.
    public static func wrap(_ text: String) -> String {
        guard text.count > maxLineLength else { return text }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return text }
        var best = 1
        var bestScore = Int.max
        for i in 1..<words.count {
            let a = words[..<i].joined(separator: " ").count
            let b = words[i...].joined(separator: " ").count
            let score = max(a, b) * 10 + abs(a - b)
            if score < bestScore {
                bestScore = score
                best = i
            }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }

    public static func timestamp(_ seconds: Double) -> String {
        let totalMs = Int((max(0, seconds) * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    public static func srt(from cues: [Cue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(wrap(cue.text))\n\n"
        }
        return out
    }
}
