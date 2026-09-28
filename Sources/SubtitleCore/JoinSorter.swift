import Foundation

public enum JoinSortKey: String, CaseIterable, Identifiable {
    case name = "Name"
    case modified = "Date modified"
    case duration = "Duration"
    public var id: String { rawValue }
}

/// What a Joiner piece is sorted by. A missing value (a file still being read)
/// sorts last in either direction.
public struct JoinSortItem {
    public var name: String
    public var modified: Date?
    public var duration: Double?

    public init(name: String, modified: Date? = nil, duration: Double? = nil) {
        self.name = name
        self.modified = modified
        self.duration = duration
    }
}

public enum JoinSorter {
    /// The new order, as indices into `items`. Stable: equal items (such as
    /// several cuts of one file) keep their current order.
    public static func order(_ items: [JoinSortItem], by key: JoinSortKey, ascending: Bool) -> [Int] {
        func compare(_ a: JoinSortItem, _ b: JoinSortItem) -> ComparisonResult? {
            switch key {
            case .name:
                // Natural order, as in Finder: "part 2" before "part 10".
                let r = a.name.localizedStandardCompare(b.name)
                return r == .orderedSame ? nil : r
            case .modified:
                return compareOptional(a.modified, b.modified)
            case .duration:
                return compareOptional(a.duration, b.duration)
            }
        }
        func compareOptional<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult? {
            switch (a, b) {
            case let (x?, y?): return x == y ? nil : (x < y ? .orderedAscending : .orderedDescending)
            case (nil, nil): return nil
            case (nil, _): return ascending ? .orderedDescending : .orderedAscending   // missing last
            case (_, nil): return ascending ? .orderedAscending : .orderedDescending
            }
        }
        return items.indices.sorted { i, j in
            guard let r = compare(items[i], items[j]) else { return i < j }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}
