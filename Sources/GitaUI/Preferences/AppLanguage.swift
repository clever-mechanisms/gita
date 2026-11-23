import AppKit

/// App-domain override and process-local formatting, adapted from Bucket.
@MainActor
enum AppLanguage {
    static let targetLanguages = [
        "en", "cs", "de", "es", "fr", "it", "hu", "nl", "pl", "pt-BR", "sv", "th", "tr", "ru", "uk", "ja", "ko",
        "zh-Hans", "zh-Hant",
    ]
    private static let languagesKey = "AppleLanguages"
    private(set) static var current = "en"
    /// The settings domain the override lives in, and its defaults (the development suite in development builds).
    static var environment = AppEnvironment.current

    private static var domain: String {
        environment.isDevelopment ? AppEnvironment.developmentSuite : environment.bundleIdentifier
    }
    private static var preferences: UserDefaults { environment.defaults }

    static var available: [String] {
        let installed = Bundle.main.localizations.filter { targetLanguages.contains($0) }
        return (installed.isEmpty ? ["en"] : installed).sorted {
            name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending
        }
    }
    private static var systemPreferences: [String] {
        CFPreferencesCopyValue(
            languagesKey as CFString, kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? ["en"]
    }
    static var system: String {
        Bundle.preferredLocalizations(from: available, forPreferences: systemPreferences).first ?? "en"
    }
    static var override: String? {
        (preferences.persistentDomain(forName: domain)?[languagesKey] as? [String])?.first
    }
    static var selected: String? {
        guard let override else { return nil }
        return Bundle.preferredLocalizations(from: available, forPreferences: [override]).first
    }
    static var needsRestart: Bool { (selected ?? system) != current }

    static func setOverride(_ code: String?) {
        guard let code else {
            preferences.removeObject(forKey: languagesKey)
            return
        }
        guard available.contains(code) else { return }
        preferences.set([code], forKey: languagesKey)
    }

    static func configureForLaunch() {
        if environment.isDevelopment {
            // Keep development choices out of the installed release's preference domain.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[languagesKey] = override.map { [$0] } ?? systemPreferences
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        current = Bundle.main.preferredLocalizations.first ?? "en"
        let global =
            CFPreferencesCopyValue(
                "AppleLocale" as CFString, kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
            ?? Locale.current.identifier
        var localeArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        localeArguments["AppleLocale"] = locale(global: global, language: current)
        UserDefaults.standard.setVolatileDomain(localeArguments, forName: UserDefaults.argumentDomain)
    }

    /// The user's locale with its language replaced by the app's: dates and numbers keep the user's region.
    static func locale(global: String, language: String) -> String {
        var components = Locale.Components(identifier: global)
        // Ordinary identifiers (es_ES) carry their region inside the language,
        // whereas Components.region is only an explicit regional override.
        // Retain the effective region before replacing the full UI language.
        components.region = Locale(identifier: global).region
        components.languageComponents = Locale.Language.Components(language: Locale.Language(identifier: language))
        return Locale(components: components).identifier
    }

    /// The flag shown beside a language in Settings: its main country's (a globe for the system's choice).
    static func flag(of code: String?) -> String {
        let regions = [
            "en": "US", "cs": "CZ", "de": "DE", "es": "ES", "fr": "FR", "it": "IT", "hu": "HU", "nl": "NL", "pl": "PL",
            "pt-BR": "BR", "sv": "SE", "th": "TH", "tr": "TR", "ru": "RU", "uk": "UA", "ja": "JP", "ko": "KR",
            "zh-Hans": "CN", "zh-Hant": "TW",
        ]
        guard let code, let region = regions[code] else { return "🌐" }
        // Each letter's regional indicator symbol; the pair draws as the flag.
        return String(String.UnicodeScalarView(region.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }))
    }

    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
