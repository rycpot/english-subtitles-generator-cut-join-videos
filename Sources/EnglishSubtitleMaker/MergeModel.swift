import AppKit
import Foundation
import ImageIO
import SubtitleCore
import SwiftUI
import UniformTypeIdentifiers

/// One picture of the Merge slideshow and where it sits on the 1920 × 1080 canvas.
struct MergeSlide: Identifiable {
    let id = UUID()
    let url: URL
    /// The picture, upright (EXIF orientation applied), at most 4096 px on its long side.
    let image: CGImage
    /// The kept part of the picture, 0…1 with the origin top-left.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Where the kept part sits on the canvas (may run past the edges).
    var frame: CGRect
    /// Seconds this picture shows; nil = an equal share of what is left.
    var fixedLength: Double?

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    /// Width / height of the kept part.
    var aspect: CGFloat {
        (pixelSize.width * crop.width) / max(1, pixelSize.height * crop.height)
    }

    /// The kept part as its own image.
    var croppedImage: CGImage {
        let r = CGRect(x: crop.minX * pixelSize.width, y: crop.minY * pixelSize.height,
                       width: crop.width * pixelSize.width, height: crop.height * pixelSize.height).integral
            .intersection(CGRect(origin: .zero, size: pixelSize))
        return image.cropping(to: r) ?? image
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"]

    /// Reads a picture upright, scaled down to 4096 px at most (plenty for 1080p).
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Draws the finished frames of a slideshow.
enum MergeRenderer {
    /// The 1920 × 1080 frame for `slide`: the background colour, then the kept
    /// part of the picture where it sits on the canvas (clipped to the canvas).
    static func frame(_ slide: MergeSlide, background: CGColor) -> CGImage? {
        let w = Int(MergeCanvas.size.width), h = Int(MergeCanvas.size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(background.converted(to: space, intent: .defaultIntent, options: nil) ?? background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        // Core Graphics counts y from the bottom; the canvas from the top.
        let f = slide.frame
        ctx.draw(slide.croppedImage, in: CGRect(x: f.minX, y: CGFloat(h) - f.maxY, width: f.width, height: f.height))
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SubtitleError(.unexpected, "Could not write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SubtitleError(.unexpected, "Could not write \(url.lastPathComponent)") }
    }
}

@MainActor
final class MergeModel: ToolModel {
    @Published var audio: URL?
    @Published var audioInfo: ProbeResult?
    /// Where the video is saved and what it is called (next to the audio, or next
    /// to the original video when the audio came from the Cutter).
    @Published var saveFolder: URL?
    @Published var baseName = ""
    @Published var wholeAudio = true
    @Published var fields = RangeFields()
    @Published var slides: [MergeSlide] = []
    @Published var selected: UUID?
    @Published var background = Color.black
    @Published var fadeIn = false
    @Published var fadeOut = false
    @Published var fadeSeconds = 1.0
    @Published var normalize = false

    init() {
        super.init(status: "Add an audio file and one or more images, then click Merge.", channel: .merge)
    }

    // MARK: Adding

    /// Sorts dropped files into the audio (the first audio/video file) and images.
    func add(_ urls: [URL]) {
        var images: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if MergeSlide.imageExtensions.contains(ext) {
                images.append(url)
            } else if JobQueue.videoExtensions.contains(ext) {
                setAudio(url, folder: url.deletingLastPathComponent(), base: url.deletingPathExtension().lastPathComponent)
            } else {
                log(.warning, "Skipped \(url.lastPathComponent): not an audio file or picture.")
            }
        }
        addImages(images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }

    func setAudio(_ url: URL, folder: URL, base: String) {
        audio = url
        audioInfo = nil
        saveFolder = folder
        baseName = base
        wholeAudio = true
        fields = RangeFields()
        Task {
            audioInfo = await probe(url)
            if let info = audioInfo {
                if info.audio.isEmpty { log(.error, "\(url.lastPathComponent) has no audio track.") }
                status = "\(url.lastPathComponent): \(TimeCode.format(info.duration)) of audio."
            }
        }
    }

    func addImages(_ urls: [URL]) {
        for url in urls {
            guard let image = MergeSlide.load(url) else {
                log(.warning, "Could not read the picture \(url.lastPathComponent).")
                continue
            }
            let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let slide = MergeSlide(url: url, image: image, frame: CanvasSnap.fit(aspect: aspect))
            slides.append(slide)
            if selected == nil { selected = slide.id }
        }
    }

    func remove(_ id: UUID) {
        slides.removeAll { $0.id == id }
        if selected == id { selected = slides.first?.id }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = slides.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard slides.indices.contains(j) else { return }
        slides.swapAt(i, j)
    }

    // MARK: Editing the selected picture

    var selectedIndex: Int? { slides.firstIndex { $0.id == selected } }

    func updateSelected(_ change: (inout MergeSlide) -> Void) {
        guard let i = selectedIndex else { return }
        change(&slides[i])
    }

    // MARK: Timing

    var audioRange: Result<ClosedRange<Double>, String> {
        guard let info = audioInfo else { return .failure(audio == nil ? "Add an audio file." : "Reading the audio…") }
        guard !info.audio.isEmpty else { return .failure("The audio file has no audio track.") }
        if wholeAudio { return .success(0...info.duration) }
        return fields.resolve(fileDuration: info.duration).mapError { $0.description }
    }

    var totalLength: Double? {
        if case .success(let r) = audioRange { return r.upperBound - r.lowerBound }
        return nil
    }

    var lengths: [Double]? {
        guard let total = totalLength else { return nil }
        return SlideTimes.lengths(total: total, fixed: slides.map(\.fixedLength))
    }

    /// Why Merge can't run yet, if it can't.
    var problem: String? {
        if case .failure(let message) = audioRange { return message }
        if slides.isEmpty { return "Add at least one image." }
        if lengths == nil { return "The set image times leave too little for the others; shorten them." }
        let fades = (fadeIn ? fadeSeconds : 0) + (fadeOut ? fadeSeconds : 0)
        if let total = totalLength, fades > total { return "The fades are longer than the audio." }
        return nil
    }

    // MARK: Running

    func run() {
        guard problem == nil, let audio, let info = audioInfo, case .success(let range) = audioRange,
              let lengths, let folder = saveFolder else { return }
        let output = Self.uniqueURL(in: folder, base: baseName.isEmpty ? "Merged" : baseName, ext: "mp4")
        let slides = self.slides
        let background = NSColor(background).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1)
        let track = info.audio.first
        let copyAudio = wholeAudio && track?.codecName == "aac" && !fadeIn && !fadeOut && !normalize
        let fadeInLength = fadeIn ? fadeSeconds : 0
        let fadeOutLength = fadeOut ? fadeSeconds : 0
        let normalize = self.normalize
        let channels = track?.channels ?? 2
        let spec = { (files: [String]) -> MergeSpec in
            var s = MergeSpec(slides: zip(files, lengths).map { MergeSpec.Slide(file: $0, length: $1) },
                              audio: audio.path, audioStart: range.lowerBound, audioLength: range.upperBound - range.lowerBound,
                              fadeIn: fadeInLength, fadeOut: fadeOutLength,
                              normalize: normalize, copyAudio: copyAudio, output: output.path)
            s.audioChannels = channels
            return s
        }
        let title = "Merging \(slides.count) image\(slides.count == 1 ? "" : "s") with \(audio.lastPathComponent) "
            + "(\(TimeCode.format(range.upperBound - range.lowerBound)))"
        start(title) { tools in
            let work = AppPaths.cache.appendingPathComponent("merge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var files: [String] = []
            for (i, slide) in slides.enumerated() {
                guard let frame = MergeRenderer.frame(slide, background: background) else {
                    throw SubtitleError(.unexpected, "Could not draw image \(i + 1)")
                }
                let file = work.appendingPathComponent("slide\(i).png")
                try MergeRenderer.writePNG(frame, to: file)
                files.append(file.path)
            }
            try await tools.merge(spec(files))
            return [output]
        }
    }
}
