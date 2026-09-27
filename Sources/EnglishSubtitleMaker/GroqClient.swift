import Foundation
import SubtitleCore

/// Talks to Groq's OpenAI-compatible audio API, with retries for
/// rate limits, server hiccups and flaky connections.
struct GroqClient {
    let apiKey: String
    let model: String
    let log: (LogLevel, String) -> Void

    /// Waits longer than this are treated as "free limit used up for now".
    static let maxRateLimitWait: Double = 20 * 60
    static let maxTransientRetries = 4

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    /// Checks the key with a cheap request. Returns nil if fine, else the error.
    func verifyKey() async -> SubtitleError? {
        var req = URLRequest(url: Groq.modelsURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await Self.session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return nil
            case 401: return SubtitleError(.apiKeyInvalid, GroqErrorEnvelope.message(from: data) ?? "")
            case 403: return SubtitleError(.apiForbidden, GroqErrorEnvelope.message(from: data) ?? "")
            default: return SubtitleError(.serverError, "HTTP \(status)")
            }
        } catch {
            return SubtitleError(.networkError, error.localizedDescription)
        }
    }

    /// Uploads one audio part to /audio/translations and returns the raw verbose_json body.
    func translate(file: URL, mimeType: String, prompt: String?) async throws -> Data {
        let audio: Data
        do {
            audio = try Data(contentsOf: file)
        } catch {
            throw SubtitleError(.audioSplitFailed, "cannot read \(file.lastPathComponent): \(error.localizedDescription)")
        }
        if audio.count > 25 * 1024 * 1024 {
            throw SubtitleError(.fileTooLarge, "\(file.lastPathComponent) is \(audio.count / 1_048_576) MB")
        }

        var form = MultipartForm()
        form.addField("model", model)
        form.addField("response_format", "verbose_json")
        form.addField("temperature", "0")
        if let prompt, !prompt.isEmpty { form.addField("prompt", prompt) }
        form.addFile("file", filename: file.lastPathComponent, mimeType: mimeType, data: audio)
        let body = form.finalized()

        var req = URLRequest(url: Groq.translationsURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        var transientFailures = 0
        var rateLimitWaits = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let http: HTTPURLResponse
            do {
                let (d, r) = try await Self.session.upload(for: req, from: body)
                guard let h = r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                data = d
                http = h
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                transientFailures += 1
                if transientFailures > Self.maxTransientRetries {
                    throw SubtitleError(.networkError, error.localizedDescription)
                }
                let wait = 5.0 * pow(2.0, Double(transientFailures - 1))
                log(.warning, "Network problem (\(error.localizedDescription)). Retrying in \(Int(wait)) s (\(transientFailures)/\(Self.maxTransientRetries))…")
                try await Self.sleep(wait)
                continue
            }

            let message = GroqErrorEnvelope.message(from: data) ?? ""
            switch http.statusCode {
            case 200:
                return data
            case 400, 422:
                throw SubtitleError(.badRequest, message)
            case 401:
                throw SubtitleError(.apiKeyInvalid, message)
            case 403:
                throw SubtitleError(.apiForbidden, message)
            case 413:
                throw SubtitleError(.fileTooLarge, message)
            case 429:
                let wait = RetryAfter.seconds(header: http.value(forHTTPHeaderField: "retry-after"), message: message) ?? 60
                rateLimitWaits += 1
                if wait > Self.maxRateLimitWait || rateLimitWaits > 12 {
                    throw SubtitleError(.rateLimitExhausted, "Groq says: \(message.isEmpty ? "try again in \(Self.describe(wait))" : message)")
                }
                log(.warning, "Groq free-tier limit hit. Waiting \(Self.describe(wait)) then continuing automatically…")
                try await Self.sleep(wait + 1, countdown: log)
            default:
                transientFailures += 1
                if transientFailures > Self.maxTransientRetries {
                    throw SubtitleError(.serverError, "HTTP \(http.statusCode) \(message)")
                }
                let wait = 5.0 * pow(2.0, Double(transientFailures - 1))
                log(.warning, "Groq returned HTTP \(http.statusCode). Retrying in \(Int(wait)) s (\(transientFailures)/\(Self.maxTransientRetries))…")
                try await Self.sleep(wait)
            }
        }
    }

    static func describe(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// Sleeps (cancellably), optionally logging a countdown every minute.
    static func sleep(_ seconds: Double, countdown: ((LogLevel, String) -> Void)? = nil) async throws {
        var remaining = seconds
        while remaining > 0 {
            let step = min(remaining, 60)
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            remaining -= step
            if remaining > 0, let countdown {
                countdown(.info, "…\(describe(remaining)) left")
            }
        }
    }
}
