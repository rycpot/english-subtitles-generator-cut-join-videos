import AppKit
import SubtitleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// Loads file URLs from a drop and hands them over together once all are read,
/// so files dropped in one go can be sorted as a group.
func loadDroppedURLs(_ providers: [NSItemProvider], _ handle: @escaping ([URL]) -> Void) -> Bool {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let all = urls
        guard !all.isEmpty else { return }
        Task { @MainActor in handle(all) }
    }
    return true
}

/// A compact drop target with a "Choose…" button.
struct SmallDropArea: View {
    let title: String
    let allowsMultiple: Bool
    let onFiles: ([URL]) -> Void
    @State private var isTargeted = false
    @State private var showImporter = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 20))
                .foregroundColor(Theme.mint)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Button(allowsMultiple ? "Choose Files…" : "Choose File…") { showImporter = true }
                .buttonStyle(.pillProminent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(isTargeted ? Theme.mint.opacity(0.08) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            .foregroundColor(isTargeted ? Theme.mint : Theme.border))
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedURLs(providers, onFiles)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .audiovisualContent],
                      allowsMultipleSelection: allowsMultiple) { result in
            if case .success(let urls) = result { onFiles(urls) }
        }
    }
}

/// A monospaced time field ("00:20:00").
struct TimeField: View {
    let label: String
    @Binding var text: String
    var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(Theme.textFaint)
            TextField("00:00:00", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 130)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.logBackground))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(invalid ? Theme.error : Theme.border, lineWidth: 1))
        }
    }
}

/// A time picked from dropdowns: hours : minutes : seconds : frame. Each
/// dropdown only offers values up to `limit` (seconds), so only times inside
/// the video can be picked; hours are disabled for videos under an hour.
/// The value is stored as text ("00:02:07.792"), like the rest of the range.
struct TimeDropdowns: View {
    let label: String
    @Binding var text: String
    let limit: Double
    let frameDuration: Double
    var invalid = false

    private var clock: FrameClock { FrameClock(frameDuration: frameDuration) }
    private var limitTime: FrameTime { clock.time(max(0, limit)) }
    private var value: FrameTime { clock.clamp(clock.time(TimeCode.parse(text) ?? 0), to: limitTime) }

    var body: some View {
        let choices = clock.choices(for: value, limit: limitTime)
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundColor(Theme.textFaint)
            HStack(spacing: 2) {
                unit(\.hours, choices.hours, caption: "h").disabled(limitTime.hours == 0)
                colon
                unit(\.minutes, choices.minutes, caption: "m")
                colon
                unit(\.seconds, choices.seconds, caption: "s")
                Text("·").font(.system(size: 14, design: .monospaced)).foregroundColor(Theme.textFaint)
                unit(\.frame, choices.frames, caption: "frame")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.logBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(invalid ? Theme.error : Theme.border, lineWidth: 1))
            .contextMenu {
                Button("Copy Time") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TimeCode.format(clock.seconds(value)), forType: .string)
                }
                Button("Paste Time") {
                    if let s = NSPasteboard.general.string(forType: .string), let t = TimeCode.parse(s) {
                        set(clock.clamp(clock.time(t), to: limitTime))
                    }
                }
            }
        }
        .onAppear(perform: normalize)
        .onChange(of: limit) { _ in normalize() }
    }

    private var colon: some View {
        Text(":").font(.system(size: 14, design: .monospaced)).foregroundColor(Theme.textFaint)
    }

    private func unit(_ key: WritableKeyPath<FrameTime, Int>, _ range: ClosedRange<Int>, caption: String) -> some View {
        Picker("", selection: Binding(get: { min(max(value[keyPath: key], range.lowerBound), range.upperBound) },
                                      set: { newValue in
                                          var t = value
                                          t[keyPath: key] = newValue
                                          set(clock.clamp(t, to: limitTime))
                                      })) {
            ForEach(Array(range), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .font(.system(size: 13, design: .monospaced))
        .frame(width: 58)
        .help(caption == "frame" ? "Frame within the second" : (caption == "h" ? "Hours" : caption == "m" ? "Minutes" : "Seconds"))
    }

    private func set(_ t: FrameTime) {
        text = TimeCode.format(clock.seconds(t))
    }

    /// A stored time past the limit (a new file, or a later start) is pulled back to it.
    private func normalize() {
        if let t = TimeCode.parse(text), t <= clock.seconds(limitTime) + frameDuration / 2 { return }
        set(value)
    }
}

/// Start + (end time | duration) with frame previews.
struct RangeEditor: View {
    @Binding var fields: RangeFields
    let fileDuration: Double?
    let frameDuration: Double
    let preview: RangePreview

    var body: some View {
        let result = fields.resolve(fileDuration: fileDuration)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 14) {
                TimeDropdowns(label: "Start", text: $fields.start, limit: startLimit,
                              frameDuration: frameDuration, invalid: result.isBadStart)
                Picker("", selection: $fields.endMode) {
                    ForEach(EndMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                TimeDropdowns(label: fields.endMode == .endTime ? "End" : "Length", text: $fields.end,
                              limit: endLimit, frameDuration: frameDuration, invalid: result.isBadEnd)
                Spacer()
            }
            switch result {
            case .success(let r):
                Text("\(TimeCode.format(r.lowerBound)) → \(TimeCode.format(r.upperBound))  ·  \(TimeCode.format(r.upperBound - r.lowerBound)) long")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.mint)
            case .failure(let error):
                Text(error.description)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.error)
            }
            if preview.start != nil || preview.end != nil {
                HStack(spacing: 10) {
                    FramePreview(image: preview.start, caption: "First frame")
                    FramePreview(image: preview.end, caption: "Last frame")
                }
            }
        }
    }
}

