import Foundation

public enum Groq {
    public static let translationsURL = URL(string: "https://api.groq.com/openai/v1/audio/translations")!
    public static let modelsURL = URL(string: "https://api.groq.com/openai/v1/models")!
    /// whisper-large-v3 is the Groq model trained for translation to English
    /// (the faster "turbo" model translates poorly).
    public static let defaultModel = "whisper-large-v3"
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
