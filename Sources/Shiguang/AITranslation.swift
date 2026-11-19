import Foundation
import CryptoKit

enum TranslationProvider: String, Codable, CaseIterable, Identifiable {
    case apple
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return L("Apple 翻译")
        case .ai: return L("AI 翻译")
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

struct AIModelOption: Identifiable, Hashable {
    let id: String
    let title: String
}

struct AITranslationResult {
    let text: String
    let api: AITranslationAPI
    let usedFallback: Bool
}

enum AITranslationError: LocalizedError {
    case aiMissingAPIKey
    case aiInvalidEndpoint
    case aiInvalidResponse
    case aiEmptyResponse
    case aiEmptyModelList
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
        case .aiEmptyModelList:
            return "AI 服务没有返回可用模型。请确认接口地址、协议和 API Key。"
        case .aiServer(let status, let message):
            return message.isEmpty ? "AI 服务请求失败（HTTP \(status)）。" : "AI 服务请求失败（HTTP \(status)）：\(message)"
        }
    }
}

/// API keys live in a permission-restricted file under Application Support instead of
/// the Keychain. Every rebuild produces a new code signature, and Keychain ACLs are
/// bound to the binary that created them, so macOS kept asking for authorization after
/// each update. A local file carries no such binding.
enum AITranslationKeychain {
    static func load(for api: AITranslationAPI) -> String {
        loadFromFile(account: api.rawValue) ?? ""
    }

