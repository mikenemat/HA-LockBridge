import Foundation

/// On-disk config. Backward-compat shape:
/// - v0 (legacy): `{ "host", "port", "bearer_token" }`
/// - v1 (current): `{ "instance_id", "host", "port", "paired_clients": {token: {...}} }`
/// Old v0 files are auto-migrated on load.
struct Config: Codable {
    var instance_id: String
    var host: String
    var port: Int
    var paired_clients: [String: PairedClient]

    static let defaultHost = "0.0.0.0"
    static let defaultPort = 8765

    struct PairedClient: Codable {
        var client_name: String
        var paired_at: String
    }

    enum CodingKeys: String, CodingKey {
        case instance_id, host, port, paired_clients
        case bearer_token  // legacy
    }

    init(instance_id: String, host: String, port: Int, paired_clients: [String: PairedClient]) {
        self.instance_id = instance_id
        self.host = host
        self.port = port
        self.paired_clients = paired_clients
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = (try? container.decode(String.self, forKey: .host)) ?? Self.defaultHost
        port = (try? container.decode(Int.self, forKey: .port)) ?? Self.defaultPort
        instance_id = (try? container.decode(String.self, forKey: .instance_id)) ?? UUID().uuidString

        if let clients = try? container.decode([String: PairedClient].self, forKey: .paired_clients), !clients.isEmpty {
            paired_clients = clients
        } else if let legacy = try? container.decode(String.self, forKey: .bearer_token) {
            paired_clients = [
                legacy: PairedClient(client_name: "legacy-migrated", paired_at: Self.now())
            ]
        } else {
            paired_clients = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instance_id, forKey: .instance_id)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(paired_clients, forKey: .paired_clients)
        // never re-encode `bearer_token` — it's a decode-only legacy key
    }

    // MARK: - Load / save

    static func load() throws -> (config: Config, path: URL, wasMigrated: Bool, wasGenerated: Bool) {
        let path = Self.path()
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            // Detect migration: if file on disk used legacy shape, decoded.paired_clients
            // will contain a "legacy-migrated" entry. Easier check: re-encode and compare keys.
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let wasMigrated = raw["bearer_token"] != nil && raw["paired_clients"] == nil
            if wasMigrated {
                try Self.save(decoded, to: path)
            }
            return (decoded, path, wasMigrated, false)
        }

        let generated = Config(
            instance_id: UUID().uuidString,
            host: defaultHost,
            port: defaultPort,
            paired_clients: [:]
        )
        try Self.save(generated, to: path)
        return (generated, path, false, true)
    }

    static func save(_ config: Config, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: path, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }

    static func path() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("HALockBridge").appendingPathComponent("config.json")
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

/// Thread-safe wrapper around Config. Tokens are mutated from the main thread
/// (PairingManager) and read from NIO event-loop threads (WS upgrade auth +
/// HTTP request auth). Without locking, the WS upgrade auth check immediately
/// after pairing can see a stale `paired_clients` dict and reject HA's first
/// connection attempt with 404 — Swift dictionaries are copy-on-write, not
/// safe across threads.
///
/// `instance_id`, `host`, and `port` are set at init and never mutate, so
/// they can be read without the lock.
final class TokenStore {
    private let lock = NSLock()
    private var _config: Config
    private let path: URL

    init(config: Config, path: URL) {
        self._config = config
        self.path = path
    }

    func isTokenValid(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _config.paired_clients[token] != nil
    }

    func addToken(_ token: String, clientName: String) {
        lock.lock()
        _config.paired_clients[token] = Config.PairedClient(
            client_name: clientName,
            paired_at: Self.now()
        )
        let snapshot = _config
        lock.unlock()
        persist(snapshot)
    }

    func removeToken(_ token: String) {
        lock.lock()
        _config.paired_clients.removeValue(forKey: token)
        let snapshot = _config
        lock.unlock()
        persist(snapshot)
    }

    /// Snapshot read for callers that want the whole config (e.g. for logging).
    func snapshotConfig() -> Config {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    var instanceID: String { _config.instance_id }
    var port: Int { _config.port }
    var host: String { _config.host }

    private func persist(_ snapshot: Config) {
        do {
            try Config.save(snapshot, to: path)
        } catch {
            FileHandle.standardError.write(Data("[lockbridge-server] failed to persist config: \(error)\n".utf8))
        }
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
