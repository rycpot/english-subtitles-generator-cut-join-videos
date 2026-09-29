import AppKit
import SubtitleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Merge tab

struct MergeView: View {
    @ObservedObject var model: MergeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SmallDropArea(title: model.slides.isEmpty && model.audio == nil
                              ? "Drop an audio file and images (or a video, for its audio)"
                              : "Drop more images, or another audio file",
                              allowsMultiple: true, types: [.audio, .movie, .audiovisualContent, .image]) { model.add($0) }
                if model.audio != nil { audioCard }
                if !model.slides.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Canvas · 1920 × 1080")
                            MergeCanvasEditor(model: model)
                            slideStrip
                            if let i = model.selectedIndex { slideTiming(i) }
                        }
                    }
                }
                optionsCard
                HStack {
                    Text(model.problem ?? summary)
                        .font(.system(size: 11))
                        .foregroundColor(model.problem == nil ? Theme.textSecondary : Theme.warning)
                    Spacer()
                    Button("Merge") { model.run() }
                        .buttonStyle(.pillProminent)
                        .disabled(model.isRunning || model.problem != nil)
                }
                ToolProgress(model: model)
            }
            .padding(.trailing, 4)
        }
    }

    private var summary: String {
        let n = model.slides.count
        return "\(n) image\(n == 1 ? "" : "s"), \(TimeCode.format(model.totalLength ?? 0)). "
            + "Saved as a YouTube-ready 1080p .mp4 next to \(model.saveFolder?.lastPathComponent ?? "the audio")."
    }

    private var audioCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionTitle("Audio")
                        Text(model.audio?.lastPathComponent ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.audioInfo.map { info in
                            "\(TimeCode.format(info.duration))" + (info.audio.first.map { " · \($0.audioLabel)" } ?? "")
                        } ?? "Reading…")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textFaint)
                    }
                    Spacer()
                    Picker("", selection: $model.wholeAudio) {
                        Text("Whole audio").tag(true)
                        Text("Part").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
                if !model.wholeAudio, let info = model.audioInfo {
                    RangeEditor(fields: $model.fields, fileDuration: info.duration, frameDuration: 0.1,
                                preview: RangePreview())
                }
            }
        }
        .disabled(model.isRunning)
    }

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Options")
                HStack(spacing: 16) {
                    Toggle("Fade in", isOn: $model.fadeIn)
                    Toggle("Fade out", isOn: $model.fadeOut)
                    Stepper(value: $model.fadeSeconds, in: 0.5...5, step: 0.5) {
                        Text(String(format: "%.1f s", model.fadeSeconds))
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .disabled(!model.fadeIn && !model.fadeOut)
                    .help("Length of the fades from and to black (with the sound)")
                    Spacer()
                }
                Toggle("Even out the loudness for YouTube (-14 LUFS)", isOn: $model.normalize)
                    .help("YouTube turns louder uploads down to about -14 LUFS; this matches it and keeps peaks from clipping.")
            }
            .font(.system(size: 12))
        }
        .disabled(model.isRunning)
    }

    // MARK: Slides

    private var slideStrip: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(Array(model.slides.enumerated()), id: \.element.id) { i, slide in
                    let isSelected = slide.id == model.selected
                    VStack(spacing: 4) {
                        ZStack(alignment: .topLeading) {
                            SlideThumbnail(slide: slide, background: model.background)
                                .frame(width: 128, height: 72)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(isSelected ? Theme.mint : Theme.border, lineWidth: isSelected ? 2 : 1))
                            Text("\(i + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.onAccent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent))
                                .padding(4)
                        }
                        .onTapGesture { model.selected = slide.id }
                        HStack(spacing: 2) {
                            Button { model.move(slide.id, by: -1) } label: { Image(systemName: "chevron.left") }
                                .disabled(i == 0).help("Move earlier")
                            Text(model.lengths.map { TimeCode.format($0[i]) } ?? "–")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(slide.fixedLength == nil ? Theme.textSecondary : Theme.mint)
                                .frame(minWidth: 62)
                            Button { model.move(slide.id, by: 1) } label: { Image(systemName: "chevron.right") }
                                .disabled(i == model.slides.count - 1).help("Move later")
                            Button { model.remove(slide.id) } label: { Image(systemName: "trash") }.help("Remove")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(model.isRunning)
    }

    /// How long the selected picture shows: an equal share, or a set time.
    private func slideTiming(_ i: Int) -> some View {
        let slide = model.slides[i]
        let total = model.totalLength ?? 0
        return HStack(alignment: .center, spacing: 12) {
            Text("Image \(i + 1) shows for").font(.system(size: 12))
            if model.slides.count == 1 {
                Text("the whole audio").font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            } else if slide.fixedLength == nil {
                Text("an equal share (\(model.lengths.map { TimeCode.format($0[i]) } ?? "–"))")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                Button("Set a time") {
                    let current = model.lengths?[i] ?? 5
                    model.updateSelected { $0.fixedLength = current }
                }
                    .buttonStyle(.pillSmall)
            } else {
                TimeDropdowns(label: "Length", text: Binding(
                    get: { TimeCode.format(model.slides[safe: i]?.fixedLength ?? 0) },
                    set: { v in model.updateSelected { $0.fixedLength = max(0.5, TimeCode.parse(v) ?? 0.5) } }),
                              limit: total, frameDuration: 1.0 / 30)
                Button("Equal share") { model.updateSelected { $0.fixedLength = nil } }
                    .buttonStyle(.pillSmall)
            }
            Spacer()
        }
        .disabled(model.isRunning || total == 0)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A small picture of how a slide's frame looks.
struct SlideThumbnail: View {
    let slide: MergeSlide
    let background: Color

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / MergeCanvas.size.width
            ZStack(alignment: .topLeading) {
                background
                Image(decorative: slide.croppedImage, scale: 1)
                    .resizable()
                    .frame(width: slide.frame.width * s, height: slide.frame.height * s)
                    .offset(x: slide.frame.minX * s, y: slide.frame.minY * s)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Canvas

/// The 1920 × 1080 canvas for the selected picture, after the design editor:
/// drag the picture (it sticks to the canvas edges and centre lines, with a
/// guide showing which; hold ⌥ to move freely), resize from the corners with
/// its proportions kept, crop, fit or fill, and zoom.
struct MergeCanvasEditor: View {
    @ObservedObject var model: MergeModel
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var cropping = false
    @State private var dragStart: CGRect?
    @State private var cropStart: CGRect?
    /// The whole picture's place while cropping (it stays put; the crop window moves).
    @State private var cropFull: CGRect?
    @State private var guideX: CGFloat?
    @State private var guideY: CGFloat?

    /// Canvas pixels within this many screen points stick.
    private let snapPoints: CGFloat = 8
    private let viewWidth: CGFloat = 720

    private var scale: CGFloat { viewWidth / MergeCanvas.size.width * zoom }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            ScrollView([.horizontal, .vertical]) {
                canvas
                    .padding(14)
            }
            .frame(height: MergeCanvas.size.height * viewWidth / MergeCanvas.size.width + 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.logBackground))
            .gesture(MagnificationGesture()
                .onChanged { v in
                    let base = pinchStart ?? zoom
                    pinchStart = base
                    zoom = min(4, max(0.25, base * v))
                }
                .onEnded { _ in pinchStart = nil })
        }
        .disabled(model.isRunning)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Fit") { place(fill: false) }.buttonStyle(.pillSmall)
                .help("Show the whole picture, centred")
            Button("Fill") { place(fill: true) }.buttonStyle(.pillSmall)
                .help("Cover the whole canvas, centred")
            Button(cropping ? "Done" : "Crop") { toggleCrop() }
                .buttonStyle(cropping ? .pillProminent : .pillSmall)
                .help("Trim the picture's edges with the handles")
            if let slide = model.slides[safe: model.selectedIndex ?? -1], slide.crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
                Button("Reset crop") { resetCrop() }.buttonStyle(.pillSmall)
            }
            ColorPicker("Background", selection: $model.background, supportsOpacity: false)
                .font(.system(size: 11))
                .help("Colour of any canvas area the picture doesn't cover")
            Spacer()
            Text("⌥ drag: no snapping").font(.system(size: 10)).foregroundColor(Theme.textFaint)
            Button { zoom = max(0.25, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.pillSmall)
            Text("\(Int((zoom * 100).rounded()))%").font(.system(size: 11, design: .monospaced)).frame(width: 44)
            Button { zoom = min(4, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.pillSmall)
            Button("Fit view") { zoom = 1 }.buttonStyle(.pillSmall)
        }
    }

    // MARK: Drawing

    @ViewBuilder private var canvas: some View {
        let w = MergeCanvas.size.width * scale
        let h = MergeCanvas.size.height * scale
        if let i = model.selectedIndex {
            let slide = model.slides[i]
            ZStack(alignment: .topLeading) {
                // The canvas and the picture, clipped to the canvas like the video.
                ZStack(alignment: .topLeading) {
                    model.background
                    if cropping, let full = cropFull {
                        picture(Image(decorative: slide.image, scale: 1), in: full).opacity(0.3)
                    }
                    picture(Image(decorative: slide.croppedImage, scale: 1), in: slide.frame)
                        .gesture(moveGesture(i), including: cropping ? .none : .all)
                        .onHover { inside in (inside && !cropping ? NSCursor.openHand : NSCursor.arrow).set() }
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .clipped()
                // Canvas border.
                Rectangle().stroke(Theme.border, lineWidth: 1).frame(width: w, height: h).allowsHitTesting(false)
                // The picture's full extent past the canvas, faintly, so it can be found and resized.
                Rectangle().stroke(Theme.mint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: slide.frame.width * scale, height: slide.frame.height * scale)
                    .offset(x: slide.frame.minX * scale, y: slide.frame.minY * scale)
                    .allowsHitTesting(false)
                guides(w: w, h: h)
                if cropping {
                    cropHandles(i, slide)
                } else {
                    resizeHandles(i, slide)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
    }

    private func picture(_ image: Image, in rect: CGRect) -> some View {
        image.resizable()
            .frame(width: max(1, rect.width * scale), height: max(1, rect.height * scale))
            .offset(x: rect.minX * scale, y: rect.minY * scale)
    }

    @ViewBuilder private func guides(w: CGFloat, h: CGFloat) -> some View {
        if let gx = guideX {
            Rectangle().fill(Color(hex: 0xFF3EA5)).frame(width: 1.5, height: h).offset(x: gx * scale - 0.75)
                .allowsHitTesting(false)
        }
        if let gy = guideY {
            Rectangle().fill(Color(hex: 0xFF3EA5)).frame(width: w, height: 1.5).offset(y: gy * scale - 0.75)
                .allowsHitTesting(false)
        }
    }

    private func handle() -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.accent, lineWidth: 1.5))
            .frame(width: 10, height: 10)
    }

    // MARK: Moving and resizing

    private var snapping: Bool { !NSEvent.modifierFlags.contains(.option) }

    private func moveGesture(_ i: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = dragStart ?? model.slides[i].frame
                dragStart = start
                let moved = start.offsetBy(dx: v.translation.width / scale, dy: v.translation.height / scale)
                let r = snapping ? CanvasSnap.drag(moved, threshold: snapPoints / scale)
                                 : CanvasSnap.Result(rect: moved, guideX: nil, guideY: nil)
                model.slides[i].frame = r.rect
                guideX = r.guideX
                guideY = r.guideY
            }
            .onEnded { _ in endDrag() }
    }

    private func resizeHandles(_ i: Int, _ slide: MergeSlide) -> some View {
        let f = slide.frame
        let corners = [(CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.maxY)),
                       (CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY)),
                       (CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.minY)),
                       (CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.minY))]
        return ZStack(alignment: .topLeading) {
            Rectangle().stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: f.width * scale, height: f.height * scale)
                .offset(x: f.minX * scale, y: f.minY * scale)
                .allowsHitTesting(false)
            ForEach(0..<4, id: \.self) { c in
                let corner = corners[c].0
                handle()
                    .offset(x: corner.x * scale - 5, y: corner.y * scale - 5)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let start = dragStart ?? model.slides[i].frame
                            dragStart = start
                            let startCorners = [CGPoint(x: start.minX, y: start.minY), CGPoint(x: start.maxX, y: start.minY),
                                                CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX, y: start.maxY)]
                            let anchor = startCorners[(c + 2) % 4]
                            let point = CGPoint(x: startCorners[c].x + v.translation.width / scale,
                                                y: startCorners[c].y + v.translation.height / scale)
                            let r = CanvasSnap.resize(anchor: anchor, to: point, aspect: start.width / start.height,
                                                      threshold: snapPoints / scale, snap: snapping)
                            model.slides[i].frame = r.rect
                            guideX = r.guideX
                            guideY = r.guideY
                        }
                        .onEnded { _ in endDrag() })
                    .onHover { inside in (inside ? NSCursor.crosshair : NSCursor.arrow).set() }
            }
        }
    }

    private func endDrag() {
        dragStart = nil
        cropStart = nil
        guideX = nil
        guideY = nil
    }

    private func place(fill: Bool) {
        model.updateSelected { s in
            s.frame = fill ? CanvasSnap.fill(aspect: s.aspect) : CanvasSnap.fit(aspect: s.aspect)
        }
    }

    // MARK: Cropping

    private func toggleCrop() {
        if cropping {
            cropping = false
            cropFull = nil
        } else if let i = model.selectedIndex {
            cropFull = CropMath.fullFrame(visible: model.slides[i].frame, crop: model.slides[i].crop)
            cropping = true
        }
    }

    private func resetCrop() {
        model.updateSelected { s in
            s.frame = CropMath.fullFrame(visible: s.frame, crop: s.crop)
            s.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if cropping, let i = model.selectedIndex { cropFull = model.slides[i].frame }
    }

    private func cropHandles(_ i: Int, _ slide: MergeSlide) -> some View {
        let f = slide.frame
        let points: [(CropMath.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: f.minX, y: f.minY)), (.top, CGPoint(x: f.midX, y: f.minY)),
            (.topRight, CGPoint(x: f.maxX, y: f.minY)), (.right, CGPoint(x: f.maxX, y: f.midY)),
            (.bottomRight, CGPoint(x: f.maxX, y: f.maxY)), (.bottom, CGPoint(x: f.midX, y: f.maxY)),
            (.bottomLeft, CGPoint(x: f.minX, y: f.maxY)), (.left, CGPoint(x: f.minX, y: f.midY)),
        ]
        return ZStack(alignment: .topLeading) {
            Rectangle().stroke(Theme.mint, lineWidth: 1.5)
                .frame(width: f.width * scale, height: f.height * scale)
                .offset(x: f.minX * scale, y: f.minY * scale)
                .allowsHitTesting(false)
            ForEach(0..<points.count, id: \.self) { k in
                let h = points[k].0
                let p = points[k].1
                handle()
                    .offset(x: p.x * scale - 5, y: p.y * scale - 5)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard let full = cropFull else { return }
                            let start = cropStart ?? model.slides[i].crop
                            cropStart = start
                            let delta = CGVector(dx: v.translation.width / scale / full.width,
                                                 dy: v.translation.height / scale / full.height)
                            let crop = CropMath.drag(start, handle: h, by: delta)
                            model.slides[i].crop = crop
                            model.slides[i].frame = CropMath.visibleFrame(full: full, crop: crop)
                        }
                        .onEnded { _ in endDrag() })
            }
        }
    }
}
