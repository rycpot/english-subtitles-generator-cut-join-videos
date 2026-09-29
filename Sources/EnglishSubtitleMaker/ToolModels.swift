import AppKit
import Foundation
import SubtitleCore

/// Previews of the first and last frame of a range.
struct RangePreview: Equatable {
    var start: NSImage?
    var end: NSImage?
}

/// Shared by the Cutter and Joiner: running one job at a time with progress.
@MainActor
class ToolModel: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var status: String
    @Published var lastOutputs: [URL] = []
    /// The tab whose log this tool writes to.
    let channel: AppTab
    private var worker: Task<Void, Never>?

    init(status: String, channel: AppTab) {
        self.status = status
        self.channel = channel
    }

    func log(_ level: LogLevel, _ text: String) {
        JobQueue.shared.append(level, text, to: channel)
    }

    func makeTools() throws -> MediaTools {
        let channel = self.channel
        return try MediaTools.make(
            log: { level, text in Task { @MainActor in JobQueue.shared.append(level, text, to: channel) } },
            progress: { [weak self] value, step in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.progress = max(self.progress, value)
                    self.status = step
                }
            })
    }

    /// Runs `body` as the current job; errors are reported with their codes.
    func start(_ title: String, _ body: @escaping (MediaTools) async throws -> [URL]) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        lastOutputs = []
        status = "Starting…"
        log(.info, "▶︎ \(title)")
        let started = Date()
        worker = Task {
            defer {
                isRunning = false
                worker = nil
            }
            do {
                let tools = try makeTools()
                let outputs = try await body(tools)
                progress = 1
                lastOutputs = outputs
                let secs = Int(Date().timeIntervalSince(started))
                for url in outputs { log(.success, "✓ Saved \(url.lastPathComponent)") }
                status = "Done in \(secs / 60) min \(secs % 60) s."
            } catch is CancellationError {
                log(.warning, "✗ \(ErrorCode.cancelled.rawValue) Cancelled.")
                status = "Cancelled."
            } catch let error as SubtitleError {
                log(.error, "✗ \(error.description)")
                log(.detail, "→ \(error.code.hint)")
                status = "Failed: \(error.code.rawValue) \(error.code.title)"
            } catch {
                log(.error, "✗ \(ErrorCode.unexpected.rawValue) \(error.localizedDescription)")
                status = "Failed."
            }
        }
    }

    func cancel() {
        worker?.cancel()
    }

    /// Probes a file for the editors (length, format), logging problems.
    func probe(_ url: URL, requireVideo: Bool = true) async -> ProbeResult? {
        do {
            return try await makeTools().probe(url, requireVideo: requireVideo)
        } catch let error as SubtitleError {
            log(.error, "✗ \(error.description)")
            return nil
        } catch {
            return nil
        }
    }

    /// Stills of the first frame and the last frame of a range.
    func previews(_ url: URL, probe: ProbeResult, range: ClosedRange<Double>) async -> RangePreview {
        guard let tools = try? makeTools(), let v = probe.video else { return RangePreview() }
        let lastFrame = max(range.lowerBound, range.upperBound - probe.frameDuration)
        async let a = tools.thumbnail(url, at: range.lowerBound, videoIndex: v.index)
        async let b = tools.thumbnail(url, at: lastFrame, videoIndex: v.index)
        return RangePreview(start: await a, end: await b)
    }

    /// "Movie [00.20.00–00.22.00].mkv", with " (2)" etc. if it exists.
    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

/// What the Cutter writes: the whole video, or one audio track only.
enum CutOutput: String, CaseIterable, Identifiable {
    case video = "Video + audio"
    case audio = "Audio only"
    var id: String { rawValue }
}

enum SplitKind: String, CaseIterable, Identifiable {
    case none = "Don't split"
    case count = "Into equal parts"
    case length = "Into parts of"
    var id: String { rawValue }
}

