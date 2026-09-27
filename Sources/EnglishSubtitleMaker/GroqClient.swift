import Foundation
import SubtitleCore

/// A non-retryable HTTP error the caller maps to an error code.
struct GroqHTTPError: Error {
    let status: Int
    let message: String

    var isModelUnavailable: Bool {
        let m = message.lowercased()
        return status == 404 || (m.contains("model") && (m.contains("not found") || m.contains("does not exist")
            || m.contains("decommissioned") || m.contains("not available") || m.contains("no access")))
    }
}

/// Talks to Groq's OpenAI-compatible API, with retries for rate limits,
/// server hiccups and flaky connections.
struct GroqClient {
    let apiKey: String
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

    // MARK: Audio

    /// One step: Whisper hears the part and writes English. Returns verbose_json.
    func translateAudio(file: URL, mimeType: String, model: String, prompt: String?) async throws -> Data {
        try await audioRequest(Groq.translationsURL, file: file, mimeType: mimeType, model: model,
                               prompt: prompt, language: nil)
    }

    /// Whisper writes down the words in the given language. Returns verbose_json.
    func transcribeAudio(file: URL, mimeType: String, model: String, prompt: String?, language: String) async throws -> Data {
        try await audioRequest(Groq.transcriptionsURL, file: file, mimeType: mimeType, model: model,
                               prompt: prompt, language: language)
    }

    private func audioRequest(_ url: URL, file: URL, mimeType: String, model: String,
                              prompt: String?, language: String?) async throws -> Data {
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
        if let language { form.addField("language", language) }
        form.addFile("file", filename: file.lastPathComponent, mimeType: mimeType, data: audio)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        do {
            return try await send(req, body: form.finalized())
        } catch let error as GroqHTTPError {
            if error.status == 413 { throw SubtitleError(.fileTooLarge, error.message) }
            throw SubtitleError(.badRequest, error.message)
        }
    }

    // MARK: Text

    /// Sends a chat completion and returns the reply text.
    /// Optional parameters Groq rejects for a model (e.g. reasoning settings)
    /// are dropped and the request is repeated.
    func chat(model: String, system: String, user: String) async throws -> String {
        var optional: [String: Any] = [
            "response_format": ["type": "json_object"],
            "reasoning_effort": model.contains("gpt-oss") ? "low" : "none",
            "include_reasoning": false,
        ]
        while true {
            var payload: [String: Any] = [
                "model": model,
                "temperature": 0.2,
                "max_completion_tokens": 4096,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
            payload.merge(optional) { a, _ in a }
            var req = URLRequest(url: Groq.chatURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = try JSONSerialization.data(withJSONObject: payload)
            do {
                let data = try await send(req, body: body)
                guard let reply = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
                      let content = reply.choices.first?.message.content else {
                    throw SubtitleError(.badResponse, String(decoding: data.prefix(300), as: UTF8.self))
                }
                return content
            } catch let error as GroqHTTPError where error.status == 400 {
                let message = error.message.lowercased()
                guard let rejected = optional.keys.first(where: { message.contains($0) }) else { throw error }
                log(.detail, "\(model) does not support \"\(rejected)\"; retrying without it.")
                optional.removeValue(forKey: rejected)
            }
        }
    }

    // MARK: Transport

    /// Sends a request, retrying rate limits, server errors and network drops.
    /// Throws `GroqHTTPError` for other 4xx replies.
    private func send(_ request: URLRequest, body: Data) async throws -> Data {
        var req = request
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
            case 401:
                throw SubtitleError(.apiKeyInvalid, message)
            case 403:
                throw SubtitleError(.apiForbidden, message)
            case 429:
                let wait = RetryAfter.seconds(header: http.value(forHTTPHeaderField: "retry-after"), message: message) ?? 60
                rateLimitWaits += 1
                if wait > Self.maxRateLimitWait || rateLimitWaits > 12 {
                    throw SubtitleError(.rateLimitExhausted, "Groq says: \(message.isEmpty ? "try again in \(Self.describe(wait))" : message)")
                }
                if wait >= 5 {
                    log(.warning, "Groq free-tier limit hit. Waiting \(Self.describe(wait)) then continuing automatically…")
                }
                try await Self.sleep(wait + 1, countdown: log)
            case 400..<500:
                throw GroqHTTPError(status: http.statusCode, message: message)
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
