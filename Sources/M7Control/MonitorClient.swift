import CryptoKit
import Foundation
import M7Core

enum MonitorError: Error, Equatable {
    case unauthorized
    case server(code: Int, message: String)
    case unreachable(String)
    case malformed
    /// The device at this address presented a different certificate than the one seen at pairing.
    case certificateChanged
}

/// Accepts the monitor's self-signed certificate, but only the exact one pinned at pairing.
private final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pinnedValue: String?
    private var seenValue: String?

    var pinned: String? {
        get { lock.withLock { pinnedValue } }
        set { lock.withLock { pinnedValue = newValue } }
    }

    var seen: String? { lock.withLock { seenValue } }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let expected: String? = lock.withLock {
            seenValue = fingerprint
            return pinnedValue
        }
        if let expected, expected != fingerprint {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Runs async operations strictly one after another, in submission order.
/// The monitor's control service is fragile, so it never sees two requests at once.
private actor SerialGate {
    private var tail: Task<Void, Never>?

    func run<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// JSON-RPC client for Samsung IP Control.
final class MonitorClient: @unchecked Sendable {
    private let delegate = PinningDelegate()
    private let session: URLSession
    private let gate = SerialGate()
    private let idLock = NSLock()
    private var lastID = 0

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// SHA-256 of the certificate the token may be sent to. `nil` accepts any (used only while pairing).
    var pinnedFingerprint: String? {
        get { delegate.pinned }
        set { delegate.pinned = newValue }
    }

    /// Fingerprint presented on the most recent connection.
    var seenFingerprint: String? { delegate.seen }

    func call(
        _ method: String,
        params: [(String, JSONValue)] = [],
        host: String,
        token: String?,
        timeout: TimeInterval = 6
    ) async throws -> [String: JSONValue] {
        try await gate.run { [self] in
            try await perform(method, params: params, host: host, token: token, timeout: timeout, mayRetry: true)
        }
    }

    private func nextID() -> Int {
        idLock.withLock {
            lastID += 1
            return lastID
        }
    }

    private func perform(
        _ method: String,
        params: [(String, JSONValue)],
        host: String,
        token: String?,
        timeout: TimeInterval,
        mayRetry: Bool
    ) async throws -> [String: JSONValue] {
        guard let url = URL(string: "https://\(host):\(RPC.port)/") else {
            throw MonitorError.unreachable("invalid address")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = RPC.requestBody(id: nextID(), method: method, token: token, params: params)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled, let pinned = delegate.pinned, delegate.seen != pinned {
                throw MonitorError.certificateChanged
            }
            // A kept-alive connection the monitor already closed: one fresh attempt is safe.
            if mayRetry, error.code == .networkConnectionLost {
                return try await perform(method, params: params, host: host, token: token, timeout: timeout, mayRetry: false)
            }
            throw MonitorError.unreachable(error.localizedDescription)
        }

        switch RPC.parseReply(data) {
        case let .success(result): return result
        case .failure(.unauthorized): throw MonitorError.unauthorized
        case let .failure(.server(code, message)): throw MonitorError.server(code: code, message: message)
        case .failure(.malformed): throw MonitorError.malformed
        }
    }
}
