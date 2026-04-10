import Foundation

nonisolated enum AppLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case englishCA = "en-CA"
    case frenchCA = "fr-CA"

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .englishCA: "English (Canada)"
        case .frenchCA: "Fran\u{00E7}ais (Canada)"
        }
    }

    var shortName: String {
        switch self {
        case .englishCA: "EN"
        case .frenchCA: "FR"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var speechLocaleIdentifier: String {
        rawValue
    }

    var bcp47: String {
        rawValue
    }

    var systemPromptLanguageInstruction: String {
        switch self {
        case .englishCA:
            "Respond in English. Use Canadian English spelling and conventions."
        case .frenchCA:
            "R\u{00E9}ponds en fran\u{00E7}ais canadien. Utilise le vocabulaire et les expressions du Qu\u{00E9}bec et du Canada francophone, pas le fran\u{00E7}ais de France sauf demande explicite."
        }
    }
}
