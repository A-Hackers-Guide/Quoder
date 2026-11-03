import AppKit
import Foundation

struct ToolError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// What the model can do on this Mac.
enum Tools {
    static let definitions: [[String: Any]] = [
        fn("run_command", "Run a shell command in zsh on this Mac and get its output. Use for anything a terminal can do.",
           ["command": str("The command line"), "cwd": str("Folder to run in (default: home)"),
            "timeout": int("Seconds before it's stopped (default 120, max 900)")], ["command"]),
        fn("read_file", "Read a text file.",
           ["path": str("Path (~ allowed)"), "offset": int("First line, from 1"), "limit": int("Number of lines")], ["path"]),
        fn("write_file", "Create or overwrite a file with the given content. Creates missing folders.",
           ["path": str("Path (~ allowed)"), "content": str("The whole new content")], ["path", "content"]),
        fn("edit_file", "Replace one exact piece of text in a file with another. old_text must appear exactly once.",
           ["path": str("Path"), "old_text": str("Exact text to replace"), "new_text": str("Replacement")],
           ["path", "old_text", "new_text"]),
        fn("list_directory", "List a folder's files and subfolders with sizes.", ["path": str("Folder (~ allowed)")], ["path"]),
        fn("screen_text", "Read all text visible on the screen, with the x,y position of each piece. Use before clicking.", [:], []),
        fn("ui_elements", "List the buttons, fields, menus and other controls of the frontmost app with their x,y positions.", [:], []),
        fn("click", "Click at screen coordinates (points, from the top left).",
           ["x": num("X"), "y": num("Y"), "button": str("left (default) or right"), "count": int("1 = click, 2 = double-click")],
           ["x", "y"]),
        fn("type_text", "Type text into whatever has keyboard focus.", ["text": str("Text to type")], ["text"]),
        fn("press_keys", "Press a key or shortcut, e.g. \"return\", \"cmd+s\", \"cmd+shift+t\", \"esc\", \"tab\", \"down\".",
           ["keys": str("The key combination")], ["keys"]),
        fn("scroll", "Scroll where the mouse is. Positive scrolls down.", ["amount": int("Lines, e.g. 5 or -5")], ["amount"]),
        fn("open", "Open an app by name, a file, a folder or a URL.", ["target": str("e.g. Safari, ~/Documents, https://example.com")], ["target"]),
        fn("wait", "Wait a moment, e.g. for an app to open.", ["seconds": num("Seconds (max 30)")], ["seconds"]),
    ]

