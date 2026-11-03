import Foundation

/// Keeps an SSH port forward to the model server open, restarting it when it
/// drops. Uses this Mac's existing SSH key, so nothing on the network can reach
/// the model without it.
@MainActor
final class Tunnel: ObservableObject {
    enum State: Equatable { case off, connecting, up, failed(String) }
    @Published private(set) var state: State = .off

    private var process: Process?
    private var wanted = false
    private var config = Config()

    func start(_ c: Config) {
        config = c
        wanted = c.useTunnel
        stopProcess()
        guard wanted else { state = .off; return }
        guard !c.sshTarget.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .failed("Set the model server's SSH address in Settings (user@host)."); return
        }
        launch()
    }

    func stop() { wanted = false; stopProcess(); state = .off }

    private func stopProcess() {
        if let p = process, p.isRunning { p.terminationHandler = nil; p.terminate() }
        process = nil
    }

    private func launch() {
        state = .connecting
        // A forward left over from an earlier run would hold the port.
        let forward = "127.0.0.1:\(config.localPort):127.0.0.1:\(config.remotePort)"
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "ssh .*-L \(forward)"]
        try? kill.run(); kill.waitUntilExit()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                       "-o", "ConnectTimeout=10",
                       "-L", "127.0.0.1:\(config.localPort):127.0.0.1:\(config.remotePort)", config.sshTarget]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                guard let self, self.wanted else { return }
                self.state = .failed(msg.isEmpty ? "SSH exited (\(proc.terminationStatus))" : msg)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.wanted { self.launch() }
            }
        }
        do {
            try p.run()
            process = p
            Task { [weak self] in
                // The forward is ready once the local port accepts connections.
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, self.process === p, p.isRunning else { return }
                    if await Tunnel.portOpen(self.config.localPort) { self.state = .up; return }
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    nonisolated static func portOpen(_ port: Int) async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse) != nil
    }
}
