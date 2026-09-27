import Foundation

/// A spoken language Whisper knows, identified by the ISO-639-1 code Groq expects.
public struct FilmLanguage: Hashable, Identifiable {
    public let code: String
    public let name: String
    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    /// Stored in preferences when Whisper should detect the language itself.
    public static let autoCode = "auto"

    public static let southAsian: [FilmLanguage] = [
        .init(code: "te", name: "Telugu"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "ta", name: "Tamil"),
        .init(code: "ml", name: "Malayalam"),
        .init(code: "kn", name: "Kannada"),
        .init(code: "mr", name: "Marathi"),
        .init(code: "bn", name: "Bengali"),
        .init(code: "ur", name: "Urdu"),
        .init(code: "gu", name: "Gujarati"),
        .init(code: "pa", name: "Punjabi"),
        .init(code: "ne", name: "Nepali"),
        .init(code: "si", name: "Sinhala"),
        .init(code: "as", name: "Assamese"),
    ]

    public static let european: [FilmLanguage] = [
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "pl", name: "Polish"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "da", name: "Danish"),
        .init(code: "fi", name: "Finnish"),
        .init(code: "el", name: "Greek"),
        .init(code: "cs", name: "Czech"),
        .init(code: "sk", name: "Slovak"),
        .init(code: "hu", name: "Hungarian"),
        .init(code: "ro", name: "Romanian"),
        .init(code: "bg", name: "Bulgarian"),
        .init(code: "hr", name: "Croatian"),
        .init(code: "sl", name: "Slovenian"),
        .init(code: "et", name: "Estonian"),
        .init(code: "lv", name: "Latvian"),
        .init(code: "lt", name: "Lithuanian"),
    ]

    public static let other: [FilmLanguage] = [
        .init(code: "en", name: "English"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "fa", name: "Persian"),
        .init(code: "ru", name: "Russian"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "th", name: "Thai"),
        .init(code: "vi", name: "Vietnamese"),
        .init(code: "id", name: "Indonesian"),
    ]

    public static let all: [FilmLanguage] = southAsian + european + other

    /// nil for "auto" or an unknown code.
    public static func named(_ code: String) -> FilmLanguage? {
        all.first { $0.code == code }
    }
}
