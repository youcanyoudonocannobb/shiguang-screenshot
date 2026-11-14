import Foundation
import Security

enum TranslationProvider: String, Codable, CaseIterable, Identifiable {
    case apple
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple 翻译"
        case .ai: return "AI 翻译"
        }
    }

    var symbol: String {
        switch self {
        case .apple: return "apple.logo"
        case .ai: return "sparkles"
        }
    }
}

struct AITranslationConfiguration: Equatable {
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4o-mini"
    var instructions: String = ""

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum AITranslationError: LocalizedError {
    case aiMissingAPIKey
    case aiInvalidEndpoint
    case aiInvalidResponse
    case aiEmptyResponse
    case aiServer(Int, String)

    var errorDescription: String? {
        switch self {
        case .aiMissingAPIKey:
            return "请先填写 AI 服务的 API Key。"
        case .aiInvalidEndpoint:
            return "接口地址无效。请填写 HTTPS 地址，例如 https://api.openai.com/v1。"
        case .aiInvalidResponse:
            return "AI 服务返回了无法识别的数据。请确认接口兼容 Chat Completions。"
        case .aiEmptyResponse:
            return "AI 服务没有返回译文。请检查模型名称或稍后重试。"
        case .aiServer(let status, let message):
            return message.isEmpty ? "AI 服务请求失败（HTTP \(status)）。" : "AI 服务请求失败（HTTP \(status)）：\(message)"
        }
    }
}

enum AITranslationKeychain {
    private static let service = "dev.shiguang.screenshot.ai-translation"
    private static let account = "api-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(status)
            }
            return
        }

        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw keychainError(updated) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw keychainError(added) }
    }

    private static func keychainError(_ status: OSStatus) -> Error {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "无法保存 API Key：\(message)"])
    }
}

struct AITranslationService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func translate(text: String, source: String, target: String,
                   configuration: AITranslationConfiguration, apiKey: String) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AITranslationError.aiMissingAPIKey }
        guard let endpoint = Self.endpoint(for: configuration.baseURL) else {
            throw AITranslationError.aiInvalidEndpoint
        }
        let sourceName = Self.languageName(source)
        let targetName = Self.languageName(target)
        let custom = configuration.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = """
        You are a professional translation engine. Translate the user's text from \(sourceName) to \(targetName). \
        Preserve paragraphs, Markdown, code, numbers, names, punctuation, and line breaks. \
        Return only the translation, without commentary, labels, or quotation marks.
        """ + (custom.isEmpty ? "" : "\nAdditional user instructions: \(custom)")

        let payload: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text]
            ],
            "temperature": 0.2
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AITranslationError.aiInvalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AITranslationError.aiServer(http.statusCode, Self.errorMessage(from: data))
        }
        guard let content = Self.content(from: data)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw AITranslationError.aiEmptyResponse
        }
        return content
    }

    static func endpoint(for baseURL: String) -> URL? {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme == "https",
              components.host != nil else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("chat/completions") {
            components.path = "/" + path + (path.isEmpty ? "" : "/") + "chat/completions"
        }
        return components.url
    }

    static func languageName(_ identifier: String) -> String {
        if identifier == "auto" { return "the detected source language" }
        return LanguageChoice.targets.first(where: { $0.id == identifier })?.name ?? identifier
    }

    private static func content(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String { return content }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { part in
                part["text"] as? String ?? (part["text"] as? [String: Any])?["value"] as? String
            }.joined()
        }
        return nil
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        if let message = root["message"] as? String { return message }
        return ""
    }
}
