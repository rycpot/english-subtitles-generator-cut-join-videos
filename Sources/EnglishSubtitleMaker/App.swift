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
        WindowGroup("English Subtitle Maker") {
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
    /// test films in <folder> (src.mkv, src2.mkv, other720.mp4) and checks every
    /// output has exactly the expected frames and decodes without errors.
    static func runTools(folder: URL) -> Never {
        Task.detached {
            do {
                let tools = try MediaTools.make(log: { _, text in print("  " + text) }, progress: { _, _ in })
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
