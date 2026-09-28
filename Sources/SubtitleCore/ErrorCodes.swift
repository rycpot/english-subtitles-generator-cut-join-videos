import Foundation

/// Every failure the app can report. The code is shown in the log and in the
/// job list so a problem can be looked up in the README table.
public enum ErrorCode: String, CaseIterable {
    // 1xx: the video file / ffmpeg
    case ffmpegMissing = "E101"
    case inputUnreadable = "E102"
    case noAudioTrack = "E103"
    case audioExtractFailed = "E104"
    case audioSplitFailed = "E105"
    // 2xx: Groq
    case apiKeyMissing = "E201"
    case apiKeyInvalid = "E202"
    case apiForbidden = "E203"
    case fileTooLarge = "E204"
    case badRequest = "E205"
    case rateLimitExhausted = "E206"
    case serverError = "E207"
    case networkError = "E208"
    case badResponse = "E209"
    // 3xx: writing the subtitle
    case writeFailed = "E301"
    case noSpeech = "E302"
    // 4xx: Cutter and Joiner
    case ffprobeMissing = "E401"
    case mediaUnreadable = "E402"
    case cutFailed = "E403"
    case joinFailed = "E404"
    // 9xx: other
    case cancelled = "E900"
    case unexpected = "E999"

    public var title: String {
        switch self {
        case .ffmpegMissing: return "ffmpeg not found"
        case .inputUnreadable: return "Cannot read the video file"
        case .noAudioTrack: return "The file has no audio track"
        case .audioExtractFailed: return "Could not extract the audio"
        case .audioSplitFailed: return "Could not split the audio into parts"
        case .apiKeyMissing: return "No Groq API key"
        case .apiKeyInvalid: return "Groq rejected the API key"
        case .apiForbidden: return "Groq refused access"
        case .fileTooLarge: return "Audio part too large for Groq"
        case .badRequest: return "Groq rejected the request"
        case .rateLimitExhausted: return "Groq free limit reached"
        case .serverError: return "Groq server error"
        case .networkError: return "Network problem"
        case .badResponse: return "Unexpected reply from Groq"
        case .writeFailed: return "Could not save the .srt file"
        case .noSpeech: return "No speech was found"
        case .ffprobeMissing: return "ffprobe not found"
        case .mediaUnreadable: return "Cannot read the video"
        case .cutFailed: return "Cutting failed"
        case .joinFailed: return "Joining failed"
        case .cancelled: return "Cancelled"
        case .unexpected: return "Unexpected error"
        }
    }

    public var hint: String {
        switch self {
        case .ffmpegMissing:
            return "The bundled ffmpeg is missing. Re-download the app, or install ffmpeg to /usr/local/bin."
        case .inputUnreadable:
            return "Check the file still exists and plays in VLC. If macOS asked for folder access, allow it in System Preferences → Security & Privacy → Files and Folders."
        case .noAudioTrack:
            return "The file contains no audio stream ffmpeg can read."
        case .audioExtractFailed, .audioSplitFailed:
            return "The file may be damaged or use an unusual audio codec. See the ffmpeg lines above in the log."
        case .apiKeyMissing:
            return "Paste your free key from console.groq.com/keys into the box at the top."
        case .apiKeyInvalid:
            return "The key is wrong or was revoked. Create a new one at console.groq.com/keys."
        case .apiForbidden:
            return "Your Groq account cannot use this model, or access is blocked from your network."
        case .fileTooLarge:
            return "Should not happen (parts are under 0.3 MB). Please report it with the log."
        case .badRequest:
            return "See Groq's message in the log above."
        case .rateLimitExhausted:
            return "The free tier allows about 8 hours of audio per day. Drop the same file again later: finished parts are remembered and skipped."
        case .serverError:
            return "Groq is having trouble. Try again later; finished parts are remembered."
        case .networkError:
            return "Check your internet connection. Finished parts are remembered, so just drop the file again."
        case .badResponse:
            return "Groq replied with something unexpected. Try again; report it with the log if it repeats."
        case .writeFailed:
            return "The folder may be read-only, or macOS blocked access (System Preferences → Security & Privacy → Files and Folders)."
        case .noSpeech:
            return "Groq returned no dialogue. Check that the right audio track was used (see the log)."
        case .ffprobeMissing:
            return "The bundled ffprobe is missing. Re-download the app."
        case .mediaUnreadable:
            return "The file may be damaged, or it has no video track. Check that it plays in VLC."
        case .cutFailed, .joinFailed:
            return "See the ffmpeg lines above in the log. Check there is enough free disk space (about twice the size of the result)."
        case .cancelled:
            return "Stopped by you. Finished parts are remembered."
        case .unexpected:
            return "Please report this with the log."
        }
    }
}

public struct SubtitleError: Error, CustomStringConvertible {
    public let code: ErrorCode
    public let detail: String

    public init(_ code: ErrorCode, _ detail: String = "") {
        self.code = code
        self.detail = detail
    }

    public var description: String {
        detail.isEmpty ? "\(code.rawValue) \(code.title)" : "\(code.rawValue) \(code.title): \(detail)"
    }
}
