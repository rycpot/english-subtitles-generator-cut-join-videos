import Foundation

/// Decides where to cut the film's audio into parts for upload. Cuts are
/// placed in pauses between lines of dialogue so no sentence is split.
public enum ChunkPlanner {
    /// - Parameters:
    ///   - duration: total audio length in seconds
    ///   - silences: pauses found by ffmpeg's silencedetect
    ///   - target: longest part length (Groq's free tier caps files at 25 MB;
    ///     10 minutes of 64 kbit/s mono MP3 is under 5 MB)
    ///   - minLength: shortest part, except for the final one
    /// - Returns: the cut points (not including 0 or `duration`).
    public static func cutPoints(duration: Double, silences: [Silence],
                                 target: Double = 600, minLength: Double = 420) -> [Double] {
        guard duration > target else { return [] }
        var cuts: [Double] = []
        var start = 0.0
        while duration - start > target {
            let windowStart = start + minLength
            let windowEnd = start + target
            // The longest pause in the window is the safest place to cut.
            let best = silences
                .filter { $0.midpoint > windowStart && $0.midpoint < windowEnd }
                .max { a, b in
                    let la = min(a.end, windowEnd) - max(a.start, windowStart)
                    let lb = min(b.end, windowEnd) - max(b.start, windowStart)
                    return la == lb ? a.midpoint < b.midpoint : la < lb
                }
            let cut = best?.midpoint ?? windowEnd
            // Avoid leaving a tiny tail part (Groq bills at least 10 s per request).
            if duration - cut < 15 { break }
            cuts.append(cut)
            start = cut
        }
        return cuts
    }
}
