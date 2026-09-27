import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest" {
            SelfTest.run(input: URL(fileURLWithPath: CommandLine.arguments[2]))
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
}
