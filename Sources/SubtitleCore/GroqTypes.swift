import Foundation

public enum Groq {
    public static let translationsURL = URL(string: "https://api.groq.com/openai/v1/audio/translations")!
    public static let transcriptionsURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    public static let chatURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    public static let modelsURL = URL(string: "https://api.groq.com/openai/v1/models")!
    /// whisper-large-v3 is the Groq model trained for translation to English
    /// (the faster "turbo" model translates poorly).
    public static let defaultModel = "whisper-large-v3"

    /// Free-tier text models for the two-step route, best first. If the chosen
    /// one has been withdrawn, the app moves on to the next.
    public static let textModels = ["openai/gpt-oss-120b", "qwen/qwen3.6-27b", "openai/gpt-oss-20b"]
    public static let defaultTextModel = "openai/gpt-oss-120b"
}

/// Reply from /chat/completions (only the parts the app uses).
public struct ChatCompletionResponse: Decodable {
    public struct Choice: Decodable {
        public struct Message: Decodable {
            public var content: String?
        }
        public var message: Message
    }
    public var choices: [Choice]
}

/// Builds the text-model request for a batch of transcribed lines and reads
/// the reply. Lines are numbered so the reply can be matched back to their
/// timestamps.
public enum SubtitleTranslation {
    /// Lines per request: large enough for context, small enough to stay well
    /// within the free tier's 8,000 tokens per minute.
    public static let batchSize = 40

    public static func systemPrompt(language: String) -> String {
        """
        You translate film subtitles from \(language) into English. The input is a numbered \
        list of consecutive lines of dialogue, transcribed automatically, so some words may be \
        misheard: use the surrounding lines to infer the meaning. Write natural, concise spoken \
        English suitable for subtitles. Keep names as they are. Translate every line separately: \
        return exactly one translation per input line, in the same order. Even when a line is \
        garbled, give your best guess at its meaning; return an empty string only for a line \
        that is clearly just a sound such as music or humming. Reply with JSON only, in the \
        form {"t": ["translation of line 1", "translation of line 2", ...]}, where each \
        element is a plain string containing only the English translation.
        """
    }

    public static func userPrompt(lines: [String], context: [String]) -> String {
        var out = ""
        if !context.isEmpty {
            out += "Earlier dialogue, already translated, for context only (do not include it):\n"
            out += context.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        out += "Translate these \(lines.count) lines:\n"
        out += lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return out
    }

    /// Returns the translations, or nil if the reply does not contain exactly
    /// `expected` of them.
    public static func parse(_ content: String, expected: Int) -> [String]? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any]
        else { return nil }
        let array = (object["t"] ?? object["translations"] ?? object.values.first { $0 is [Any] }) as? [Any]
        guard let items = array, items.count == expected else { return nil }
        return items.map { item in
            // Some models echo the numbering ("3. Hello"); remove it.
            text(of: item).replacingOccurrences(of: #"^\s*\d+[.):]\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A reply entry is normally a string, but some models send objects such as
    /// {"line": 1, "translation": "..."}: take the translation from those.
    static func text(of item: Any) -> String {
        if let s = item as? String { return s }
        guard let object = item as? [String: Any] else { return "" }
        for key in ["translation", "english", "en", "text", "t", "output"] {
            if let s = object[key] as? String { return s }
        }
        let original = ["original", "source", "input", "telugu", "line"]
        return object.filter { !original.contains($0.key.lowercased()) }
            .compactMap { $0.value as? String }
            .max { $0.count < $1.count } ?? ""
    }
}

/// `response_format=verbose_json` reply from /audio/translations.
public struct GroqVerboseResponse: Codable, Equatable {
    public var text: String?
    public var language: String?
    public var duration: Double?
    public var segments: [GroqSegment]?
}

public struct GroqSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var avgLogprob: Double?
    public var compressionRatio: Double?
    public var noSpeechProb: Double?

    public init(start: Double, end: Double, text: String,
                avgLogprob: Double? = nil, compressionRatio: Double? = nil, noSpeechProb: Double? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.avgLogprob = avgLogprob
        self.compressionRatio = compressionRatio
        self.noSpeechProb = noSpeechProb
    }

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case avgLogprob = "avg_logprob"
        case compressionRatio = "compression_ratio"
        case noSpeechProb = "no_speech_prob"
    }
}

public struct GroqErrorEnvelope: Decodable {
    public struct Body: Decodable {
        public var message: String?
        public var type: String?
    }
    public var error: Body?

    public static func message(from data: Data) -> String? {
        if let env = try? JSONDecoder().decode(GroqErrorEnvelope.self, from: data), let msg = env.error?.message {
            return msg
        }
        let text = String(decoding: data.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public enum RetryAfter {
    /// How long Groq asks us to wait after a 429, from the `retry-after`
    /// header or from text such as "Please try again in 7m32.5s".
    public static func seconds(header: String?, message: String?) -> Double? {
        if let h = header?.trimmingCharacters(in: .whitespaces), let v = Double(h), v >= 0 {
            return v
        }
        guard let message, let range = message.range(of: "try again in ") else { return nil }
        let chars = Array(message[range.upperBound...])
        var total = 0.0
        var number = ""
        var matchedAny = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            i += 1
            if ch.isNumber || ch == "." {
                number.append(ch)
                continue
            }
            guard let v = Double(number) else { break }
            switch ch {
            case "h": total += v * 3600
            case "m" where i < chars.count && chars[i] == "s":
                total += v / 1000
                i += 1
            case "m": total += v * 60
            case "s": total += v
            default: return matchedAny ? total : nil
            }
            matchedAny = true
            number = ""
        }
        return matchedAny ? total : nil
    }
}

/// Builds a multipart/form-data body for the upload.
public struct MultipartForm {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    public func finalized() -> Data {
        var out = body
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
