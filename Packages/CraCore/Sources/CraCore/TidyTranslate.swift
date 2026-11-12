import Foundation

/// The fork's selection translation (W1): the user selects text on a page, Cra asks the local
/// model, and a toast shows the translation. Direction auto-detected from the text's script:
/// CJK-dominant → English, otherwise → Chinese. The model prompt stays English (instructions
/// carry the target language per direction).
public enum TidyTranslate {
    public static let maximumLength = 2000

    public static func isCJK(_ text: String) -> Bool {
        let cjk = text.unicodeScalars.filter { c in
            (0x4E00...0x9FFF).contains(c.value) || (0x3400...0x4DBF).contains(c.value)
        }.count
        guard !text.isEmpty else { return false }
        return Double(cjk) / Double(text.unicodeScalars.count) > 0.3
    }

    /// English → Chinese.
    public static let toChineseInstructions = """
    You are a translator inside a web browser. Translate the user's text from English to natural,     fluent Simplified Chinese. Keep the meaning and tone; translate idiomatically, not literally.     Reply with the translation only — no quotes, no explanation, no transliteration notes.
    """

    /// Chinese → English.
    public static let toEnglishInstructions = """
    You are a translator inside a web browser. Translate the user's text from Simplified Chinese     to natural, fluent English. Keep the meaning and tone; translate idiomatically, not literally.     Reply with the translation only — no quotes, no explanation, no notes.
    """

    public static func instructions(for text: String) -> String {
        isCJK(text) ? toEnglishInstructions : toChineseInstructions
    }

    public static func prompt(_ text: String) -> String {
        "Translate this text:\n\n\(text.prefix(maximumLength))"
    }

    /// The answer as a translation, or nil when it isn't usable: empty, multi-line, or an
    /// echo of the input.
    public static func clean(_ answer: String, original: String) -> String? {
        var s = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        s = s.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’")))
        guard !s.isEmpty, s != original.trimmingCharacters(in: .whitespaces) else { return nil }
        return s
    }
}