    static let names: Set<String> = Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })

    private static func fn(_ name: String, _ desc: String, _ props: [String: [String: Any]], _ req: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": desc,
                                          "parameters": ["type": "object", "properties": props, "required": req]]]
    }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }

    // MARK: risk

    /// Commands that only look at things don't need a double-check.
    private static let readOnly: Set<String> = ["ls", "pwd", "cat", "head", "tail", "wc", "echo", "which", "whoami", "date",
                                                "df", "du", "file", "stat", "grep", "rg", "find", "ps", "top", "uname",
                                                "sw_vers", "env", "printenv", "tree", "less", "git"]

    /// Actions that change something get the model's second look first.
    static func isRisky(_ name: String, _ args: [String: Any]) -> Bool {
        switch name {
        case "write_file", "edit_file", "click", "type_text", "press_keys", "open": return true
        case "run_command":
            let cmd = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if cmd.contains(">") || cmd.contains("|") && cmd.contains("sh") || cmd.contains(";") || cmd.contains("&&") { return true }
            let first = cmd.split(separator: " ").first.map(String.init) ?? ""
            if first == "git" {
                let sub = cmd.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                return !["status", "log", "diff", "show", "branch", "remote"].contains(sub)
            }
            return !readOnly.contains(first)
        default: return false
        }
    }

    /// The few commands that can wreck a Mac in one go. These always ask you,
    /// whatever the model decided.
    static func catastrophic(_ name: String, _ args: [String: Any]) -> String? {
        guard name == "run_command", let cmd = args["command"] as? String else { return nil }
        let c = cmd.replacingOccurrences(of: "  ", with: " ")
        let patterns = [
            #"rm\s+(-[a-zA-Z]*[rRf][a-zA-Z]*\s+)+(/|~|\$HOME|/Users|/System|/Applications|/Library)(\s|/?\*?$|/?$)"#,
            #"diskutil\s+(erase|zero|secureErase|partitionDisk|apfs\s+delete)"#,
            #"\bmkfs\b"#, #"\bdd\b.*\bof=/dev/"#, #":\(\)\s*\{\s*:\|:&\s*\};:"#,
            #"csrutil\s+disable"#, #"\bnvram\b.*-c"#, #"chmod\s+-R\s+[0-7]{3,4}\s+/(\s|$)"#,
        ]
        for p in patterns where c.range(of: p, options: .regularExpression) != nil {
            return "This command could erase or break the whole Mac:\n\n\(cmd)"
        }
        return nil
    }

    // MARK: running

    static func run(_ name: String, _ args: [String: Any]) async -> String {
        do { return try await perform(name, args) } catch { return "Error: \(error.localizedDescription)" }
    }

    private static func path(_ a: [String: Any], _ key: String = "path") throws -> String {
        guard let p = a[key] as? String, !p.isEmpty else { throw ToolError("Missing \(key)") }
        return (p as NSString).expandingTildeInPath
    }

    private static func perform(_ name: String, _ a: [String: Any]) async throws -> String {
        switch name {
        case "run_command":
            guard let cmd = a["command"] as? String else { throw ToolError("Missing command") }
            let cwd = (a["cwd"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
            let timeout = min(max((a["timeout"] as? Int) ?? 120, 1), 900)
            return try await shell(cmd, cwd: cwd, timeout: timeout)
        case "read_file":
            let p = try path(a)
            guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { throw ToolError("Can't read \(p) as text") }
            var lines = s.components(separatedBy: "\n")
            let off = max((a["offset"] as? Int) ?? 1, 1) - 1
            let lim = (a["limit"] as? Int) ?? 2000
            lines = Array(lines.dropFirst(off).prefix(lim))
            var out = lines.enumerated().map { "\($0.offset + off + 1)\t\($0.element)" }.joined(separator: "\n")
            if out.count > 60_000 { out = String(out.prefix(60_000)) + "\n… (truncated; use offset/limit)" }
            return out.isEmpty ? "(empty file)" : out
        case "write_file":
            let p = try path(a)
            let content = a["content"] as? String ?? ""
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: p, atomically: true, encoding: .utf8)
            return "Wrote \(content.utf8.count) bytes to \(p)"
        case "edit_file":
            let p = try path(a)
            guard let old = a["old_text"] as? String, let new = a["new_text"] as? String else { throw ToolError("Missing old_text/new_text") }
            var s = try String(contentsOfFile: p, encoding: .utf8)
            let n = s.components(separatedBy: old).count - 1
            guard n == 1 else { throw ToolError(n == 0 ? "old_text not found in \(p)" : "old_text appears \(n) times; make it unique") }
            s = s.replacingOccurrences(of: old, with: new)
            try s.write(toFile: p, atomically: true, encoding: .utf8)
            return "Edited \(p)"
        case "list_directory":
            let p = try path(a)
            let items = try FileManager.default.contentsOfDirectory(atPath: p).sorted()
            var out = "\(p):\n"
            for i in items.prefix(500) {
                var dir: ObjCBool = false
                FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(i), isDirectory: &dir)
                let size = (try? FileManager.default.attributesOfItem(atPath: (p as NSString).appendingPathComponent(i))[.size] as? Int) ?? 0
                out += dir.boolValue ? "\(i)/\n" : "\(i)  (\(size) bytes)\n"
            }
            if items.count > 500 { out += "… and \(items.count - 500) more\n" }
            return out
        case "screen_text": return try await Screen.text()
        case "ui_elements": return try await MainActor.run { try Screen.elements() }
        case "click":
            guard let x = (a["x"] as? NSNumber)?.doubleValue, let y = (a["y"] as? NSNumber)?.doubleValue else { throw ToolError("Missing x/y") }
            try Screen.click(x: x, y: y, button: a["button"] as? String ?? "left", count: (a["count"] as? Int) ?? 1)
            return "Clicked at \(Int(x)),\(Int(y))"
        case "type_text":
            guard let t = a["text"] as? String else { throw ToolError("Missing text") }
            try Screen.type(t); return "Typed \(t.count) characters"
        case "press_keys":
            guard let k = a["keys"] as? String else { throw ToolError("Missing keys") }
            try Screen.press(k); return "Pressed \(k)"
        case "scroll":
            try Screen.scroll(dy: (a["amount"] as? Int) ?? 3); return "Scrolled"
        case "open":
            guard let t = a["target"] as? String else { throw ToolError("Missing target") }
            let expanded = (t as NSString).expandingTildeInPath
            let args = t.contains("://") || FileManager.default.fileExists(atPath: expanded) ? [expanded.contains("://") ? t : expanded] : ["-a", t]
            return try await shell("open " + args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " "),
                                   cwd: NSHomeDirectory(), timeout: 30)
        case "wait":
            let s = min(max((a["seconds"] as? NSNumber)?.doubleValue ?? 1, 0), 30)
            try await Task.sleep(nanoseconds: UInt64(s * 1e9)); return "Waited \(s)s"
        default: throw ToolError("No tool named \(name)")
        }
    }

    static func shell(_ cmd: String, cwd: String, timeout: Int) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            let buf = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { h in buf.append(h.availableData) }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                buf.append(pipe.fileHandleForReading.readDataToEndOfFile())
                var out = buf.text
                if out.count > 8_000 { out = String(out.prefix(4_000)) + "\n… (\(out.count - 8_000) characters cut) …\n" + String(out.suffix(4_000)) }
                let status = proc.terminationReason == .uncaughtSignal ? "stopped (timed out or killed)" : "exit code \(proc.terminationStatus)"
                cont.resume(returning: (out.isEmpty ? "(no output)" : out) + "\n[\(status)]")
            }
            do { try p.run() } catch { cont.resume(throwing: error); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) { if p.isRunning { p.terminate() } }
        }
    }
}

final class OutputBuffer: @unchecked Sendable {
    private var data = Data(); private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
