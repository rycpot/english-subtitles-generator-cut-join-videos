import Foundation

/// Decides where to cut the film's audio into parts for upload.
///
/// Whisper hears audio in 30-second windows. Given a longer file, it moves
/// to each next window using its own predicted timestamps, which are
/// unreliable when translating (especially for languages such as Telugu):
/// speech gets skipped and subtitles drift out of sync after the first
/// 30 seconds. Parts are therefore kept to at most 30 s, so each is exactly
/// one window, and cut at the quietest moment so no word is split.
public enum ChunkPlanner {
    /// Preferred longest part, a little under Whisper's 30 s window.
    public static let target: Double = 28
    /// Never exceed Whisper's window.
    public static let hardMax: Double = 30
    /// Shortest part, except for the final one.
    public static let minLength: Double = 12

    /// - Parameters:
    ///   - duration: total audio length in seconds
    ///   - loudness: 0.1 s loudness samples from ffmpeg (may be empty)
    /// - Returns: the cut points (not including 0 or `duration`).
    public static func cutPoints(duration: Double, loudness: [LoudnessSample],
                                 target: Double = target, minLength: Double = minLength) -> [Double] {
        guard duration > target else { return [] }
        let smoothed = smooth(loudness)
        var cuts: [Double] = []
        var start = 0.0
        var searchFrom = 0
        while duration - start > target {
            let windowStart = start + minLength
            let windowEnd = start + target
            // Find the quietest moment in the window; later wins ties so parts stay long.
            var best: (time: Double, db: Double)?
            var i = searchFrom
            while i < smoothed.count, smoothed[i].time < windowEnd {
                let s = smoothed[i]
                if s.time > windowStart, best == nil || s.db <= best!.db {
                    best = (s.time, s.db)
                }
                if s.time <= windowStart { searchFrom = i }
                i += 1
            }
            // Cut in the middle of the quiet 0.1 s slice.
            let cut = best.map { $0.time + 0.05 } ?? windowEnd
            // A tiny tail can join the last part as long as it stays inside the window.
            if duration - cut < 2, duration - start <= hardMax { break }
            cuts.append(cut)
            start = cut
        }
        return cuts
    }

    /// Averages each sample with its neighbours (0.3 s) so a single quiet
    /// slice inside a word isn't mistaken for a pause.
    static func smooth(_ samples: [LoudnessSample]) -> [LoudnessSample] {
        guard samples.count > 2 else { return samples }
        return samples.indices.map { i in
            let lo = max(0, i - 1), hi = min(samples.count - 1, i + 1)
            let avg = samples[lo...hi].reduce(0) { $0 + $1.db } / Double(hi - lo + 1)
            return LoudnessSample(time: samples[i].time, db: avg)
        }
    }

    /// Loudest smoothed level of each part, used to skip silent parts
    /// (no upload means no Whisper "Thank you." hallucinations and no quota used).
    public static func peakLevels(_ loudness: [LoudnessSample], parts: [(start: Double, end: Double)]) -> [Double?] {
        let smoothed = smooth(loudness)
        var result: [Double?] = []
        var i = 0
        for part in parts {
            while i < smoothed.count, smoothed[i].time < part.start { i += 1 }
            var peak: Double?
            var j = i
            while j < smoothed.count, smoothed[j].time < part.end {
                peak = max(peak ?? -.infinity, smoothed[j].db)
                j += 1
            }
            result.append(peak)
        }
        return result
    }
}
