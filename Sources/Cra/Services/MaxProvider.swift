import Foundation
import Security

/// Max features on a model of the user's own, when Apple Intelligence can't run (an Intel Mac,
/// an older macOS): an OpenAI-compatible chat endpoint with the user's API key. DeepSeek, Qwen
/// and GLM ship presets; any other provider works through Custom. Cra only ever sends what the
/// Apple Intelligence path composes too — tab titles and site names (TidyDownloads: file names) —
/// and MaxPane says so.
///
/// The key lives in its own Keychain item (Cra keeps no other user secrets; SafeStorage's item is
/// Chromium's). The rest of the configuration is UserDefaults, read on every call so a Settings
/// change takes effect at once. CraLog notes counts and timings, never the key or prompt text.
enum MaxRemote {
    /// The providers MaxPane offers. Apple Intelligence stays out of this enum: it is the
    /// default path and needs no configuration.
    enum Provider: String, CaseIterable {
        case off, deepseek, qwen, glm, custom

        /// The preset endpoint and model; Custom leaves both to the user.
        var preset: (baseURL: String, model: String)? {
            switch self {
            case .off: return nil
            case .deepseek: return ("https://api.deepseek.com/v1", "deepseek-chat")
            case .qwen: return ("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-flash")
            case .glm: return ("https://open.bigmodel.cn/api/paas/v4", "glm-4-flash")
            case .custom: return nil
            }
        }

        /// What Settings and the log call it ("DeepSeek", "Custom provider").
        var label: String {
            switch self {
            case .off: return "Off"
            case .deepseek: return "DeepSeek"
            case .qwen: return "Qwen"
            case .glm: return "GLM"
            case .custom: return "Custom"
            }
        }
    }

    private static let service = "Cra Max"

    // MARK: Configuration (UserDefaults + Keychain)

    static var provider: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: "maxProvider") ?? "") ?? .off
    }

    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "maxBaseURL") ?? ""
        if !stored.isEmpty { return stored }
        return provider.preset?.baseURL ?? ""
    }

    static var model: String {
        let stored = UserDefaults.standard.string(forKey: "maxModel") ?? ""
        if !stored.isEmpty { return stored }
        return provider.preset?.model ?? ""
    }

    /// True when MaxPane's Toggles may turn on: a cloud provider picked, all three fields filled.
    static var isConfigured: Bool {
        provider != .off && !baseURL.isEmpty && !model.isEmpty && !(key()?.isEmpty ?? true)
    }

    static func setProvider(_ provider: Provider) {
        CraLog.note(String(format: "Max: provider set to %@", provider.rawValue))
        // Switching presets fills the fields they imply, but keeps a Custom answer.
        if let preset = provider.preset, provider != .custom {
            UserDefaults.standard.set(preset.baseURL, forKey: "maxBaseURL")
            UserDefaults.standard.set(preset.model, forKey: "maxModel")
        }
        UserDefaults.standard.set(provider.rawValue, forKey: "maxProvider")
    }

    static func setBaseURL(_ url: String) {
        CraLog.note(String(format: "Max: base URL set (%d chars)", url.count))
        UserDefaults.standard.set(url, forKey: "maxBaseURL")
    }
    static func setModel(_ model: String) {
        CraLog.note(String(format: "Max: model set (%d chars)", model.count))
        UserDefaults.standard.set(model, forKey: "maxModel")
    }

    // MARK: The Keychain item

    static func key() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "API Key", kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return String(data: data, encoding: .utf8) }
        guard status == errSecItemNotFound else {
            NSLog("Cra: reading the \(service) Keychain item failed (\(status))")
            return nil
        }
        return nil
    }

    static func setKey(_ key: String) {
        CraLog.note(String(format: "Max: API key set (%d chars)", key.count))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "API Key"]
        let update: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = key.isEmpty
            ? SecItemDelete(query as CFDictionary)
            : SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            NSLog("Cra: updating the \(service) Keychain item failed (\(status))")
            return
        }
        if status == errSecItemNotFound && !key.isEmpty {
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: "API Key", kSecAttrLabel as String: service,
                                       kSecValueData as String: Data(key.utf8)]
            let added = SecItemAdd(item as CFDictionary, nil)
            if added != errSecSuccess { NSLog("Cra: creating the \(service) Keychain item failed (\(added))") }
        }
    }

    // MARK: The call

    /// One chat completion. `json` asks for a JSON object reply (Tidy Tabs' groups); the title
    /// and download renames want plain text. Nil on any failure, which the callers treat the
    /// way they treat a silent model: no tidy this round.
    static func ask(instructions: String, prompt: String, json: Bool) async -> String? {
        guard isConfigured, let url = URL(string: baseURL + "/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key() ?? "")", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["model": model, "temperature": 0,
                                   "messages": [["role": "system", "content": instructions],
                                                ["role": "user", "content": prompt]]]
        if json { body["response_format"] = ["type": "json_object"] }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data

        let started = Date()
        let (replyData, response, error): (Data?, URLResponse?, Error?) = await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                continuation.resume(returning: (data, response, error))
            }.resume()
        }
        let seconds = Date().timeIntervalSince(started)
        guard error == nil, let http = response as? HTTPURLResponse, let replyData else {
            CraLog.note(String(format: "Max (\(provider.label)): request failed after %.1f s", seconds))
            return nil
        }
        guard http.statusCode == 200,
              let reply = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any],
              let choices = reply["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            CraLog.note(String(format: "Max (%@): HTTP %d in %.1f s", provider.label, http.statusCode, seconds))
            return nil
        }
        CraLog.note(String(format: "Max (%@): reply in %.1f s", provider.label, seconds))
        return content
    }
}
