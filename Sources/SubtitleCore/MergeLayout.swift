import CoreGraphics
import Foundation

/// The Merge canvas: a 1920 × 1080 frame an image is placed on.
public enum MergeCanvas {
    public static let size = CGSize(width: 1920, height: 1080)
}

/// Snapping like a design tool: while an image is dragged or resized, its
/// left / centre / right (and top / middle / bottom) stick to the canvas edges
/// and centre lines once they come within `threshold`, and a guide line shows
/// which one. It's a sticky spot, not a wall: keep going and it pulls free.
public enum CanvasSnap {
    public struct Result: Equatable {
        public var rect: CGRect
        /// Where to draw the vertical / horizontal guide, if something snapped.
        public var guideX: CGFloat?
        public var guideY: CGFloat?

        public init(rect: CGRect, guideX: CGFloat? = nil, guideY: CGFloat? = nil) {
            self.rect = rect
            self.guideX = guideX
            self.guideY = guideY
        }
    }

    /// The closest of `edges` to any of `targets` within `threshold`: (shift, target).
    static func closest(_ edges: [CGFloat], _ targets: [CGFloat], within threshold: CGFloat) -> (shift: CGFloat, at: CGFloat)? {
        var best: (shift: CGFloat, at: CGFloat)?
        for e in edges {
            for t in targets where abs(t - e) <= threshold && (best == nil || abs(t - e) < abs(best!.shift)) {
                best = (t - e, t)
            }
        }
        return best
    }

    static func xTargets(_ canvas: CGSize) -> [CGFloat] { [0, canvas.width / 2, canvas.width] }
    static func yTargets(_ canvas: CGSize) -> [CGFloat] { [0, canvas.height / 2, canvas.height] }

    /// A dragged rect, moved onto the nearest canvas edge or centre line.
    public static func drag(_ rect: CGRect, canvas: CGSize = MergeCanvas.size, threshold: CGFloat) -> Result {
        var r = rect
        let bx = closest([rect.minX, rect.midX, rect.maxX], xTargets(canvas), within: threshold)
        let by = closest([rect.minY, rect.midY, rect.maxY], yTargets(canvas), within: threshold)
        if let bx { r.origin.x += bx.shift }
        if let by { r.origin.y += by.shift }
        return Result(rect: r, guideX: bx?.at, guideY: by?.at)
    }

    /// Resizing from a corner with the proportions kept: `anchor` is the opposite
    /// corner (it stays put) and `point` where the dragged corner is. The dragged
    /// corner snaps to whichever canvas line (vertical or horizontal) is closest.
    public static func resize(anchor: CGPoint, to point: CGPoint, aspect: CGFloat, canvas: CGSize = MergeCanvas.size,
                              threshold: CGFloat, snap: Bool = true, minWidth: CGFloat = 40) -> Result {
        let sx: CGFloat = point.x >= anchor.x ? 1 : -1
        let sy: CGFloat = point.y >= anchor.y ? 1 : -1
        // Follow whichever direction the pointer went further (as the proportions allow).
        var width = max(abs(point.x - anchor.x), abs(point.y - anchor.y) * aspect, minWidth)
        var guideX: CGFloat?
        var guideY: CGFloat?
        if snap {
            let cornerX = anchor.x + sx * width
            let cornerY = anchor.y + sy * width / aspect
            let bx = closest([cornerX], xTargets(canvas), within: threshold)
            let by = closest([cornerY], yTargets(canvas), within: threshold)
            if let bx, by == nil || abs(bx.shift) <= abs(by!.shift) {
                let w = abs(bx.at - anchor.x)
                if w >= minWidth { width = w; guideX = bx.at }
            } else if let by {
                let w = abs(by.at - anchor.y) * aspect
                if w >= minWidth { width = w; guideY = by.at }
            }
        }
        let height = width / aspect
        let rect = CGRect(x: sx > 0 ? anchor.x : anchor.x - width, y: sy > 0 ? anchor.y : anchor.y - height,
                          width: width, height: height)
        return Result(rect: rect, guideX: guideX, guideY: guideY)
    }

    /// The whole image inside the canvas, centred (may leave bars).
    public static func fit(aspect: CGFloat, canvas: CGSize = MergeCanvas.size) -> CGRect {
        let w = min(canvas.width, canvas.height * aspect)
        let h = w / aspect
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    /// The canvas covered completely, centred (the image may run past the edges).
    public static func fill(aspect: CGFloat, canvas: CGSize = MergeCanvas.size) -> CGRect {
        let w = max(canvas.width, canvas.height * aspect)
        let h = w / aspect
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }
}

/// Cropping: `crop` is the kept part of the image in 0…1 image coordinates
/// (origin top-left); `visible` is where that kept part sits on the canvas.
public enum CropMath {
    public enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// Where the whole, uncropped image lies on the canvas.
    public static func fullFrame(visible: CGRect, crop: CGRect) -> CGRect {
        let w = visible.width / crop.width
        let h = visible.height / crop.height
        return CGRect(x: visible.minX - crop.minX * w, y: visible.minY - crop.minY * h, width: w, height: h)
    }

