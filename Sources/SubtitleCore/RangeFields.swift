import Foundation

public enum EndMode: String, CaseIterable, Identifiable {
    case endTime = "End time"
    case duration = "Duration"
    public var id: String { rawValue }
}

/// What the user typed for one range: a start, and either an end time or a
/// duration from the start ("from 00:20:00, 00:02:00 long").
public struct RangeFields: Equatable {
    public var start: String
    public var endMode: EndMode
    public var end: String

    public init(start: String = "00:00:00", endMode: EndMode = .duration, end: String = "00:01:00") {
        self.start = start
        self.endMode = endMode
        self.end = end
    }

    /// The range in seconds from the file's start, or a message saying what is wrong.
    /// An end slightly past the file's end (under half a second) is treated as the end.
    public func resolve(fileDuration: Double?) -> Result<ClosedRange<Double>, RangeError> {
        guard let s = TimeCode.parse(start) else { return .failure(.badStart) }
        guard let value = TimeCode.parse(end) else {
            return .failure(endMode == .endTime ? .badEnd : .badDuration)
        }
        var e = endMode == .endTime ? value : s + value
        guard e - s >= 0.1 else { return .failure(.notAfterStart) }
        if let d = fileDuration, d > 0 {
            guard s < d - 0.05 else { return .failure(.startPastEnd(d)) }
            if e > d + 0.5 { return .failure(.endPastEnd(d)) }
            e = min(e, d)
        }
        return .success(s...e)
    }
}

public enum RangeError: Error, Equatable, CustomStringConvertible {
    case badStart, badEnd, badDuration, notAfterStart
    case startPastEnd(Double)
    case endPastEnd(Double)

    public var description: String {
        switch self {
        case .badStart: return "Start time isn't valid. Use hh:mm:ss, for example 00:20:00."
        case .badEnd: return "End time isn't valid. Use hh:mm:ss, for example 00:22:00."
        case .badDuration: return "Duration isn't valid. Use hh:mm:ss, for example 00:02:00."
        case .notAfterStart: return "The end must be after the start."
        case .startPastEnd(let d): return "Starts after the video ends (it is \(TimeCode.format(d)) long)."
        case .endPastEnd(let d): return "Ends after the video ends (it is \(TimeCode.format(d)) long)."
        }
    }
}
