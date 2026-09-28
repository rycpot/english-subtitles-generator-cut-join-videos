import Foundation

/// Times typed by the user, such as "00:20:00", "20:00", "95" or "1:02:03.5".
public enum TimeCode {
    /// Parses h:mm:ss(.fff), m:ss(.fff) or plain seconds. A comma also works
    /// as the decimal mark. Returns nil for anything else.
    public static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            let allowed = CharacterSet(charactersIn: isLast ? "0123456789." : "0123456789")
            guard !part.isEmpty, part.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  part.filter({ $0 == "." }).count <= 1, let value = Double(part) else { return nil }
            // Minutes and seconds after the first field must be under 60.
            if i > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// "01:02:03" or, when there are milliseconds, "01:02:03.500".
    public static func format(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let base = String(format: "%02d:%02d:%02d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60)
        return ms % 1000 == 0 ? base : base + String(format: ".%03d", ms % 1000)
    }

    /// Like `format`, but with dots so it can go in a file name: "00.20.00".
    public static func fileSafe(_ seconds: Double) -> String {
        format(seconds).replacingOccurrences(of: ":", with: ".")
    }
}

public enum SplitMode: Equatable {
    case none
    case count(Int)
    case length(Double)
}

public enum RangeSplitter {
    /// Splits start..<end into equal parts, or parts of a fixed length where
    /// the last one takes whatever is left.
    public static func split(start: Double, end: Double, mode: SplitMode) -> [(start: Double, end: Double)] {
        guard end > start else { return [] }
        switch mode {
        case .none:
            return [(start, end)]
        case .count(let n):
            guard n > 1 else { return [(start, end)] }
            let length: Double = (end - start) / Double(n)
            var ranges: [(start: Double, end: Double)] = []
            for i in 0..<n {
                let s: Double = start + Double(i) * length
                let e: Double = i == n - 1 ? end : start + Double(i + 1) * length
                ranges.append((s, e))
            }
            return ranges
        case .length(let length):
            guard length > 0 else { return [(start, end)] }
            var ranges: [(start: Double, end: Double)] = []
            var s = start
            while end - s > 0.001 {
                var e = min(s + length, end)
                // Don't leave a sliver of a few milliseconds as its own part.
                if end - e < 0.001 { e = end }
                ranges.append((s, e))
                s = e
            }
            return ranges
        }
    }
}