extension RangeEditor {
    private var videoLength: Double { (fileDuration ?? 0) > 0 ? fileDuration! : 100 * 3600 - 1 }
    /// The last frame can still start a cut.
    fileprivate var startLimit: Double { max(0, videoLength - frameDuration) }
    fileprivate var endLimit: Double {
        fields.endMode == .endTime ? videoLength : max(0, videoLength - (TimeCode.parse(fields.start) ?? 0))
    }
}

private extension Result where Success == ClosedRange<Double>, Failure == RangeError {
    var isBadStart: Bool {
        guard case .failure(let e) = self else { return false }
        switch e {
        case .badStart, .startPastEnd: return true
        default: return false
        }
    }

    var isBadEnd: Bool {
        guard case .failure(let e) = self else { return false }
        switch e {
        case .badEnd, .badDuration, .endPastEnd, .notAfterStart: return true
        default: return false
        }
    }
}

struct FramePreview: View {
    let image: NSImage?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Theme.logBackground)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ProgressView().scaleEffect(0.5)
                }
            }
            .frame(width: 176, height: 99)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            Text(caption)
                .font(.system(size: 10))
                .foregroundColor(Theme.textFaint)
        }
    }
}

/// Status line, progress bar and cancel button for a tool.
struct ToolProgress: View {
    @ObservedObject var model: ToolModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.isRunning {
                    Text("\(Int(model.progress * 100))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Theme.mint)
                    Button("Cancel") { model.cancel() }.buttonStyle(.pillSmall)
                } else if let first = model.lastOutputs.first {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.lastOutputs.isEmpty ? [first] : model.lastOutputs) }
                        .buttonStyle(.pillSmall)
                }
            }
            ProgressBar(value: model.progress)
        }
    }
}

// MARK: - Cutter

struct CutterView: View {
    @ObservedObject var model: CutterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let file = model.file {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                SectionTitle("Video")
                                Text(file.lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(model.info.map { "\(TimeCode.format($0.duration)) · \($0.formatSummary)" } ?? "Reading…")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textFaint)
                            }
                            Spacer()
                            Button("Change…") { model.file = nil }.buttonStyle(.pillSmall).disabled(model.isRunning)
                        }
                        SectionTitle("Range")
                        RangeEditor(fields: $model.fields, fileDuration: model.info?.duration,
                                    frameDuration: model.info?.frameDuration ?? 0.04, preview: model.preview)
                        splitSection
                    }
                }
                HStack {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button(model.splitKind == .none ? "Cut" : "Cut and Split") { model.run() }
                        .buttonStyle(.pillProminent)
                        .disabled(model.isRunning || model.info == nil || !canRun)
                }
            } else {
                SmallDropArea(title: "Drop a video to cut", allowsMultiple: false) { urls in
                    if let url = urls.first { model.load(url) }
                }
            }
            ToolProgress(model: model)
        }
    }

    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Split the cut")
            HStack(spacing: 12) {
                Picker("", selection: $model.splitKind) {
                    ForEach(SplitKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                switch model.splitKind {
                case .none:
                    EmptyView()
                case .count:
                    TextField("4", text: $model.splitCount)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(width: 60)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.logBackground))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    Stepper("", value: Binding(get: { Int(model.splitCount.trimmingCharacters(in: .whitespaces)) ?? 4 },
                                               set: { model.splitCount = String($0) }),
                            in: 2...500)
                        .labelsHidden()
                        .help("More or fewer parts")
                    Text("parts").font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                case .length:
                    TimeField(label: "Each part", text: $model.splitLength)
                }
                Spacer()
            }
        }
    }

    private var canRun: Bool {
        if case .success = model.plannedRanges { return true }
        return false
    }

    private var summary: String {
        switch model.plannedRanges {
        case .failure(let message):
            return message
        case .success(let ranges):
            if ranges.count == 1 { return "Creates 1 file next to the original." }
            let lengths = Set(ranges.map { TimeCode.format($0.end - $0.start) })
            return "Creates \(ranges.count) files next to the original"
                + (lengths.count == 1 ? ", \(lengths.first!) each." : " (the last one shorter).")
        }
    }
}

