import Foundation
import Observation

enum AppLanguage: String, CaseIterable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    static func systemLanguage(for preferences: [String]) -> AppLanguage {
        for identifier in preferences {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "zh": return .chinese
            case "en": return .english
            default: continue
            }
        }
        return .english
    }

    var title: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

@Observable
final class L10n {
    static let shared = L10n()
    private static let preferenceKey = "interfaceLanguage"
    private static let englishBundle = Bundle.main.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))

    var preference: AppLanguage {
        get {
            access(keyPath: \.preference)
            return UserDefaults.standard.string(forKey: Self.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            guard newValue != preference else { return }
            withMutation(keyPath: \.preference) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.preferenceKey)
            }
        }
    }

    var locale: Locale {
        access(keyPath: \.locale)
        switch preference {
        case .system:
            return Locale(identifier: AppLanguage.systemLanguage(for: Locale.preferredLanguages).rawValue)
        case .english: return Locale(identifier: "en")
        case .chinese: return Locale(identifier: "zh-Hans")
        }
    }

    func refreshSystemLanguage() {
        if preference == .system { withMutation(keyPath: \.locale) {} }
    }

    @TaskLocal fileprivate static var formattingLocale: Locale?
    fileprivate static var activeLocale: Locale { formattingLocale ?? shared.locale }

    static func text(_ key: String) -> String {
        guard activeLocale.identifier == "en" else { return key }
        return englishBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: activeLocale, arguments: arguments)
    }
}

// Retain both renderings of transient UI feedback, including its original arguments.
// Resolve on display so a language change never repeats the underlying operation.
struct InterfaceMessage: Equatable, Sendable, ExpressibleByStringLiteral {
    let chinese: String
    let english: String

    init(_ render: () -> String) {
        chinese = L10n.$formattingLocale.withValue(Locale(identifier: "zh-Hans"), operation: render)
        english = L10n.$formattingLocale.withValue(Locale(identifier: "en"), operation: render)
    }

    init(stringLiteral key: String) { self.init { L10n.text(key) } }

    var text: String { L10n.activeLocale.identifier == "en" ? english : chinese }
}