@MainActor
final class CutterModel: ToolModel {
    @Published var file: URL?
    @Published var info: ProbeResult?
    @Published var fields = RangeFields() {
        didSet { if fields != oldValue { schedulePreview() } }
    }
    @Published var output: CutOutput = .video
    /// The audio track to extract (a stream index); nil = the default track.
    @Published var audioTrack: Int?
    @Published var splitKind: SplitKind = .none
    @Published var splitCount = "4"
    @Published var splitLength = "00:00:30"
    @Published var preview = RangePreview()
    private var previewTask: Task<Void, Never>?

    init() {
        super.init(status: "Drop a video to cut.", channel: .cutter)
    }

    var range: Result<ClosedRange<Double>, RangeError> {
        fields.resolve(fileDuration: info?.duration)
    }

    var splitMode: Result<SplitMode, String> {
        switch splitKind {
        case .none:
            return .success(.none)
        case .count:
            guard let n = Int(splitCount.trimmingCharacters(in: .whitespaces)), (2...500).contains(n) else {
                return .failure("Number of parts must be between 2 and 500.")
            }
            return .success(.count(n))
        case .length:
            guard let l = TimeCode.parse(splitLength), l >= 0.5 else {
                return .failure("Part length isn't valid. Use hh:mm:ss, for example 00:00:30.")
            }
            return .success(.length(l))
        }
    }

    /// The audio stream "Audio only" extracts: the picked one, else the default track.
    var chosenAudio: ProbeStream? {
        guard let tracks = info?.audio, !tracks.isEmpty else { return nil }
        return tracks.first { $0.index == audioTrack }
            ?? tracks.first { $0.disposition?["default"] == 1 } ?? tracks.first
    }

    /// The ranges that will be written, or what is wrong.
    var plannedRanges: Result<[(start: Double, end: Double)], String> {
        if output == .audio, info != nil, chosenAudio == nil { return .failure("This file has no audio track.") }
        switch (range, splitMode) {
        case (.failure(let e), _): return .failure(e.description)
        case (_, .failure(let e)): return .failure(e)
        case (.success(let r), .success(let mode)):
            let parts = RangeSplitter.split(start: r.lowerBound, end: r.upperBound, mode: mode)
            return parts.count > 500 ? .failure("That would make \(parts.count) files; use longer parts.") : .success(parts)
        }
    }

    func load(_ url: URL) {
        file = url
        info = nil
        audioTrack = nil
        preview = RangePreview()
        status = "Reading \(url.lastPathComponent)…"
        Task {
            info = await probe(url)
            if let info {
                status = "\(url.lastPathComponent): \(TimeCode.format(info.duration)) long. Set the range and click Cut."
                schedulePreview()
            } else {
                status = "Could not read \(url.lastPathComponent)."
            }
        }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard let file, let info, case .success(let r) = range else {
            preview = RangePreview()
            return
        }
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let p = await previews(file, probe: info, range: r)
            if !Task.isCancelled { preview = p }
        }
    }

    func run() {
        guard let file, let info, case .success(let ranges) = plannedRanges else { return }
        let base = file.deletingPathExtension().lastPathComponent
        let folder = file.deletingLastPathComponent()
        let audio = output == .audio ? chosenAudio : nil
        if output == .audio, audio == nil { return }
        let ext = audio.map { AudioFiles.fileExtension(forCodec: $0.codecName) }
            ?? (file.pathExtension.isEmpty ? "mkv" : file.pathExtension)
        guard case .success(let whole) = range else { return }
        let label = "[\(TimeCode.fileSafe(whole.lowerBound))–\(TimeCode.fileSafe(whole.upperBound))]"
        let what = audio.map { "the audio (\($0.audioLabel)) of " } ?? ""
        let title = ranges.count == 1
            ? "Cutting \(what)\(file.lastPathComponent) \(TimeCode.format(whole.lowerBound))–\(TimeCode.format(whole.upperBound))"
            : "Cutting \(what)\(file.lastPathComponent) into \(ranges.count) parts"
        start(title) { tools in
            var outputs: [URL] = []
            for (i, r) in ranges.enumerated() {
                try Task.checkCancellation()
                var name = ranges.count == 1 ? "\(base) \(label)" : "\(base) \(label) part \(i + 1) of \(ranges.count)"
                if audio != nil { name += " audio" }
                let out = Self.uniqueURL(in: folder, base: name, ext: ext)
                await MainActor.run { self.status = "Part \(i + 1) of \(ranges.count)…" }
                let piece = MediaPiece(url: file, probe: info, start: r.start, end: r.end)
                if let audio {
                    try await tools.extractAudio(piece, streamIndex: audio.index, to: out)
                } else {
                    try await tools.render([piece], to: out)
                }
                outputs.append(out)
            }
            return outputs
        }
    }
}

