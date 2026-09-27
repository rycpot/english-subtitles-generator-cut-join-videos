import Foundation
import SubtitleCore

/// Second step of the two-step route: translates Whisper's transcribed
/// lines to English with a Groq text model, in batches, keeping each line's
/// timing. Finished batches are saved in the work folder so an interrupted
/// job does not redo them.
final class LineTranslator {
    private let client: GroqClient
    private let language: FilmLanguage
    private let workDir: URL
    private let log: (LogLevel, String) -> Void

    /// Models to try, the preferred one first.
    private var models: [String]
    private(set) var translated: [GroqSegment] = []
    private var pending: [GroqSegment] = []
    private var batchIndex = 0

    var modelInUse: String { models.first ?? "?" }

    init(client: GroqClient, language: FilmLanguage, preferredModel: String, workDir: URL,
         log: @escaping (LogLevel, String) -> Void) {
        self.client = client
        self.language = language
        self.workDir = workDir
        self.log = log
        models = [preferredModel] + Groq.textModels.filter { $0 != preferredModel }
    }

    func add(_ segments: [GroqSegment]) {
        pending += segments.filter { !SubtitleBuilder.cleaned($0.text).isEmpty }
    }

    func translateFullBatches() async throws {
        while pending.count >= SubtitleTranslation.batchSize {
            try await translateBatch(Array(pending.prefix(SubtitleTranslation.batchSize)))
            pending.removeFirst(SubtitleTranslation.batchSize)
        }
    }

    func finish() async throws {
        try await translateFullBatches()
        if !pending.isEmpty {
            try await translateBatch(pending)
            pending.removeAll()
        }
    }

    // MARK: -

    private struct SavedBatch: Codable {
        let input: [String]
        let output: [String]
    }

    private func translateBatch(_ segments: [GroqSegment]) async throws {
        let lines = segments.map { SubtitleBuilder.cleaned($0.text) }
        let file = workDir.appendingPathComponent(String(format: "text_%04d.json", batchIndex))
        batchIndex += 1

        var output: [String]?
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(SavedBatch.self, from: data), saved.input == lines {
            output = saved.output
        }
        if output == nil {
            let context = translated.suffix(3).map { SubtitleBuilder.cleaned($0.text) }
            let result = try await translate(lines, context: context)
            if let data = try? JSONEncoder().encode(SavedBatch(input: lines, output: result)) {
                try? data.write(to: file, options: .atomic)
            }
            let empty = result.filter(\.isEmpty).count
            log(.detail, "Translated \(lines.count) lines" + (empty > 0 ? " (\(empty) left out as noise)" : "")
                + ": \(result.filter { !$0.isEmpty }.joined(separator: " / ").prefix(90))")
            output = result
        }
        for (segment, english) in zip(segments, output ?? []) where !english.isEmpty {
            var s = segment
            s.text = english
            translated.append(s)
        }
    }

    /// Translates lines; if the reply doesn't match line for line, retries
    /// once and then splits the batch in half.
    private func translate(_ lines: [String], context: [String]) async throws -> [String] {
        let system = SubtitleTranslation.systemPrompt(language: language.name)
        let user = SubtitleTranslation.userPrompt(lines: lines, context: context)
        var lastReply = ""
        for attempt in 1...2 {
            lastReply = try await chat(system: system, user: user)
            if let result = SubtitleTranslation.parse(lastReply, expected: lines.count) { return result }
            log(.detail, "The translation reply did not match the \(lines.count) lines"
                + (attempt == 1 ? "; asking again." : "."))
        }
        guard lines.count > 1 else {
            throw SubtitleError(.textTranslationFailed, "reply was: \(lastReply.prefix(200))")
        }
        let half = lines.count / 2
        let first = try await translate(Array(lines[..<half]), context: context)
        let second = try await translate(Array(lines[half...]), context: first.suffix(3).filter { !$0.isEmpty })
        return first + second
    }

    /// Sends to the first model that is still available.
    private func chat(system: String, user: String) async throws -> String {
        while let model = models.first {
            do {
                return try await client.chat(model: model, system: system, user: user)
            } catch let error as GroqHTTPError where error.isModelUnavailable {
                models.removeFirst()
                log(.warning, "Translation model \(model) is not available (\(error.message))."
                    + (models.first.map { " Switching to \($0)." } ?? ""))
            } catch let error as GroqHTTPError {
                throw SubtitleError(.badRequest, "\(model): \(error.message)")
            }
        }
        throw SubtitleError(.noTextModel)
    }
}
