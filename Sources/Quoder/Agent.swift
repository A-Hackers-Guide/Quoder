import AppKit
import Foundation

/// One thing shown in a conversation.
struct Item: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case user, assistant, tool, error }
    enum Check: String, Codable { case none, checking, confirmed, corrected }
    var id = UUID()
    var kind: Kind
    var text = ""
    // tool items
    var toolName = ""
    var arguments = ""
    var result = ""
    var running = false
    var check: Check = .none
}

struct Chat: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New chat"
    var created = Date()
    var items: [Item] = []
    /// What the model sees: the whole exchange, including tool calls and results.
    var history: [APIMessage] = []

    static func == (a: Chat, b: Chat) -> Bool { a.id == b.id && a.items == b.items && a.title == b.title }
}

@MainActor
final class Agent: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var currentID: UUID?
    @Published var busy = false
    @Published var config = Config.load()
    let tunnel = Tunnel()
    private var task: Task<Void, Never>?

    static var chatsFolder: URL {
        let u = Config.folder.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Agent.chatsFolder, includingPropertiesForKeys: nil)) ?? []
        chats = files.compactMap { try? JSONDecoder().decode(Chat.self, from: Data(contentsOf: $0)) }.sorted { $0.created > $1.created }
        if chats.isEmpty { chats = [Chat()] }
        currentID = chats.first?.id
        tunnel.start(config)
    }

    var current: Chat? { chats.first { $0.id == currentID } }

    func newChat() {
        if let c = current, c.items.isEmpty { return }
        let c = Chat(); chats.insert(c, at: 0); currentID = c.id
    }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Agent.chatsFolder.appendingPathComponent("\(id).json"))
        if chats.isEmpty { chats = [Chat()] }
        if currentID == id { currentID = chats.first?.id }
    }

    func applyConfig(_ c: Config) { config = c; c.save(); tunnel.start(c) }

    private func update(_ f: (inout Chat) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == currentID }) else { return }
        f(&chats[i])
    }
    private func save() {
        guard let c = current, let d = try? JSONEncoder().encode(c) else { return }
        try? d.write(to: Agent.chatsFolder.appendingPathComponent("\(c.id).json"), options: .atomic)
    }

    var systemPrompt: String {
        let fmt = DateFormatter(); fmt.dateStyle = .full; fmt.timeStyle = .short
        return """
        You are Quoder, an assistant running on the user's own Mac with full use of it through tools: a terminal (run_command), files (read_file, write_file, edit_file, list_directory), and the screen (screen_text and ui_elements to see what is on screen, then click, type_text, press_keys, scroll, open). You cannot see images; screen_text and ui_elements describe the screen as text with x,y positions.
        Work step by step: look before you act, act, then check the result. When a task is done, say briefly what you did.
        Home folder: \(NSHomeDirectory()). macOS \(ProcessInfo.processInfo.operatingSystemVersionString). Now: \(fmt.string(from: Date())).
        """
    }

    func stop() { task?.cancel() }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        update { c in
            if c.history.isEmpty { c.history.append(APIMessage(role: "system", content: systemPrompt)) }
            if c.items.isEmpty { c.title = String(t.prefix(48)) }
            c.items.append(Item(kind: .user, text: t))
            c.history.append(APIMessage(role: "user", content: t))
        }
        save()
        busy = true
        task = Task { await loop(request: t); busy = false; save() }
    }

    private func loop(request: String) async {
        let llm = LLM(config: config)
        for _ in 0..<40 {
            if Task.isCancelled { return note("Stopped.") }
            guard let history = current?.history else { return }
            var itemID = UUID()
            update { c in let it = Item(kind: .assistant); itemID = it.id; c.items.append(it) }
            let id = itemID
            do {
                let (text, calls) = try await llm.stream(history, tools: Tools.definitions) { [weak self] piece in
                    Task { @MainActor in self?.update { c in
                        if let i = c.items.firstIndex(where: { $0.id == id }) { c.items[i].text += piece }
                    } }
                }
                update { c in
                    if let i = c.items.firstIndex(where: { $0.id == id }) {
                        c.items[i].text = text
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.items.remove(at: i) }
                    }
                    c.history.append(APIMessage(role: "assistant", content: text.isEmpty ? nil : text, tool_calls: calls.isEmpty ? nil : calls))
                }
                if calls.isEmpty { return }
                for call in calls {
                    if Task.isCancelled { return note("Stopped.") }
                    let result = await runTool(call, request: request, llm: llm)
                    update { c in c.history.append(APIMessage(role: "tool", content: result, tool_call_id: call.id)) }
                    save()
                }
            } catch is CancellationError {
                return note("Stopped.")
            } catch {
                if Task.isCancelled { return note("Stopped.") }
                update { c in
                    c.items.removeAll { $0.id == id && $0.text.isEmpty }
                    c.items.append(Item(kind: .error, text: error.localizedDescription))
                }
                return
            }
        }
        note("Stopped after 40 steps. Say \"continue\" to keep going.")
    }

    private func note(_ s: String) { update { c in c.items.append(Item(kind: .error, text: s)) } }

    private func runTool(_ call: ToolCall, request: String, llm: LLM) async -> String {
        var argsText = call.function.arguments
        var args = (try? JSONSerialization.jsonObject(with: Data(argsText.utf8))) as? [String: Any] ?? [:]
        var item = Item(kind: .tool, toolName: call.function.name, arguments: argsText, running: true)
        update { c in c.items.append(item) }
        func set(_ f: (inout Item) -> Void) {
            f(&item)
            let snapshot = item
            update { c in if let i = c.items.firstIndex(where: { $0.id == snapshot.id }) { c.items[i] = snapshot } }
        }

        // Risky actions: the model looks again at exactly what it typed.
        if config.selfCheck, Tools.isRisky(call.function.name, args) {
            set { $0.check = .checking }
            if let fixed = await doubleCheck(call.function.name, argsText, request: request, llm: llm) {
                argsText = fixed
                args = (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) as? [String: Any] ?? args
                set { $0.check = .corrected; $0.arguments = fixed }
            } else {
                set { $0.check = .confirmed }
            }
        }

        // The last safety net: a handful of commands that can wipe the Mac.
        if let warning = Tools.catastrophic(call.function.name, args) {
            let a = NSAlert()
            a.messageText = "Quoder wants to run a dangerous command"
            a.informativeText = warning
            a.alertStyle = .critical
            a.addButton(withTitle: "Don't run it"); a.addButton(withTitle: "Run it")
            if a.runModal() != .alertSecondButtonReturn {
                set { $0.running = false; $0.result = "Blocked: you chose not to run this." }
                return "The user blocked this command. Do not try it again; ask them what they want instead."
            }
        }

        let result = await Tools.run(call.function.name, args)
        set { $0.running = false; $0.result = result }
        return result
    }

    /// Asks the model to re-read a risky action. Returns corrected arguments,
    /// or nil when it confirms the action as typed.
    private func doubleCheck(_ name: String, _ args: String, request: String, llm: LLM) async -> String? {
        let prompt = """
        Before it runs, double-check this action you are about to take on the user's Mac.
        The user asked: \(request.prefix(1500))
        Action: \(name)
        Arguments: \(args)

        Read the arguments slowly. Check spelling, paths, quoting and escaping, flags, coordinates, and that the action does what was asked and nothing more.
        If it is exactly right, reply with only: CONFIRM
        If anything should change, reply with REVISE on the first line and the corrected arguments as a JSON object on the next line.
        """
        guard let reply = try? await llm.complete([APIMessage(role: "user", content: prompt)]) else { return nil }
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.uppercased().hasPrefix("REVISE"),
              let start = r.firstIndex(of: "{"), let end = r.lastIndex(of: "}") else { return nil }
        let json = String(r[start...end])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], !obj.isEmpty,
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s == args ? nil : s
    }
}