    /// Where the kept part lies on the canvas, for a whole image at `full`.
    public static func visibleFrame(full: CGRect, crop: CGRect) -> CGRect {
        CGRect(x: full.minX + crop.minX * full.width, y: full.minY + crop.minY * full.height,
               width: crop.width * full.width, height: crop.height * full.height)
    }

    /// Moves one handle of `crop` by `delta` (0…1 image units), keeping it inside
    /// the image and at least `minSize` wide and tall.
    public static func drag(_ crop: CGRect, handle: Handle, by delta: CGVector, minSize: CGFloat = 0.05) -> CGRect {
        var minX = crop.minX, minY = crop.minY, maxX = crop.maxX, maxY = crop.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(max(0, minX + delta.dx), maxX - minSize)
        case .topRight, .right, .bottomRight: maxX = max(min(1, maxX + delta.dx), minX + minSize)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(max(0, minY + delta.dy), maxY - minSize)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(min(1, maxY + delta.dy), minY + minSize)
        case .left, .right: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// How long each image of a slideshow shows.
public enum SlideTimes {
    /// Lengths for the slides: those with a fixed length keep it, the others
    /// share what is left of `total` equally (if every slide is fixed, the last
    /// one takes what is left). nil if that leaves any slide under `minimum`.
    public static func lengths(total: Double, fixed: [Double?], minimum: Double = 0.5) -> [Double]? {
        guard !fixed.isEmpty, total > 0 else { return nil }
        var fixed = fixed
        if fixed.allSatisfy({ $0 != nil }) { fixed[fixed.count - 1] = nil }
        let taken = fixed.compactMap { $0 }.reduce(0, +)
        let free = fixed.filter { $0 == nil }.count
        let share = (total - taken) / Double(free)
        let result = fixed.map { $0 ?? share }
        return result.allSatisfy({ $0 >= minimum - 1e-9 }) ? result : nil
    }
}

/// Everything the Merge tab turns into one ffmpeg run.
public struct MergeSpec: Equatable {
    public struct Slide: Equatable {
        public var file: String   // a 1920 × 1080 picture of the finished frame
        public var length: Double
        public init(file: String, length: Double) {
            self.file = file
            self.length = length
        }
    }

    public var slides: [Slide]
    public var audio: String
    public var audioStart: Double
    public var audioLength: Double
    /// Fade from / to black, with the sound, in seconds (0 = none).
    public var fadeIn: Double
    public var fadeOut: Double
    /// Even the loudness out to YouTube's -14 LUFS.
    public var normalize: Bool
    /// Copy the audio unchanged (AAC, whole file, no fades or normalising).
    public var copyAudio: Bool
    public var output: String
    public var audioChannels = 2
    public var fps = 30

    public init(slides: [Slide], audio: String, audioStart: Double, audioLength: Double, fadeIn: Double, fadeOut: Double,
                normalize: Bool, copyAudio: Bool, output: String) {
        self.slides = slides
        self.audio = audio
        self.audioStart = audioStart
        self.audioLength = audioLength
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.normalize = normalize
        self.copyAudio = copyAudio
        self.output = output
    }

    /// ffmpeg arguments for a YouTube-ready 1080p H.264 + AAC .mp4 (YouTube's
    /// recommended settings: High profile, 4:2:0, BT.709, keyframe every 2 s,
    /// 48 kHz AAC, moov atom first).
    public var ffmpegArguments: [String] {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        var args = ["-hide_banner", "-nostdin", "-y"]
        for s in slides { args += ["-loop", "1", "-framerate", "\(fps)", "-t", f(s.length), "-i", s.file] }
        if audioStart > 0 { args += ["-ss", f(audioStart)] }
        args += ["-t", f(audioLength), "-i", audio]
        let a = slides.count

        var video = (0..<slides.count).map { "[\($0):v]" }.joined()
        video += slides.count > 1 ? "concat=n=\(slides.count):v=1:a=0," : "null,"
        video += "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,setsar=1,"
            + "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"
        if fadeIn > 0 { video += ",fade=t=in:st=0:d=\(f(fadeIn))" }
        if fadeOut > 0 { video += ",fade=t=out:st=\(f(max(0, audioLength - fadeOut))):d=\(f(fadeOut))" }
        var graph = video + "[v]"
        if !copyAudio {
            var audioChain = "[\(a):a:0]"
            var filters: [String] = []
            if normalize { filters.append("loudnorm=I=-14:TP=-1.5:LRA=11") }
            if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(f(fadeIn))") }
            if fadeOut > 0 { filters.append("afade=t=out:st=\(f(max(0, audioLength - fadeOut))):d=\(f(fadeOut))") }
            filters.append("aresample=48000")
            audioChain += filters.joined(separator: ",") + "[a]"
            graph += ";" + audioChain
        }
        args += ["-filter_complex", graph, "-map", "[v]", "-map", copyAudio ? "\(a):a:0" : "[a]"]
        args += ["-c:v", "libx264", "-preset", "veryfast", "-tune", "stillimage", "-crf", "18",
                 "-profile:v", "high", "-level:v", "4.2", "-pix_fmt", "yuv420p", "-r", "\(fps)", "-g", "\(fps * 2)"]
        args += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", audioChannels == 1 ? "160k" : "320k", "-ar", "48000"]
        args += ["-t", f(audioLength), "-movflags", "+faststart", output]
        return args
    }
}
