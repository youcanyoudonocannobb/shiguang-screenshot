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

enum AITranslationAPI: String, Codable, CaseIterable, Identifiable {
    case openAIChat
    case openAIResponses
    case anthropicMessages
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAIChat: return "OpenAI Chat"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Claude Messages"
        case .gemini: return "Gemini"
        }
    }

    var detail: String {
        switch self {
        case .openAIChat:
            return "兼容 OpenAI Chat Completions 的云端或本地服务"
        case .openAIResponses:
            return "OpenAI Responses API"
        case .anthropicMessages:
            return "Anthropic Claude Messages API"
        case .gemini:
            return "Google Gemini generateContent API"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAIChat, .openAIResponses:
            return "https://api.openai.com/v1"
        case .anthropicMessages:
            return "https://api.anthropic.com/v1"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAIChat:
            return "gpt-4o-mini"
        case .openAIResponses:
            return "gpt-5-mini"
        case .anthropicMessages:
            return "claude-sonnet-4-5"
        case .gemini:
            return "gemini-2.5-flash"
        }
    }
}

struct AITranslationConfiguration: Equatable {
    var baseURL: String = AITranslationAPI.openAIChat.defaultBaseURL
    var model: String = AITranslationAPI.openAIChat.defaultModel
    var instructions: String = ""
    var api: AITranslationAPI = .openAIChat

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var allowsEmptyAPIKey: Bool {
        AITranslationService.isLoopbackBaseURL(baseURL)
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
            return "接口地址无效。请填写 HTTPS 地址；本机服务可使用 http://127.0.0.1 或 http://localhost。"
        case .aiInvalidResponse:
            return "AI 服务返回了无法识别的数据。请确认接口地址、协议与模型匹配。"
        case .aiEmptyResponse:
            return "AI 服务没有返回译文。请检查模型名称或稍后重试。"
        case .aiServer(let status, let message):
            return message.isEmpty ? "AI 服务请求失败（HTTP \(status)）。" : "AI 服务请求失败（HTTP \(status)）：\(message)"
        }
    }
}

enum AITranslationKeychain {
    private static let service = "dev.shiguang.screenshot.ai-translation"

    static func load(for api: AITranslationAPI) -> String {
        let value = load(account: api.rawValue)
        if !value.isEmpty || api != .openAIChat { return value }
        // Migrate the single key stored by versions before protocol support.
        return load(account: "api-key")
    }

    static func save(_ value: String, for api: AITranslationAPI) throws {
        try save(value, account: api.rawValue)
    }

    private static func load(account: String) -> String {
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

    private static func save(_ value: String, account: String) throws {
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
        guard !key.isEmpty || configuration.allowsEmptyAPIKey else {
            throw AITranslationError.aiMissingAPIKey
        }
        guard let endpoint = Self.endpoint(for: configuration) else {
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

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)

        switch configuration.api {
        case .openAIChat:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": text]
                ],
                "temperature": 0.2
            ])
        case .openAIResponses:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "instructions": system,
                "input": text
            ])
        case .anthropicMessages:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 4096,
                "temperature": 0.2,
                "system": system,
                "messages": [["role": "user", "content": text]]
            ])
        case .gemini:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": ["temperature": 0.2]
            ])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AITranslationError.aiInvalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AITranslationError.aiServer(http.statusCode, Self.errorMessage(from: data))
        }
        guard let content = Self.content(from: data, api: configuration.api)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw AITranslationError.aiEmptyResponse
        }
        return content
    }

    static func endpoint(for baseURL: String) -> URL? {
        endpoint(for: AITranslationConfiguration(baseURL: baseURL), allowInsecureLoopback: true)
    }

    static func endpoint(for configuration: AITranslationConfiguration) -> URL? {
        endpoint(for: configuration, allowInsecureLoopback: true)
    }

    private static func endpoint(for configuration: AITranslationConfiguration,
                                 allowInsecureLoopback: Bool) -> URL? {
        let baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
        guard scheme == "https" || (allowInsecureLoopback && scheme == "http" && loopback) else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix: String
        switch configuration.api {
        case .openAIChat:
            guard !path.hasSuffix("chat/completions") else { return components.url }
            suffix = "chat/completions"
        case .openAIResponses:
            guard !path.hasSuffix("responses") else { return components.url }
            suffix = "responses"
        case .anthropicMessages:
            guard !path.hasSuffix("messages") else { return components.url }
            suffix = "messages"
        case .gemini:
            guard !path.contains(":generateContent") else { return components.url }
            let modelPath = model.replacingOccurrences(of: "^models/", with: "",
                                                       options: .regularExpression)
            suffix = path.hasSuffix("models")
                ? "\(modelPath):generateContent"
                : "models/\(modelPath):generateContent"
        }
        components.path = "/" + (path.isEmpty ? suffix : "\(path)/\(suffix)")
        return components.url
    }

    static func isLoopbackBaseURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
    }

    static func languageName(_ identifier: String) -> String {
        if identifier == "auto" { return "the detected source language" }
        return LanguageChoice.targets.first(where: { $0.id == identifier })?.name ?? identifier
    }

    private static func content(from data: Data, api: AITranslationAPI) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch api {
        case .openAIChat:
            if let choices = root["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any] {
                if let content = message["content"] as? String { return content }
                if let parts = message["content"] as? [[String: Any]] {
                    return parts.compactMap(textFromPart).joined()
                }
            }
            return root["output_text"] as? String
        case .openAIResponses:
            if let outputText = root["output_text"] as? String { return outputText }
            guard let output = root["output"] as? [[String: Any]] else { return nil }
            return output.flatMap { item in
                (item["content"] as? [[String: Any]])?.compactMap(textFromPart) ?? []
            }.joined()
        case .anthropicMessages:
            guard let parts = root["content"] as? [[String: Any]] else { return nil }
            return parts.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            guard let candidates = root["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return nil }
            return parts.compactMap { $0["text"] as? String }.joined()
        }
    }

    private static func textFromPart(_ part: [String: Any]) -> String? {
        if let text = part["text"] as? String { return text }
        if let text = part["text"] as? [String: Any] { return text["value"] as? String }
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
