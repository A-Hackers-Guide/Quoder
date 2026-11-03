import AppKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.16, green: 0.47, blue: 0.43)        // deep teal
    static let paper = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.11, green: 0.115, blue: 0.12, alpha: 1)
                                                            : NSColor(calibratedRed: 0.975, green: 0.972, blue: 0.962, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.17, alpha: 1)
                                                            : NSColor(calibratedWhite: 1.0, alpha: 1)
    })
    static let bubble = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.21, alpha: 1)
                                                            : NSColor(calibratedRed: 0.925, green: 0.92, blue: 0.905, alpha: 1)
    })
    static let line = Color.primary.opacity(0.09)
}

struct QMark: View {
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.accent)
            Text("Q").font(.system(size: size * 0.62, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }.frame(width: size, height: size)
    }
}

struct RootView: View {
    @EnvironmentObject var agent: Agent
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $agent.currentID) {
                ForEach(agent.chats) { c in
                    Text(c.title).lineLimit(1).tag(c.id)
                        .contextMenu { Button("Delete", role: .destructive) { agent.delete(c.id) } }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar { ToolbarItem { Button { agent.newChat() } label: { Label("New chat", systemImage: "square.and.pencil") } } }
        } detail: {
            ChatView()
                .toolbar {
                    ToolbarItem(placement: .navigation) { HStack(spacing: 8) { QMark(); Text("Quoder").font(.headline) } }
                    ToolbarItem { StatusPill() }
                    ToolbarItem { Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") } }
                }
        }
        .sheet(isPresented: $showSettings) { SettingsView(config: agent.config).environmentObject(agent) }
    }
}

struct StatusPill: View {
    @EnvironmentObject var agent: Agent
    var body: some View { Inner(tunnel: agent.tunnel) }

    struct Inner: View {
        @ObservedObject var tunnel: Tunnel
        @EnvironmentObject var agent: Agent
        var body: some View {
            let (color, text): (Color, String) = {
                if !agent.config.useTunnel { return (.blue, "Direct") }
                switch tunnel.state {
                case .up: return (.green, "Connected")
                case .connecting: return (.orange, "Connecting…")
                case .off: return (.gray, "Off")
                case .failed: return (.red, "Can't reach the PC")
                }
            }()
            HStack(spacing: 6) { Circle().fill(color).frame(width: 8, height: 8); Text(text).font(.caption) }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Theme.bubble))
                .help({ if case let .failed(m) = tunnel.state { return m }; return "Model: \(agent.config.model)" }())
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var agent: Agent
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if agent.current?.items.isEmpty ?? true { Welcome() }
                        ForEach(agent.current?.items ?? []) { item in ItemView(item: item).id(item.id) }
                        if agent.busy { ThinkingDots().id("dots") }
                    }
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
                    .padding(.horizontal, 28).padding(.vertical, 24)
                }
                .onChange(of: agent.current?.items) { _ in
                    withAnimation {
                        if agent.busy { proxy.scrollTo("dots", anchor: .bottom) }
                        else if let last = agent.current?.items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            Composer(draft: $draft)
        }
        .background(Theme.paper)
    }
}

struct Welcome: View {
    var body: some View {
        VStack(spacing: 14) {
            QMark(size: 54)
            Text("What should we work on?").font(.system(size: 26, weight: .semibold, design: .serif))
            Text("Quoder runs a model on your own computers and can use this Mac: the terminal, your files and the screen.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            PermissionRow()
        }
        .frame(maxWidth: .infinity).padding(.top, 90)
    }
}

struct PermissionRow: View {
    @State private var tick = 0
    var body: some View {
        HStack(spacing: 10) {
            perm("Accessibility", Screen.canControl, "click and type") { Screen.askToControl() }
            perm("Screen Recording", Screen.canSee, "read the screen") { Screen.askToSee() }
        }
        .id(tick)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
    }
    func perm(_ name: String, _ ok: Bool, _ why: String, _ ask: @escaping () -> Void) -> some View {
        Button(action: ask) {
            Label(ok ? "\(name) on" : "Allow \(name)", systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
        }
        .buttonStyle(.bordered).tint(ok ? .green : .orange).disabled(ok)
        .help(ok ? "Quoder can \(why)." : "Needed so Quoder can \(why).")
    }
}

struct ThinkingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Theme.accent).frame(width: 7, height: 7).opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: on)
            }
        }.onAppear { on = true }
    }
}

