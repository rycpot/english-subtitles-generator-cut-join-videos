import AppKit
import SubtitleCore
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest" {
            SelfTest.run(input: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest-tools" {
            SelfTest.runTools(folder: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        EnglishSubtitleMakerApp.main()
    }
}

struct EnglishSubtitleMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var queue = JobQueue.shared

    var body: some Scene {
        WindowGroup("English Subtitles Generator, Cut & Join Videos") {
            ContentView().environmentObject(queue)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        Settings {
            SettingsView().environmentObject(queue)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon or opened with "Open With".
    func application(_ sender: NSApplication, open urls: [URL]) {
        JobQueue.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard JobQueue.shared.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A subtitle job is still running."
        alert.informativeText = "If you quit, finished parts are remembered and the job resumes when you drop the same file again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Working")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// `EnglishSubtitleMaker --selftest <file>`: runs everything up to the upload
/// (probe, extract, find pauses, split) and prints the log. Used by CI.
enum SelfTest {
    static func run(input: URL) -> Never {
        guard let ffmpeg = AppPaths.findFFmpeg() else {
            print("FAIL: ffmpeg not found")
            exit(2)
        }
        print("ffmpeg: \(ffmpeg.path)")
        let pipeline = Pipeline(input: input, ffmpeg: ffmpeg, settings: .current(), apiKey: nil,
                                log: { _, text in print(text) }, progress: { _, _ in })
        Task.detached {
            do {
                let dir = try await pipeline.run(prepareOnly: true)
                let plan = try String(contentsOf: dir.appendingPathComponent("plan.json"), encoding: .utf8)
                print("PLAN: \(plan)")
                try? FileManager.default.removeItem(at: dir)
                print("OK")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        // The task above ends the process; keep the main thread parked until then.
        while true { sleep(60) }
    }

    /// `EnglishSubtitleMaker --selftest-tools <folder>`: cuts, splits and joins
    /// test films in <folder> (src.mkv, src2.mkv, other720.mp4, opengop.mp4, hevc10.mkv) and
    /// checks every output has exactly the expected frames and decodes without errors.
    static func runTools(folder: URL) -> Never {
        Task.detached {
            do {
                let fallbacks = FallbackCounter()
                let tools = try MediaTools.make(log: { _, text in
                    print("  " + text)
                    if text.contains("don't join cleanly") { fallbacks.add() }
                }, progress: { _, _ in })
                let src = folder.appendingPathComponent("src.mkv")
                let src2 = folder.appendingPathComponent("src2.mkv")
                let other = folder.appendingPathComponent("other720.mp4")
                let out = folder.appendingPathComponent("out", isDirectory: true)
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let p1 = try await tools.probe(src), p2 = try await tools.probe(src2), p3 = try await tools.probe(other)
                let pts1 = try await tools.framePTS(src), pts2 = try await tools.framePTS(src2)
                var failures = 0

                /// Frames of `pts` (file time base) that fall in start..<end (user time).
                func expected(_ pts: [Double], _ probe: ProbeResult, _ start: Double, _ end: Double) -> Int {
                    pts.filter { $0 >= start + probe.startTime && $0 < end + probe.startTime }.count
                }
                func check(_ name: String, _ file: URL, frames: Int, tolerance: Int = 0) async throws {
                    let got = try await tools.framePTS(file).count
                    let errors = try await tools.decodeErrors(file)
                    let ok = abs(got - frames) <= tolerance && errors.isEmpty
                    print("\(ok ? "PASS" : "FAIL") \(name): \(got) frames, expected \(frames)"
                          + (errors.isEmpty ? "" : ", decode errors: \(errors.prefix(3))"))
                    if !ok { failures += 1 }
                }

                // 1. A cut between keyframes: copied middle, re-encoded edges.
                let cut = out.appendingPathComponent("cut.mkv")
                try await tools.render([MediaPiece(url: src, probe: p1, start: 20.5, end: 32.7)], to: cut)
                try await check("cut 20.5-32.7", cut, frames: expected(pts1, p1, 20.5, 32.7))

                // 2. Split 20-32 into 3 parts: together exactly the frames of 20-32.
                var splitFrames = 0
                for (i, r) in RangeSplitter.split(start: 20, end: 32, mode: .count(3)).enumerated() {
                    let part = out.appendingPathComponent("part\(i + 1).mkv")
                    try await tools.render([MediaPiece(url: src, probe: p1, start: r.start, end: r.end)], to: part)
                    let n = try await tools.framePTS(part).count
                    splitFrames += n
                    try await check("split part \(i + 1)", part, frames: expected(pts1, p1, r.start, r.end))
                }
                print(splitFrames == expected(pts1, p1, 20, 32) ? "PASS split total" : "FAIL split total \(splitFrames)")
                if splitFrames != expected(pts1, p1, 20, 32) { failures += 1 }

                // 3. Join cuts of two matching files, including one from the very start.
                let joined = out.appendingPathComponent("joined.mkv")
                try await tools.render([MediaPiece(url: src, probe: p1, start: 20.5, end: 32.7),
                                        MediaPiece(url: src2, probe: p2, start: 10.3, end: 15.1),
                                        MediaPiece(url: src, probe: p1, start: 0, end: 5.3)], to: joined)
                try await check("join of 3 cuts", joined, frames: expected(pts1, p1, 20.5, 32.7)
                                + expected(pts2, p2, 10.3, 15.1) + expected(pts1, p1, 0, 5.3))

                // 4. Whole files: pure copy.
                let whole = out.appendingPathComponent("whole.mkv")
                try await tools.render([MediaPiece(url: src2, probe: p2, start: 0, end: p2.duration),
                                        MediaPiece(url: src2, probe: p2, start: 0, end: p2.duration)], to: whole)
                try await check("join of 2 whole files", whole, frames: 2 * pts2.count)

                // 5. Different formats: converted to the format with the most running time
                //    (5 s of src at 25 fps beats 3 s of other720 at 30 fps).
                let mixed = out.appendingPathComponent("mixed.mkv")
                try await tools.render([MediaPiece(url: src, probe: p1, start: 20.5, end: 25.5),
                                        MediaPiece(url: other, probe: p3, start: 2, end: 5)], to: mixed)
                let mixedProbe = try await tools.probe(mixed)
                let sizeOK = mixedProbe.video?.width == p1.video?.width
                print(sizeOK ? "PASS converted to the dominant format" : "FAIL converted size \(mixedProbe.formatSummary)")
                if !sizeOK { failures += 1 }
                try await check("converted join", mixed, frames: 8 * 25, tolerance: 1)

                // 6. Open GOP (as in many films and trailers), cut in the middle.
                let og = folder.appendingPathComponent("opengop.mp4")
                let p4 = try await tools.probe(og)
                let pts4 = try await tools.framePTS(og)
                let ogCut = out.appendingPathComponent("opengop-cut.mp4")
                try await tools.render([MediaPiece(url: og, probe: p4, start: 5.3, end: 15.6)], to: ogCut)
                try await check("open-GOP cut 5.3-15.6", ogCut, frames: expected(pts4, p4, 5.3, 15.6))

                // 7. Split the open-GOP film into 2 parts: each keeps the source's exact
                //    format (so the Joiner sees them as matching), and joining them back
                //    gives exactly the frames of the range.
                var ogParts: [MediaPiece] = []
                for (i, r) in RangeSplitter.split(start: 0.3, end: 20.3, mode: .count(2)).enumerated() {
                    let part = out.appendingPathComponent("opengop-part\(i + 1).mp4")
                    try await tools.render([MediaPiece(url: og, probe: p4, start: r.start, end: r.end)], to: part)
                    let pp = try await tools.probe(part)
                    let diff = pp.joinSignature.differences(from: p4.joinSignature)
                    print(diff.isEmpty ? "PASS open-GOP part \(i + 1) keeps the format (\(pp.formatSummary))"
                                       : "FAIL open-GOP part \(i + 1) format: \(diff)")
                    if !diff.isEmpty { failures += 1 }
                    ogParts.append(MediaPiece(url: part, probe: pp, start: 0, end: pp.duration))
                }
                let ogJoined = out.appendingPathComponent("opengop-joined.mp4")
                try await tools.render(ogParts, to: ogJoined)
                try await check("open-GOP parts joined back", ogJoined, frames: expected(pts4, p4, 0.3, 20.3))

                // 8. 10-bit HEVC with open GOP (typical x265 film releases): quick cut too,
                //    keeping the format.
                let hv = folder.appendingPathComponent("hevc10.mkv")
                let p5 = try await tools.probe(hv)
                let pts5 = try await tools.framePTS(hv)
                print(p5.canSmartCut ? "PASS 10-bit HEVC uses the quick cut" : "FAIL 10-bit HEVC not quick-cut: \(p5.formatSummary)")
                if !p5.canSmartCut { failures += 1 }
                let hvCut = out.appendingPathComponent("hevc10-cut.mkv")
                try await tools.render([MediaPiece(url: hv, probe: p5, start: 5.3, end: 15.6)], to: hvCut)
                try await check("HEVC 10-bit cut 5.3-15.6", hvCut, frames: expected(pts5, p5, 5.3, 15.6))
                let hvDiff = try await tools.probe(hvCut).joinSignature.differences(from: p5.joinSignature)
                print(hvDiff.isEmpty ? "PASS HEVC cut keeps the format" : "FAIL HEVC cut format: \(hvDiff)")
                if !hvDiff.isEmpty { failures += 1 }

                // 9. Audio only: one track copied unchanged, the length of the range.
                for (name, source, probe, trackIndex, ext) in [("AAC from .mkv", src, p1, 1, "m4a"),
                                                                ("AC3 5.1 from .mkv", hv, p5, 1, "ac3")] {
                    let a = out.appendingPathComponent("audio-\(ext).\(ext)")
                    try await tools.extractAudio(MediaPiece(url: source, probe: probe, start: 20.5, end: 27.7),
                                                 streamIndex: trackIndex, to: a)
                    let length = try await tools.audioLength(a)
                    let ok = abs(length - 7.2) < 0.06
                    print("\(ok ? "PASS" : "FAIL") audio only, \(name): \(String(format: "%.3f", length)) s, expected 7.200")
                    if !ok { failures += 1 }
                }

                // 10. Merge: two pictures (one cropped and filling the canvas) over 12 s of
                //     audio with fades and loudness evening → YouTube-ready 1080p H.264.
                let photo = folder.appendingPathComponent("photo.png")
                guard let img = MergeSlide.load(photo) else { throw SubtitleError(.unexpected, "photo.png unreadable") }
                let aspect = CGFloat(img.width) / CGFloat(img.height)
                let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                let slides = [MergeSlide(url: photo, image: img, frame: CanvasSnap.fit(aspect: aspect)),
                              MergeSlide(url: photo, image: img, crop: crop, frame: CanvasSnap.fill(aspect: aspect))]
                var slideFiles: [String] = []
                for (k, slide) in slides.enumerated() {
                    guard let frame = MergeRenderer.frame(slide, background: CGColor(red: 0, green: 0, blue: 0.4, alpha: 1)) else {
                        throw SubtitleError(.unexpected, "could not draw slide \(k + 1)")
                    }
                    let file = out.appendingPathComponent("slide\(k).png")
                    try MergeRenderer.writePNG(frame, to: file)
                    slideFiles.append(file.path)
                }
                let merged = out.appendingPathComponent("merged.mp4")
                try await tools.merge(MergeSpec(slides: [.init(file: slideFiles[0], length: 5), .init(file: slideFiles[1], length: 7)],
                                                audio: src.path, audioStart: 10, audioLength: 12, fadeIn: 1, fadeOut: 1,
                                                normalize: true, copyAudio: false, output: merged.path))
                let mp = try await tools.probe(merged)
                let mv = mp.video, ma = mp.audio.first
                let formatOK = mv?.codecName == "h264" && mv?.width == 1920 && mv?.height == 1080 && mv?.pixFmt == "yuv420p"
                    && abs((mp.frameRate ?? 0) - 30) < 0.01 && ma?.codecName == "aac" && ma?.sampleRate == "48000"
                    && abs(mp.duration - 12) < 0.1
                print(formatOK ? "PASS merge makes 1080p30 H.264 + 48 kHz AAC, 12 s"
                               : "FAIL merge format: \(mp.formatSummary), \(ma?.codecName ?? "no audio") \(ma?.sampleRate ?? ""), \(mp.duration) s")
                if !formatOK { failures += 1 }
                try await check("merge frames", merged, frames: 360, tolerance: 1)

                // The quick cut must not have fallen back to full re-encoding anywhere.
                let fell = fallbacks.count
                print(fell == 0 ? "PASS quick cut used throughout" : "FAIL quick cut fell back \(fell) time(s)")
                if fell > 0 { failures += 1 }

                print(failures == 0 ? "TOOLS OK" : "TOOLS FAILED: \(failures)")
                exit(failures == 0 ? 0 : 1)
            } catch {
                print("TOOLS FAILED: \(error)")
                exit(1)
            }
        }
        while true { sleep(60) }
    }
}

/// Counts smart-cut fallbacks reported through the log during the tools self-test.
final class FallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
