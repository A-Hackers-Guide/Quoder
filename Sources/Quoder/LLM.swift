import Foundation

// The OpenAI-style chat API that llama-server speaks.

struct ToolCall: Codable, Equatable, Identifiable {
    struct Function: Codable, Equatable { var name: String; var arguments: String }
    var id: String
    var type = "function"
    var function: Function
}

struct APIMessage: Codable {
    var role: String
    var content: String?
    var tool_calls: [ToolCall]?
    var tool_call_id: String?
}

enum LLMError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case let .http(code, body): return "The model server answered \(code): \(body.prefix(300))"
        }
    }
}

struct LLM {
    var config: Config

    private func request(_ body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: config.baseURL.appendingPathComponent("v1/chat/completions"))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { r.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    private func encode(_ messages: [APIMessage]) throws -> [[String: Any]] {
        let d = try JSONEncoder().encode(messages)
        return (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
    }

    /// Streams one reply. onText gets each new piece of text; the result is
    /// the full text and any tool calls the model made.
    func stream(_ messages: [APIMessage], tools: [[String: Any]],
                onText: @escaping (String) -> Void) async throws -> (String, [ToolCall]) {
        // Slot 0 keeps the conversation already read, so each step only reads
        // what's new; double-checks use slot 1 and don't evict it.
        var body: [String: Any] = ["model": config.model, "messages": try encode(messages), "stream": true,
                                   "id_slot": 0, "cache_prompt": true]
        if !tools.isEmpty { body["tools"] = tools }
        let (bytes, resp) = try await URLSession.shared.bytes(for: try request(body))
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            var s = ""; for try await line in bytes.lines { s += line }
            throw LLMError.http(h.statusCode, s)
        }
        var text = ""
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choice = (obj["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }
            if let t = delta["content"] as? String, !t.isEmpty { text += t; onText(t) }
            for tc in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let i = tc["index"] as? Int ?? 0
                var c = calls[i] ?? (id: "", name: "", args: "")
                if let id = tc["id"] as? String, !id.isEmpty { c.id = id }
                if let f = tc["function"] as? [String: Any] {
                    if let n = f["name"] as? String { c.name += n }
                    if let a = f["arguments"] as? String { c.args += a }
                }
                calls[i] = c
            }
        }
        let out = calls.keys.sorted().compactMap { k -> ToolCall? in
            let c = calls[k]!
            guard !c.name.isEmpty else { return nil }
            return ToolCall(id: c.id.isEmpty ? "call_\(k)_\(UUID().uuidString.prefix(8))" : c.id,
                            function: .init(name: c.name, arguments: c.args.isEmpty ? "{}" : c.args))
        }
        if out.isEmpty, let parsed = LLM.toolCalls(inText: text) { return ("", parsed) }
        return (text, out)
    }

    /// Qwen2.5 Coder often writes its tool calls as plain JSON
    /// ({"name": ..., "arguments": {...}}), sometimes inside <tool_call> tags or
    /// a ```json block, instead of the tagged form the server recognizes.
    static func toolCalls(inText text: String) -> [ToolCall]? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<tool_call>", "</tool_call>", "```json", "```"] { s = s.replacingOccurrences(of: tag, with: "\n") }
        var found: [ToolCall] = []
        var depth = 0, start: String.Index?
        var inString = false, escaped = false
        for i in s.indices {
            let ch = s[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            if ch == "\"" { inString = true }
            else if ch == "{" { if depth == 0 { start = i }; depth += 1 }
            else if ch == "}", depth > 0 {
                depth -= 1
                if depth == 0, let st = start {
                    let chunk = String(s[st...i])
                    if let obj = try? JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [String: Any],
                       let name = obj["name"] as? String, Tools.names.contains(name) {
                        var args = obj["arguments"] ?? obj["parameters"] ?? [String: Any]()
                        if let str = args as? String, let o = try? JSONSerialization.jsonObject(with: Data(str.utf8)) { args = o }
                        let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                        found.append(ToolCall(id: "call_\(UUID().uuidString.prefix(8))",
                                              function: .init(name: name, arguments: String(decoding: data, as: UTF8.self))))
                    }
                    start = nil
                }
            }
        }
        // Only when the reply is essentially just the call(s), not prose that mentions JSON.
        let leftover = s.replacingOccurrences(of: #"\{[\s\S]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty || leftover.count > 200 ? nil : found
    }

    /// One short reply without tools (used for double-checking actions).
    func complete(_ messages: [APIMessage]) async throws -> String {
        let body: [String: Any] = ["model": config.model, "messages": try encode(messages), "stream": false,
                                   "id_slot": 1, "cache_prompt": true]
        let (data, resp) = try await URLSession.shared.data(for: try request(body))
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw LLMError.http(h.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        return msg?["content"] as? String ?? ""
    }
}