// MARK: - Joiner

struct JoinerView: View {
    @ObservedObject var model: JoinerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SmallDropArea(title: model.pieces.isEmpty ? "Drop videos to join" : "Drop more videos to add them",
                          allowsMultiple: true) { model.add($0) }
            if !model.pieces.isEmpty {
                HStack {
                    SectionTitle("Pieces, in order")
                    Spacer()
                    Text("Drag to reorder, or sort:")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textFaint)
                    Menu {
                        ForEach(JoinSortKey.allCases) { key in
                            Button(key == .name ? "Name (natural)" : key.rawValue) {
                                model.sort(by: key, ascending: model.sortAscending)
                            }
                        }
                    } label: {
                        Text(model.sortKey == .name ? "Name (natural)" : model.sortKey.rawValue)
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.isRunning)
                    Button { model.sort(by: model.sortKey, ascending: !model.sortAscending) } label: {
                        Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
                    }
                    .buttonStyle(.pillSmall)
                    .help(model.sortAscending ? "Ascending: click for descending" : "Descending: click for ascending")
                    .disabled(model.isRunning)
                }
                List {
                    ForEach(Array(model.pieces.enumerated()), id: \.element.id) { index, piece in
                        JoinPieceRow(model: model, piece: piece, number: index + 1, count: model.pieces.count)
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 4)
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .frame(minHeight: 150, maxHeight: 330)
                .background(Theme.background)
                if model.formatsDiffer { matchPicker }
                HStack {
                    Text(model.problem ?? "\(model.pieces.count) pieces, \(TimeCode.format(model.totalDuration)) in total. Saved next to the first file.")
                        .font(.system(size: 11))
                        .foregroundColor(model.problem == nil ? Theme.textSecondary : Theme.warning)
                    Spacer()
                    Button("Clear") { model.pieces.removeAll() }
                        .buttonStyle(.pillSmall)
                        .disabled(model.isRunning)
                    Button("Join") { model.run() }
                        .buttonStyle(.pillProminent)
                        .disabled(model.isRunning || model.problem != nil)
                }
            }
            ToolProgress(model: model)
        }
    }

    /// Shown when pieces differ in size/frame rate/format: which one to match.
    private var matchPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warning)
                Text("These videos have different formats, so they will be converted to one. Match:")
                    .font(.system(size: 12))
                Picker("", selection: $model.matchPiece) {
                    Text("Automatic" + (model.autoMatchPiece.map { " (\($0.info?.formatSummary ?? ""))" } ?? ""))
                        .tag(UUID?.none)
                    ForEach(Array(model.pieces.enumerated()), id: \.element.id) { index, piece in
                        Text("Piece \(index + 1): \(piece.info?.formatSummary ?? "…")").tag(UUID?.some(piece.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            Text("Automatic picks the format that makes up most of the running time, so the least video is converted.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textFaint)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.08)))
    }
}

struct JoinPieceRow: View {
    @ObservedObject var model: JoinerModel
    let piece: JoinPiece
    let number: Int
    let count: Int

    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.onAccent)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.accent))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(piece.url.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(piece.info.map { "\(TimeCode.format($0.duration)) · \($0.formatSummary)" }
                             ?? (piece.loadFailed ? "Could not read this file" : "Reading…"))
                            .font(.system(size: 10))
                            .foregroundColor(piece.loadFailed ? Theme.error : Theme.textFaint)
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { piece.whole }, set: { model.update(piece.id, whole: $0) })) {
                        Text("Whole file").tag(true)
                        Text("Cut").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    Button { model.move(piece.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.pillSmall).disabled(number == 1)
                        .help("Move up")
                    Button { model.move(piece.id, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.pillSmall).disabled(number == count)
                        .help("Move down")
                    Button { model.addCut(after: piece.id) } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                        .buttonStyle(.pillSmall)
                        .help("Add another cut from this file")
                    Button { model.remove(piece.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.pillSmall)
                        .help("Remove")
                }
                if !piece.whole {
                    RangeEditor(fields: Binding(get: { piece.fields }, set: { model.update(piece.id, fields: $0) }),
                                fileDuration: piece.info?.duration,
                                frameDuration: piece.info?.frameDuration ?? 0.04, preview: piece.preview)
                }
            }
        }
        .disabled(model.isRunning)
    }
}