extension CutterModel {
    /// Cuts the audio-only range into a temporary file and hands it to Merge;
    /// nothing is saved next to the original.
    func sendToMerge(_ handoff: @escaping (URL, URL, String) -> Void) {
        guard output == .audio, let file, let info, let audio = chosenAudio,
              case .success(let ranges) = plannedRanges, ranges.count == 1, let r = ranges.first else { return }
        let base = file.deletingPathExtension().lastPathComponent
        let name = "\(base) [\(TimeCode.fileSafe(r.start))–\(TimeCode.fileSafe(r.end))]"
        let folder = file.deletingLastPathComponent()
        let ext = AudioFiles.fileExtension(forCodec: audio.codecName)
        start("Sending the audio (\(audio.audioLabel)) of \(file.lastPathComponent) "
              + "\(TimeCode.format(r.start))–\(TimeCode.format(r.end)) to Merge") { tools in
            let dir = AppPaths.cache.appendingPathComponent("to-merge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent("\(name).\(ext)")
            try await tools.extractAudio(MediaPiece(url: file, probe: info, start: r.start, end: r.end),
                                         streamIndex: audio.index, to: out)
            await MainActor.run {
                self.log(.success, "✓ Sent to the Merge tab (the video will be saved next to \(file.lastPathComponent)).")
                handoff(out, folder, name)
            }
            return []
        }
    }
}

/// One entry in the Joiner: a whole file or a range of it.
struct JoinPiece: Identifiable {
    let id = UUID()
    let url: URL
    var modified: Date?
    var info: ProbeResult?
    var whole = true
    var fields = RangeFields()
    var preview = RangePreview()
    var loadFailed = false

    var sortItem: JoinSortItem {
        let length: Double? = { if case .success(let r) = range { return r.upperBound - r.lowerBound }; return nil }()
        return JoinSortItem(name: url.lastPathComponent, modified: modified, duration: length)
    }

    var range: Result<ClosedRange<Double>, String> {
        guard let info else { return .failure(loadFailed ? "Could not read this file." : "Reading…") }
        if whole { return .success(0...info.duration) }
        return fields.resolve(fileDuration: info.duration).mapError { $0.description }
    }
}

extension String: Error {}

@MainActor
final class JoinerModel: ToolModel {
    @Published var pieces: [JoinPiece] = []
    /// Format to convert to when pieces differ: nil = automatic, else a piece id.
    @Published var matchPiece: UUID?
    @Published var sortKey: JoinSortKey = .name
    @Published var sortAscending = true
    private var previewTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        super.init(status: "Add two or more videos, or cuts of them, then click Join.", channel: .joiner)
    }

