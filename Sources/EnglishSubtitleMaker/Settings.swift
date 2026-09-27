import Foundation
import SubtitleCore

enum LogLevel {
    case info, warning, error, success, detail
}

enum AppPaths {
    static let appFolderName = "EnglishSubtitleMaker"

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    /// Work files for unfinished jobs (audio parts and Groq replies), kept so a
    /// job interrupted by the daily limit or a network drop can resume.
    static var cache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    static var logs: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(appFolderName, isDirectory: true)
    }

    /// Bundled ffmpeg first, then common install locations.
    static func findFFmpeg() -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            candidates.append(bundled)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("ffmpeg"))
        for path in ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/opt/local/bin/ffmpeg"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// The Groq key is kept in a file only you can read (permissions 600) in
/// ~/Library/Application Support/EnglishSubtitleMaker. The Keychain would
/// re-prompt after every update of an unsigned app.
enum APIKeyStore {
    static var fileURL: URL { AppPaths.support.appendingPathComponent("groq-api-key") }

    static func load() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try Data(key.utf8).write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum PrefKeys {
    static let dialogueFocus = "dialogueFocus"
}

struct PipelineSettings {
    var model: String
    /// On 5.1/7.1 tracks, use only the centre channel, where dialogue is
    /// mixed, to keep music and effects from confusing the recogniser.
    var dialogueFocus: Bool

    static func current() -> PipelineSettings {
        let d = UserDefaults.standard
        return PipelineSettings(
            // Only whisper-large-v3 can translate; an older setting that
            // chose the turbo model is ignored.
            model: Groq.defaultModel,
            dialogueFocus: d.object(forKey: PrefKeys.dialogueFocus) as? Bool ?? true)
    }
}
