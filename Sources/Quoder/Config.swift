import Foundation

/// Settings, kept in ~/Library/Application Support/Quoder/config.json
/// (readable only by you).
struct Config: Codable, Equatable {
    /// SSH target of the computer that runs the model (user@host); the app
    /// forwards a local port to the model server through it. Set in Settings.
    var sshTarget = ""
    var remotePort = 8080
    var localPort = 18080
    var useTunnel = true
    /// Used instead of the tunnel when useTunnel is off, e.g. a Cloudflare
    /// Tunnel address.
    var directURL = ""
    var apiKey = ""
    var model = "qwen2.5-coder-abliterate-32b"
    /// The model double-checks risky actions before they run.
    var selfCheck = true

    var baseURL: URL {
        if useTunnel { return URL(string: "http://127.0.0.1:\(localPort)")! }
        return URL(string: directURL.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://127.0.0.1:\(localPort)")!
    }

    static var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quoder", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var file: URL { folder.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let d = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
        return c
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(self) else { return }
        try? d.write(to: Config.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.file.path)
    }
}