    /// Files dropped together are added in natural name order ("part 2" before "part 10").
    func add(_ urls: [URL]) {
        var batch = urls.filter { JobQueue.videoExtensions.contains($0.pathExtension.lowercased()) }.map { url in
            JoinPiece(url: url, modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        batch = JoinSorter.order(batch.map(\.sortItem), by: .name, ascending: true).map { batch[$0] }
        for piece in batch {
            pieces.append(piece)
            load(piece.id)
        }
    }

    /// Re-orders the list once; pieces can still be moved by hand afterwards.
    func sort(by key: JoinSortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        pieces = JoinSorter.order(pieces.map(\.sortItem), by: key, ascending: ascending).map { pieces[$0] }
    }

    private func load(_ id: UUID) {
        guard let url = pieces.first(where: { $0.id == id })?.url else { return }
        Task {
            let info = await probe(url)
            guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
            pieces[i].info = info
            pieces[i].loadFailed = info == nil
        }
    }

    /// Adds another cut from the same file right after `id`.
    func addCut(after id: UUID) {
        guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        var piece = JoinPiece(url: pieces[i].url, modified: pieces[i].modified)
        piece.info = pieces[i].info
        piece.whole = false
        pieces.insert(piece, at: i + 1)
        schedulePreview(piece.id)
    }

    func remove(_ id: UUID) {
        pieces.removeAll { $0.id == id }
        if matchPiece == id { matchPiece = nil }
    }

    /// Pieces whose files have been read, for format comparison.
    private var readyMedia: [MediaPiece] {
        pieces.compactMap { piece in
            guard let info = piece.info, case .success(let r) = piece.range else { return nil }
            return MediaPiece(url: piece.url, probe: info, start: r.lowerBound, end: r.upperBound)
        }
    }

    /// True when the pieces differ in format, so they will be converted.
    var formatsDiffer: Bool {
        let infos = pieces.compactMap(\.info)
        guard let first = infos.first else { return false }
        return infos.contains { $0.joinSignature != first.joinSignature }
    }

    /// The piece automatic matching would choose.
    var autoMatchPiece: JoinPiece? {
        let ready = pieces.filter { piece in
            guard piece.info != nil, case .success = piece.range else { return false }
            return true
        }
        guard !ready.isEmpty else { return nil }
        return ready[MediaTools.autoTarget(readyMedia)]
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard pieces.indices.contains(j) else { return }
        pieces.swapAt(i, j)
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        pieces.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func update(_ id: UUID, whole: Bool? = nil, fields: RangeFields? = nil) {
        guard let i = pieces.firstIndex(where: { $0.id == id }) else { return }
        if let whole { pieces[i].whole = whole }
        if let fields { pieces[i].fields = fields }
        schedulePreview(id)
    }

    private func schedulePreview(_ id: UUID) {
        previewTasks[id]?.cancel()
        guard let piece = pieces.first(where: { $0.id == id }), !piece.whole,
              let info = piece.info, case .success(let r) = piece.range else {
            if let i = pieces.firstIndex(where: { $0.id == id }) { pieces[i].preview = RangePreview() }
            return
        }
        previewTasks[id] = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            let p = await previews(piece.url, probe: info, range: r)
            if !Task.isCancelled, let i = pieces.firstIndex(where: { $0.id == id }) { pieces[i].preview = p }
        }
    }

    var problem: String? {
        if pieces.isEmpty { return "Add at least one video." }
        for (n, piece) in pieces.enumerated() {
            if case .failure(let message) = piece.range { return "Piece \(n + 1): \(message)" }
        }
        if pieces.count == 1 && pieces[0].whole { return "Add another video or a cut to join." }
        return nil
    }

    var totalDuration: Double {
        pieces.reduce(0) { total, piece in
            if case .success(let r) = piece.range { return total + r.upperBound - r.lowerBound }
            return total
        }
    }

    func run() {
        guard problem == nil else { return }
        let media: [MediaPiece] = pieces.compactMap { piece in
            guard let info = piece.info, case .success(let r) = piece.range else { return nil }
            return MediaPiece(url: piece.url, probe: info, start: r.lowerBound, end: r.upperBound)
        }
        let first = media[0].url
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let out = Self.uniqueURL(in: first.deletingLastPathComponent(),
                                 base: "Joined \(formatter.string(from: Date()))",
                                 ext: first.pathExtension.isEmpty ? "mkv" : first.pathExtension)
        let target = matchPiece.flatMap { id in pieces.firstIndex { $0.id == id } }
        start("Joining \(media.count) pieces (\(TimeCode.format(totalDuration)))") { tools in
            try await tools.render(media, to: out, target: target)
            return [out]
        }
    }
}
