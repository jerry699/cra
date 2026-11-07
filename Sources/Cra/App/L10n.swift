import AppKit

/// Cra's interface language ("en" / "zh-Hans"), picked in Settings and kept in
/// UserDefaults. English stays the source of truth in code: `tr()` looks the
/// English string up in the language's Localizable.strings and returns it as-is
/// when there is no entry, so an English user sees exactly what they saw before
/// and an incomplete translation degrades string by string instead of breaking.
///
/// The strings file is loaded by hand rather than through NSLocalizedString,
/// because the call sites keep plain English literals: the English text is the
/// key, so a missing entry is always safe and translators work on one
/// resources/zh-Hans.lproj/Localizable.strings file.
enum L10n {
    /// The pickable languages, in menu order. Names are written in their own
    /// language so the picker reads the same in every UI language.
    static let available: [(code: String, name: String)] = [("en", "English"), ("zh-Hans", "简体中文")]

    static let defaultsKey = "interfaceLanguage"

    /// The chosen language, "en" unless the user picked another one. Read on
    /// every call so a Settings change takes effect without a launch.
    static var language: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? "en"
    }

    private static let lock = NSLock()
    private static var table: [String: String] = [:]
    private static var tableLanguage = ""

    /// The translation of `english`, or `english` itself when the active
    /// language is English or has no entry for it.
    static func tr(_ english: String) -> String {
        let language = language
        guard language != "en" else { return english }
        lock.lock()
        if tableLanguage != language {
            table = load(language)
            tableLanguage = language
        }
        let entry = table[english]
        lock.unlock()
        return entry ?? english
    }

    /// The translation of a format string ("Switch to %@"), formatted with
    /// `args`. The bundle locale stays out of it: Cra formats in the user's
    /// number/date habits already, and a placeholder swap needs no locale.
    static func tr(_ english: String, _ args: CVarArg...) -> String {
        String(format: tr(english), arguments: args)
    }

    /// Extra command-bar search phrases for a KeyAction id ("关闭 关标签"),
    /// split on spaces; empty in English. Keyed "trigger.<action id>".
    static func triggers(for id: String) -> [String] {
        let entry = tr("trigger.\(id)")
        guard entry != "trigger.\(id)" else { return [] }
        return entry.split(separator: " ").map(String.init)
    }

    /// The display name of a KeyAction. Entries keyed "name.<action id>" win:
    /// numbered commands ("Go to Space 3") are composed at runtime, so their
    /// names have no exact English key to translate. Everything else translates
    /// the English name; a missing entry falls back to it.
    static func actionName(id: String, fallback: String) -> String {
        let keyed = tr("name.\(id)")
        guard keyed != "name.\(id)" else { return tr(fallback) }
        return keyed
    }

    /// Whether a language with translations is active (menus ask, to decide
    /// whether to rebuild themselves after a Settings change).
    static var isLocalized: Bool { language != "en" }

    /// Picks a language: keeps it in UserDefaults and has the menu bar rebuilt.
    /// Views that build their strings once (tooltips, menu rows) pick the change
    /// up on their next rebuild; a few stay until the next launch.
    static func setLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: defaultsKey)
        lock.lock()
        tableLanguage = ""  // the next tr() reloads the table
        lock.unlock()
        NotificationCenter.default.post(name: .craKeyBindingsChanged, object: nil)
    }

    private static func load(_ language: String) -> [String: String] {
        guard
            let path = Bundle.main.path(forResource: "Localizable", ofType: "strings",
                                        inDirectory: nil, forLocalization: language),
            let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        else { return [:] }
        return dict
    }
}
