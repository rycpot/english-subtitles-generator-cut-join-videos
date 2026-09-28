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
    static func findFFmpeg() -> URL? { findTool("ffmpeg") }

    /// A bundled command-line tool (ffmpeg, ffprobe), else a common install location.
    static func findTool(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) {
            candidates.append(bundled)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent(name))
        for dir in ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", "/usr/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
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
    static let contextMode = "contextMode"
}

/// What each part (after the first) is told about the part before it.
enum ContextMode: String, CaseIterable, Identifiable {
    /// The last English lines of the previous part go along as a prompt, and a
    /// part that comes back with very few words is asked again without it.
    case previousWithRetry
    /// Every part is translated on its own.
    case none
    /// The last English lines go along as a prompt (up to v1.5.5).
    case previous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previousWithRetry: return "Previous lines, re-ask thin parts without them"
        case .none: return "No context: every part on its own"
        case .previous: return "Previous lines only (as before v1.5.6)"
        }
    }
}

struct PipelineSettings {
    var model: String
    /// On 5.1/7.1 tracks, use only the centre channel, where dialogue is
    /// mixed, to keep music and effects from confusing the recogniser.
    var dialogueFocus: Bool
    var contextMode: ContextMode

    static func current() -> PipelineSettings {
        let d = UserDefaults.standard
        return PipelineSettings(
            // Only whisper-large-v3 can translate; an older setting that
            // chose the turbo model is ignored.
            model: Groq.defaultModel,
            dialogueFocus: d.object(forKey: PrefKeys.dialogueFocus) as? Bool ?? true,
            contextMode: ContextMode(rawValue: d.string(forKey: PrefKeys.contextMode) ?? "") ?? .previousWithRetry)
    }
}
