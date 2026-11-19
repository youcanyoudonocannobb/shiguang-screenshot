import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var nativeTitle: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static var stored: AppLanguage {
        AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        ) ?? .simplifiedChinese
    }
}

enum AppLocalization {
    static func text(_ key: String, language: AppLanguage? = nil, bundle: Bundle = .main) -> String {
        let language = language ?? .stored
        guard language != .simplifiedChinese else { return key }
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return key
        }
        return localizedBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

func L(_ key: String) -> String {
    AppLocalization.text(key)
}
