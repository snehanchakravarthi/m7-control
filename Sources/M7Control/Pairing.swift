import Foundation
import Network

/// What the app needs to talk to the monitor again after pairing.
struct Pairing: Codable, Equatable {
    /// Last address the monitor answered on. `nil` until it has been located on the network.
    var host: String?
    var token: String
    /// SHA-256 of the monitor's certificate, recorded when the token was issued.
    var fingerprint: String
}

enum PairingStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("M7 Control", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("pairing.json") }

    /// Pairing made by `tools/ipcontrol_probe.py`, adopted so the monitor need not be paired twice.
    private static var legacyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/m7ctl/ipcontrol.json")
    }

    static func load() -> Pairing? {
        if let data = try? Data(contentsOf: file), let pairing = try? JSONDecoder().decode(Pairing.self, from: data) {
            return pairing
        }
        if let data = try? Data(contentsOf: legacyFile), let pairing = try? JSONDecoder().decode(Pairing.self, from: data) {
            try? save(pairing)
            return pairing
        }
        return nil
    }

    /// Written owner-only. The token is kept in a file, not the Keychain, because the app is ad-hoc
    /// signed and the Keychain would ask for the login password again after every rebuild.
    static func save(_ pairing: Pairing) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pairing)
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Finds Samsung smart displays on the local network through Bonjour.
enum Discovery {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String] = []

        func add(_ host: String) {
            lock.withLock { if !hosts.contains(host) { hosts.append(host) } }
        }

        var all: [String] { lock.withLock { hosts } }
    }

    /// Returns the addresses of Samsung displays that announce themselves within `timeout`.
    static func hosts(timeout: TimeInterval = 2.5) async -> [String] {
        await withCheckedContinuation { continuation in
            let collector = Collector()
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_samsungmsf._tcp", domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    // The TXT record carries the device's own service URL, e.g. se=http://192.168.1.20:8001/api/v2/
                    guard case let .bonjour(record) = result.metadata,
                          let service = record["se"],
                          let host = URL(string: service)?.host
                    else { continue }
                    collector.add(host)
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                continuation.resume(returning: collector.all)
            }
        }
    }
}