struct ItemView: View {
    let item: Item
    var body: some View {
        switch item.kind {
        case .user:
            HStack { Spacer(minLength: 80)
                Text(item.text).textSelection(.enabled).font(.body).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bubble))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                QMark(size: 24).padding(.top, 1)
                Markdown(text: item.text)
            }
        case .tool: ToolCard(item: item)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        }
    }
}

struct Markdown: View {
    let text: String
    var body: some View {
        let parts = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i % 2 == 1 {
                    let code = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let body = code.count > 1 ? String(code[1]) : String(part)
                    ScrollView(.horizontal) {
                        Text(body.trimmingCharacters(in: .newlines)).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(12)
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
                    .foregroundStyle(Color(white: 0.92))
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text((try? AttributedString(markdown: part.trimmingCharacters(in: .newlines),
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(part))
                        .font(.system(size: 14.5)).lineSpacing(3).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolCard: View {
    let item: Item
    @State private var open = false
    var icon: String {
        switch item.toolName {
        case "run_command": return "terminal"
        case "read_file", "list_directory": return "doc.text.magnifyingglass"
        case "write_file", "edit_file": return "square.and.pencil"
        case "screen_text", "ui_elements": return "eye"
        case "click": return "cursorarrow.click"
        case "type_text", "press_keys": return "keyboard"
        case "open": return "arrow.up.forward.app"
        default: return "wrench.and.screwdriver"
        }
    }
    var summary: String {
        let a = (try? JSONSerialization.jsonObject(with: Data(item.arguments.utf8))) as? [String: Any] ?? [:]
        for k in ["command", "path", "target", "text", "keys"] { if let v = a[k] as? String { return v } }
        if let x = a["x"], let y = a["y"] { return "\(x), \(y)" }
        return ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 18)
                    Text(item.toolName.replacingOccurrences(of: "_", with: " ")).font(.callout.weight(.medium))
                    Text(summary).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    switch item.check {
                    case .checking: Label("double-checking", systemImage: "magnifyingglass").font(.caption).foregroundStyle(.orange)
                    case .confirmed: Label("checked", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
                    case .corrected: Label("corrected", systemImage: "wand.and.stars").font(.caption).foregroundStyle(.blue)
                    case .none: EmptyView()
                    }
                    if item.running { ProgressView().controlSize(.small) }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if !item.result.isEmpty {
                        ScrollView { Text(item.result).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
                    }
                }.padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.line))
    }
}

struct Composer: View {
    @EnvironmentObject var agent: Agent
    @Binding var draft: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask Quoder to do something…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14.5)).lineLimit(1...10)
                    .focused($focused)
                    .onSubmit(send)
                if agent.busy {
                    Button(action: agent.stop) { Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold)) }
                        .buttonStyle(Round(color: .red)).help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)) }
                        .buttonStyle(Round(color: Theme.accent)).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
            Text(agent.config.selfCheck ? "Quoder double-checks risky actions before running them." : "Self-check is off: actions run as typed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
        .padding(.horizontal, 28).padding(.bottom, 16).padding(.top, 6)
        .onAppear { focused = true }
    }

    func send() {
        guard !agent.busy else { return }
        agent.send(draft); draft = ""
    }
}

struct Round: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white).frame(width: 30, height: 30)
            .background(Circle().fill(color.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

struct SettingsView: View {
    @EnvironmentObject var agent: Agent
    @Environment(\.dismiss) var dismiss
    @State var config: Config

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.weight(.semibold))
            Form {
                Section("Model server") {
                    Toggle("Connect through SSH to the PC", isOn: $config.useTunnel)
                    if config.useTunnel {
                        TextField("SSH address (user@host)", text: $config.sshTarget)
                        TextField("Server port on the PC", value: $config.remotePort, format: .number.grouping(.never))
                    } else {
                        TextField("Server address (e.g. a Cloudflare Tunnel URL)", text: $config.directURL)
                    }
                    SecureField("API key", text: $config.apiKey)
                    TextField("Model name", text: $config.model)
                }
                Section("Actions") {
                    Toggle("Double-check risky actions before running them", isOn: $config.selfCheck)
                    Text("Commands that could erase the Mac always ask you first.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Permissions") { PermissionRow() }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Cancel") { dismiss() }
                Button("Save") { agent.applyConfig(config); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 520, height: 560)
    }
}
