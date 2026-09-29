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
    static func frame(_ slide: MergeSlide, background: CGColor, texts: [MergeText] = []) -> CGImage? {
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
        // Text boxes on top, in order (later ones above).
        for t in texts where t.shows(on: slide.id) {
            guard let r = TextRenderer.render(t) else { continue }
            ctx.draw(r.image, in: CGRect(x: t.origin.x, y: CGFloat(h) - t.origin.y - r.size.height,
                                         width: r.size.width, height: r.size.height))
        }
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
    /// On by default: YouTube turns loud uploads down but never quiet ones up,
    /// and film soundtracks are mixed far quieter than YouTube's level.
    @Published var normalize = true
    @Published var texts: [MergeText] = []
    @Published var selectedText: UUID?
    /// Font families to offer: the Mac's, with the user's own fonts first.
    @Published private(set) var customFamilies: [String] = []

    struct Snapshot {
        var slides: [MergeSlide]
        var texts: [MergeText]
    }

    /// Earlier states of the pictures and texts (placement, crop, order, times,
    /// text and style) for Undo.
    @Published private(set) var undoStack: [Snapshot] = []
    private var lastTextEdit: (id: UUID, at: Date)?

    init() {
        super.init(status: "Add an audio file and one or more images, then click Merge.", channel: .merge)
        customFamilies = Array(Set(CustomFonts.registerSaved())).sorted()
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
            audioInfo = await probe(url, requireVideo: false)
            if let info = audioInfo {
                if info.audio.isEmpty { log(.error, "\(url.lastPathComponent) has no audio track.") }
                status = "\(url.lastPathComponent): \(TimeCode.format(info.duration)) of audio."
            }
        }
    }

    func addImages(_ urls: [URL]) {
        if !urls.isEmpty { checkpoint() }
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
        checkpoint()
        slides.removeAll { $0.id == id }
        texts.removeAll { $0.slide == id }
        if selected == id { selected = slides.first?.id }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = slides.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard slides.indices.contains(j) else { return }
        checkpoint()
        slides.swapAt(i, j)
    }

    // MARK: Undo

    /// Remembers the pictures as they are now, before a change.
    func checkpoint() {
        undoStack.append(Snapshot(slides: slides, texts: texts))
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        slides = previous.slides
        texts = previous.texts
        if !slides.contains(where: { $0.id == selected }) { selected = slides.first?.id }
        if !texts.contains(where: { $0.id == selectedText }) { selectedText = nil }
        lastTextEdit = nil
    }

    // MARK: Text

    var selectedTextIndex: Int? { texts.firstIndex { $0.id == selectedText } }

    /// Texts shown on the selected picture.
    var visibleTexts: [MergeText] {
        guard let s = selected else { return [] }
        return texts.filter { $0.shows(on: s) }
    }

    func addText() {
        checkpoint()
        var t = MergeText()
        t.slide = selected
        if let size = TextRenderer.render(t)?.size {
            t.origin = CGPoint(x: (MergeCanvas.size.width - size.width) / 2, y: MergeCanvas.size.height * 0.78)
        }
        texts.append(t)
        selectedText = t.id
    }

    /// Changes the selected text. Typing and dragging sliders make many small
    /// changes; they share one Undo step per second.
    func updateText(_ change: (inout MergeText) -> Void) {
        guard let i = selectedTextIndex else { return }
        let now = Date()
        if lastTextEdit?.id != texts[i].id || now.timeIntervalSince(lastTextEdit?.at ?? .distantPast) > 1 { checkpoint() }
        lastTextEdit = (texts[i].id, now)
        change(&texts[i])
    }

    func deleteText() {
        guard let id = selectedText else { return }
        checkpoint()
        texts.removeAll { $0.id == id }
        selectedText = nil
    }

    func addFonts(_ urls: [URL]) {
        var added: [String] = []
        for url in urls {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                added += try CustomFonts.add(url)
            } catch {
                log(.error, "✗ \((error as? SubtitleError)?.description ?? error.localizedDescription)")
            }
        }
        guard !added.isEmpty else { return }
        customFamilies = Array(Set(customFamilies + added)).sorted()
        log(.success, "✓ Font added: \(added.joined(separator: ", ")). It stays available next time.")
        if let first = added.first { updateText { $0.fontFamily = first } }
    }

    func removeFont(family: String) {
        for saved in CustomFonts.saved() where saved.families.contains(family) {
            CustomFonts.remove(saved.file)
            log(.info, "Removed the font \(saved.file.lastPathComponent).")
        }
        customFamilies = Array(Set(CustomFonts.saved().flatMap(\.families))).sorted()
        for i in texts.indices where texts[i].fontFamily == family { texts[i].fontFamily = MergeText().fontFamily }
    }

    // MARK: Editing the selected picture

    var selectedIndex: Int? { slides.firstIndex { $0.id == selected } }

    func updateSelected(_ change: (inout MergeSlide) -> Void) {
        guard let i = selectedIndex else { return }
        checkpoint()
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

    /// A note about how the audio will be prepared, or nil.
    var audioNote: String? {
        guard let track = audioInfo?.audio.first else { return nil }
        if let ch = track.channels, ch > 2 {
            return "\(track.channelLayout ?? "\(ch)-channel") surround audio: it will be mixed down to stereo with the dialogue "
                + "(centre channel) emphasised, as YouTube plays stereo and its own downmix makes speech quieter."
        }
        if !normalize {
            return "Loudness evening is off. YouTube never turns quiet uploads up, so film or recorded audio may play quietly."
        }
        return nil
    }

    // MARK: Running

    func run() {
        guard problem == nil, let audio, let info = audioInfo, case .success(let range) = audioRange,
              let lengths, let folder = saveFolder else { return }
        let output = Self.uniqueURL(in: folder, base: baseName.isEmpty ? "Merged" : baseName, ext: "mp4")
        let slides = self.slides
        let texts = self.texts
        let background = NSColor(background).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1)
        let track = info.audio.first
        let copyAudio = wholeAudio && track?.codecName == "aac" && (track?.channels ?? 2) <= 2 && !fadeIn && !fadeOut && !normalize
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
        // Draw the frames here, on the main thread (AppKit text drawing), then encode.
        let work = AppPaths.cache.appendingPathComponent("merge-\(UUID().uuidString)", isDirectory: true)
        var files: [String] = []
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            for (i, slide) in slides.enumerated() {
                guard let frame = MergeRenderer.frame(slide, background: background, texts: texts) else {
                    throw SubtitleError(.unexpected, "Could not draw image \(i + 1)")
                }
                let file = work.appendingPathComponent("slide\(i).png")
                try MergeRenderer.writePNG(frame, to: file)
                files.append(file.path)
            }
        } catch {
            try? FileManager.default.removeItem(at: work)
            log(.error, "✗ \((error as? SubtitleError)?.description ?? error.localizedDescription)")
            return
        }
        start(title) { tools in
            defer { try? FileManager.default.removeItem(at: work) }
            try await tools.merge(spec(files))
            return [output]
        }
    }
}
