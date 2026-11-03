import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // Quoder --run "task": do the task without a window, printing each step.
        if let i = CommandLine.arguments.firstIndex(of: "--run"), i + 1 < CommandLine.arguments.count {
            let prompt = CommandLine.arguments[i + 1]
            Task { @MainActor in await Headless.run(prompt); exit(0) }
            RunLoop.main.run()
        }
        QuoderApp.main()
    }
}

@MainActor
enum Headless {
    static func run(_ prompt: String) async {
        let agent = Agent()
        for _ in 0..<80 where agent.tunnel.state != .up && agent.config.useTunnel {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        print("connection: \(agent.tunnel.state)")
        agent.newChat()
        agent.send(prompt)
        var shown = Set<UUID>()
        while agent.busy {
            try? await Task.sleep(nanoseconds: 500_000_000)
            for it in agent.current?.items ?? [] where !shown.contains(it.id) && !it.running && it.check != .checking {
                if it.kind == .assistant, agent.busy, it.id == agent.current?.items.last?.id { continue }  // still streaming
                shown.insert(it.id)
                switch it.kind {
                case .user: print("USER: \(it.text)")
                case .assistant: print("QUODER: \(it.text)")
                case .tool: print("TOOL \(it.toolName) \(it.arguments) [check: \(it.check.rawValue)]\n  → \(it.result.prefix(400))")
                case .error: print("NOTE: \(it.text)")
                }
            }
        }
        for it in agent.current?.items ?? [] where !shown.contains(it.id) {
            print(it.kind == .tool ? "TOOL \(it.toolName) \(it.arguments) [check: \(it.check.rawValue)]\n  → \(it.result.prefix(400))"
                                   : "\(it.kind.rawValue.uppercased()): \(it.text)")
        }
    }
}

struct QuoderApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @StateObject private var agent = Agent()

    var body: some Scene {
        WindowGroup("Quoder") {
            RootView().environmentObject(agent).frame(minWidth: 760, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New Chat") { agent.newChat() }.keyboardShortcut("n") }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        // Close the SSH forward with the app.
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "ssh .*-L 127.0.0.1:\(Config.load().localPort):127.0.0.1"]
        try? k.run(); k.waitUntilExit()
    }
}
