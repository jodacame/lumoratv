import Foundation

/// Calls any OpenAI-compatible chat-completions endpoint (OpenAI, Gemini, Groq,
/// OpenRouter, Anthropic, or a custom/local URL like Ollama/LM Studio). The body
/// is intentionally minimal (model + messages) so it also works with reasoning
/// models that reject `temperature`/`max_tokens`.
enum AIService {
    struct Config: Sendable {
        let baseURL: String
        let apiKey: String?
        let model: String
    }

    static func providerBaseURL(_ provider: String, custom: String) -> String {
        switch provider {
        case "gemini": "https://generativelanguage.googleapis.com/v1beta/openai"
        case "groq": "https://api.groq.com/openai/v1"
        case "openrouter": "https://openrouter.ai/api/v1"
        case "anthropic": "https://api.anthropic.com/v1"
        case "custom": custom.trimmingCharacters(in: .whitespaces)
        default: "https://api.openai.com/v1"
        }
    }

    /// Explains a word like a friendly language tutor, in the learner's language.
    static func explainWord(_ word: String, sentence: String, target: String, native: String, config: Config) async -> String? {
        let targetName = languageName(target)
        let nativeName = languageName(native)
        let system = "You are a concise language tutor for a learner whose native language is \(nativeName), learning \(targetName). ALWAYS answer in \(nativeName). Be very brief."
        let user = """
        Word: "\(word)" (\(targetName)). Context: "\(sentence)".
        In \(nativeName), very short (max ~4 lines), give: meaning · part of speech · how it's used (note if idiom/slang) · one short \(targetName) example with its \(nativeName) translation. No preamble, no markdown headers.
        """
        return await chat(system: system, user: user, config: config)
    }

    /// Explains a whole subtitle line (meaning + word breakdown) using the
    /// surrounding lines as context, answering in the learner's language.
    static func explainLine(_ sentence: String, context: [String], target: String, native: String, config: Config) async -> String? {
        let targetName = languageName(target)
        let nativeName = languageName(native)
        let ctx = context.isEmpty ? "" : "Conversation context (\(targetName)):\n" + context.joined(separator: "\n") + "\n\n"
        let system = "You are a concise language tutor for a learner whose native language is \(nativeName), learning \(targetName). Always answer in \(nativeName)."
        let user = """
        \(ctx)Explain this \(targetName) line: "\(sentence)".
        In \(nativeName), concise:
        1) Natural meaning of the whole line (translation + any nuance or idiom).
        2) Quick word-by-word breakdown of the key words (word — meaning).
        Use the context to disambiguate. No preamble, no markdown headers.
        """
        return await chat(system: system, user: user, config: config)
    }

    /// Lists the models the key has access to (GET /models) — also validates the
    /// key/URL. Returns nil on failure (bad key, unreachable, unsupported).
    static func listModels(config: Config) async -> [String]? {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models") else { return nil }
        var req = URLRequest(url: url)
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 20
        struct Resp: Decodable { struct M: Decodable { let id: String }; let data: [M]? }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let ids = (try JSONDecoder().decode(Resp.self, from: data).data ?? []).map(\.id)
            return ids.isEmpty ? nil : ids.sorted()
        } catch {
            return nil
        }
    }

    static func chat(system: String, user: String, config: Config) async -> String? {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        struct Resp: Decodable {
            struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg? }
            let choices: [Choice]?
        }
        do {
            let (respData, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let r = try JSONDecoder().decode(Resp.self, from: respData)
            let text = r.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        } catch {
            return nil
        }
    }

    private static func languageName(_ code: String) -> String {
        let c = String(code.prefix(2))
        return Locale(identifier: "en").localizedString(forLanguageCode: c)?.capitalized ?? c
    }
}
