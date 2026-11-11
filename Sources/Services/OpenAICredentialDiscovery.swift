import Foundation

/// UI-safe metadata. Secret values stay in the credential resolver.
struct OpenAICredentialDetection: Sendable {
    var adminSource: String?
    var hasSavedKey = false
    var hasProjectKey = false
    var hasChatGPTSignIn = false
    var title: String {
        if adminSource != nil { return "Admin API key detected" }
        if hasProjectKey { return "OpenAI API key detected · Admin key needed" }
        if hasChatGPTSignIn { return "Codex sign-in detected · Admin key needed" }
        return "No Admin API key found on this Mac"
    }
    var detail: String {
        if let adminSource { return "Using \(adminSource). Costs access is checked when you refresh." }
        if hasProjectKey || hasChatGPTSignIn {
            return "Your existing API key or Codex login cannot access organization billing. An Admin API key is required for the Costs API."
        }
        return "Automatically checks Keychain, OpenAI environment variables, shell settings and Codex credentials."
    }
}

struct OpenAICredentialFile: Sendable {
    enum Kind: Sendable { case shell, codex }
    var source: String
    var kind: Kind
    var data: Data
}

enum OpenAICredentialDiscovery {
    struct Resolution: Sendable {
        var key: String?
        var detection: OpenAICredentialDetection
    }
    static func resolve(savedKey: String?, environment: [String: String], launchEnvironment: [String: String], files: [OpenAICredentialFile]) -> Resolution {
        var result = Resolution(detection: OpenAICredentialDetection(hasSavedKey: savedKey != nil))
        func consider(_ value: String?, name: String, source: String) {
            guard let key = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  key.hasPrefix("sk-"), key.count > 3,
                  key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else { return }
            // A project key or ChatGPT login is not an administrative credential.
            // An explicit OPENAI_ADMIN_KEY may also contain a legacy-format key.
            let administrative = key.hasPrefix("sk-admin-") || (name == "OPENAI_ADMIN_KEY" && !key.hasPrefix("sk-proj-") && !key.hasPrefix("sk-svcacct-"))
            if administrative {
                if result.key == nil { result.key = key; result.detection.adminSource = source }
            } else { result.detection.hasProjectKey = true }
        }
        consider(savedKey, name: "OPENAI_ADMIN_KEY", source: "this app’s Keychain")
        for name in ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"] {
            consider(environment[name], name: name, source: "\(name) environment variable")
            consider(launchEnvironment[name], name: name, source: "\(name) macOS login environment")
        }
        for file in files {
            switch file.kind {
            case .shell:
                for (name, value) in shellAssignments(file.data) {
                    consider(value, name: name, source: file.source + " (\(name))")
                }
            case .codex:
                guard let json = (try? JSONSerialization.jsonObject(with: file.data)) as? [String: Any] else { continue }
                for name in ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"] {
                    consider(json[name] as? String, name: name, source: file.source)
                }
                if let tokens = json["tokens"] as? [String: Any],
                   let token = tokens["access_token"] as? String, !token.isEmpty {
                    result.detection.hasChatGPTSignIn = true
                }
            }
        }
        return result
    }
    private static func shellAssignments(_ data: Data) -> [(String, String)] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        // Read literal assignments only. Never execute shell startup files,
        // command substitutions, credential helpers or arbitrary expressions.
        let pattern = #"^\s*(?:export\s+)?(OPENAI_ADMIN_KEY|OPENAI_API_KEY)\s*=\s*(?:"(sk-[A-Za-z0-9_-]+)"|'(sk-[A-Za-z0-9_-]+)'|(sk-[A-Za-z0-9_-]+))\s*(?:#.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var assignments: [(String, String)] = []
        for line in content.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line) else { continue }
            for index in 2...4 {
                if let valueRange = Range(match.range(at: index), in: line) {
                    assignments.append((String(line[nameRange]), String(line[valueRange]))); break
                }
            }
        }
        // The last literal assignment in a file takes precedence.
        return Array(assignments.reversed())
    }
}
