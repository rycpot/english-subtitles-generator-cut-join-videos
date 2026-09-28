import Foundation

/// A time as hours, minutes, seconds and a frame within that second, for
/// picking cut points from dropdowns.
public struct FrameTime: Equatable, Comparable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frame: Int

    public init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frame: Int = 0) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frame = frame
    }

    public static func < (a: FrameTime, b: FrameTime) -> Bool {
        (a.hours, a.minutes, a.seconds, a.frame) < (b.hours, b.minutes, b.seconds, b.frame)
    }
}

/// Converts between seconds and `FrameTime`, and works out which values each
/// dropdown may offer so only times inside the video can be picked.
public struct FrameClock {
    public let frameDuration: Double

    public init(frameDuration: Double) {
        self.frameDuration = frameDuration > 0 ? frameDuration : 0.04
    }

    /// Frames that start within one second: 24 for 23.976 fps, 25 for 25 fps.
    public var framesPerSecond: Int { max(1, Int((1 / frameDuration - 1e-6).rounded(.up))) }

    public func time(_ seconds: Double) -> FrameTime {
        let t = max(0, seconds)
        var whole = Int((t + 1e-6).rounded(.down))
        var frame = Int(((t - Double(whole)) / frameDuration).rounded())
        if frame >= framesPerSecond {
            // Closer to the next second's first frame.
            whole += 1
            frame = 0
        }
        return FrameTime(hours: whole / 3600, minutes: (whole / 60) % 60, seconds: whole % 60, frame: max(0, frame))
    }

    public func seconds(_ t: FrameTime) -> Double {
        Double(t.hours * 3600 + t.minutes * 60 + t.seconds) + Double(t.frame) * frameDuration
    }

    /// `t`, or `limit` if `t` is past it.
    public func clamp(_ t: FrameTime, to limit: FrameTime) -> FrameTime { min(t, limit) }

    /// The values each dropdown offers for `t`, given the latest allowed time.
    public func choices(for t: FrameTime, limit: FrameTime)
        -> (hours: ClosedRange<Int>, minutes: ClosedRange<Int>, seconds: ClosedRange<Int>, frames: ClosedRange<Int>) {
        let atHour = t.hours >= limit.hours
        let atMinute = atHour && t.minutes >= limit.minutes
        let atSecond = atMinute && t.seconds >= limit.seconds
        return (0...limit.hours,
                0...(atHour ? limit.minutes : 59),
                0...(atMinute ? limit.seconds : 59),
                0...(atSecond ? limit.frame : framesPerSecond - 1))
    }
}