    static func save(_ value: String, for api: AITranslationAPI) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeToFile(key, account: api.rawValue)
    }

    /// True when no local key file has been written yet, so settings can explain the
    /// one-time re-entry needed by users coming from the Keychain-based build.
    static var hasStoredKeyFile: Bool {
        guard let url = storeURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Local store

    private static var storeURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let directory = support.appendingPathComponent("Shiguang", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("ai-keys.json")
    }

    private static func loadStore() -> [String: String] {
        guard let url = storeURL, let data = try? Data(contentsOf: url),
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dictionary
    }

    private static func loadFromFile(account: String) -> String? {
        guard let sealed = loadStore()[account],
              let payload = Data(base64Encoded: sealed) else { return nil }
        return decrypt(payload)
    }

    private static func writeToFile(_ value: String, account: String) throws {
        guard let url = storeURL else { throw error("找不到应用数据目录。") }
        var store = loadStore()
        if value.isEmpty {
            store.removeValue(forKey: account)
        } else {
            guard let payload = encrypt(value) else { throw error("无法加密 API Key。") }
            store[account] = payload.base64EncodedString()
        }
        let data = try JSONEncoder().encode(store)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    // This keeps keys out of plain-text backups and casual inspection. It is
    // obfuscation, not protection against a local attacker.
    private static var encryptionKey: SymmetricKey {
        let seed = "dev.shiguang.screenshot.ai-key.v1"
        return SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
    }

    private static func encrypt(_ value: String) -> Data? {
        guard let sealed = try? AES.GCM.seal(Data(value.utf8), using: encryptionKey) else { return nil }
        return sealed.combined
    }

    private static func decrypt(_ data: Data) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: encryptionKey) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "PawShotAIKey", code: -1,
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

    func translateWithProtocolFallback(text: String, source: String, target: String,
                                       configuration: AITranslationConfiguration,
                                       apiKey: String) async throws -> AITranslationResult {
        do {
            let translated = try await translate(
                text: text,
                source: source,
                target: target,
                configuration: configuration,
                apiKey: apiKey
            )
            return AITranslationResult(text: translated,
                                       api: configuration.api,
                                       usedFallback: false)
        } catch {
            guard let fallback = Self.fallbackAPI(for: configuration.api, after: error) else {
                throw error
            }
            var fallbackConfiguration = configuration
            fallbackConfiguration.api = fallback
            let translated = try await translate(
                text: text,
                source: source,
                target: target,
                configuration: fallbackConfiguration,
                apiKey: apiKey
            )
            return AITranslationResult(text: translated,
                                       api: fallback,
                                       usedFallback: true)
        }
    }

    func fetchModels(configuration: AITranslationConfiguration,
                     apiKey: String) async throws -> [AIModelOption] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || configuration.allowsEmptyAPIKey else {
            throw AITranslationError.aiMissingAPIKey
        }
        guard let endpoint = Self.modelsEndpoint(for: configuration) else {
            throw AITranslationError.aiInvalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch configuration.api {
        case .openAIChat, .openAIResponses:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .anthropicMessages:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            if !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AITranslationError.aiInvalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AITranslationError.aiServer(http.statusCode, Self.errorMessage(from: data))
        }
        let models = Self.models(from: data, api: configuration.api)
        guard !models.isEmpty else { throw AITranslationError.aiEmptyModelList }
        return models
    }

    static func endpoint(for baseURL: String) -> URL? {
        endpoint(for: AITranslationConfiguration(baseURL: baseURL), allowInsecureLoopback: true)
    }

    static func endpoint(for configuration: AITranslationConfiguration) -> URL? {
        endpoint(for: configuration, allowInsecureLoopback: true)
    }

    private static func endpoint(for configuration: AITranslationConfiguration,
                                 allowInsecureLoopback: Bool) -> URL? {
        guard var components = validatedComponents(
            configuration.baseURL,
            allowInsecureLoopback: allowInsecureLoopback
        ) else { return nil }
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

    static func modelsEndpoint(for configuration: AITranslationConfiguration) -> URL? {
        guard var components = validatedComponents(
            configuration.baseURL,
            allowInsecureLoopback: true
        ) else { return nil }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        for suffix in ["chat/completions", "responses", "messages"] {
            if path == suffix {
                path = ""
                break
            }
            if path.hasSuffix("/\(suffix)") {
                path.removeLast(suffix.count + 1)
                break
            }
        }

        if let operation = path.range(of: ":generateContent") {
            let modelPath = path[..<operation.lowerBound]
            if let models = modelPath.range(of: "models/", options: .backwards) {
                let prefix = modelPath[..<models.lowerBound]
                path = String(prefix) + "models"
            }
        }

        if path != "models", !path.hasSuffix("/models") {
            path = path.isEmpty ? "models" : "\(path)/models"
        }
        components.path = "/" + path
        return components.url
    }

    private static func validatedComponents(_ baseURL: String,
                                            allowInsecureLoopback: Bool) -> URLComponents? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        let loopback = ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
        guard scheme == "https" || (allowInsecureLoopback && scheme == "http" && loopback) else {
            return nil
        }
        return components
    }

    static func isLoopbackBaseURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
    }

    static func fallbackAPI(for current: AITranslationAPI, after error: Error) -> AITranslationAPI? {
        guard let serviceError = error as? AITranslationError,
              case .aiServer(let status, let message) = serviceError else { return nil }
        let detail = message.lowercased()
        let endpointMissing = [404, 405, 501].contains(status)
            || (status == 400 && ["endpoint", "not found", "unsupported", "unknown"].contains {
                detail.contains($0)
            })
        guard endpointMissing else { return nil }
        switch current {
        case .openAIChat: return .openAIResponses
        case .openAIResponses: return .openAIChat
        case .anthropicMessages, .gemini: return nil
        }
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

    static func models(from data: Data, api: AITranslationAPI) -> [AIModelOption] {
        let rootObject = try? JSONSerialization.jsonObject(with: data)
        let records: [[String: Any]]
        if let root = rootObject as? [String: Any] {
            switch api {
            case .gemini:
                records = root["models"] as? [[String: Any]]
                    ?? root["data"] as? [[String: Any]]
                    ?? []
            case .openAIChat, .openAIResponses, .anthropicMessages:
                records = root["data"] as? [[String: Any]]
                    ?? root["models"] as? [[String: Any]]
                    ?? []
            }
        } else {
            records = rootObject as? [[String: Any]] ?? []
        }

        var seen = Set<String>()
        var options: [AIModelOption] = []
        for record in records {
            guard let rawID = record["id"] as? String
                    ?? record["name"] as? String
                    ?? record["model"] as? String else { continue }
            let id = rawID.replacingOccurrences(of: "^models/", with: "",
                                                options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let display = record["display_name"] as? String
                ?? record["displayName"] as? String
            let title = display?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? id
            options.append(AIModelOption(id: id, title: resolvedTitle))
        }
        return options.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
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
