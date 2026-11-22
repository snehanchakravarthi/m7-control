import Foundation

/// Samsung IP Control speaks JSON-RPC 2.0 over HTTPS on port 1516.
/// The access token travels inside `params`, not in a header.
public enum RPC {
    public static let port = 1516

    public enum Failure: Error, Equatable {
        /// The monitor rejected the token, or pairing was declined.
        case unauthorized
        case server(code: Int, message: String)
        case malformed
    }

    /// Builds a request body with a fixed key order (jsonrpc, id, method, params).
    /// The monitor's parser is fragile, so the order other working clients use is kept.
    public static func requestBody(
        id: Int,
        method: String,
        token: String?,
        params: [(String, JSONValue)] = []
    ) -> Data {
        var pairs: [(String, JSONValue)] = []
        if let token { pairs.append(("AccessToken", .string(token))) }
        pairs.append(contentsOf: params)

        var json = "{\"jsonrpc\":\"2.0\",\"id\":\(JSONValue.quote(String(id))),\"method\":\(JSONValue.quote(method))"
        if !pairs.isEmpty {
            let body = pairs.map { "\(JSONValue.quote($0.0)):\($0.1.serialized)" }.joined(separator: ",")
            json += ",\"params\":{\(body)}"
        }
        json += "}"
        return Data(json.utf8)
    }

    /// Reads a reply. Success is `{"result": {...}}`.
    /// Errors come either wrapped in `"error"` or, on current firmware, as a flat `{"code", "message"}`.
    public static func parseReply(_ data: Data) -> Result<[String: JSONValue], Failure> {
        guard let root = JSONValue.parse(data)?.objectValue else { return .failure(.malformed) }
        if let result = root["result"]?.objectValue { return .success(result) }

        let error = root["error"]?.objectValue ?? root
        guard let code = error["code"]?.intValue else { return .failure(.malformed) }
        let message = error["message"]?.stringValue ?? ""
        // -32700 "Parse error" is what the monitor answers for a missing or stale token;
        // -32010 is a declined or timed-out pairing prompt.
        if code == -32700 || code == -32010 { return .failure(.unauthorized) }
        return .failure(.server(code: code, message: message))
    }
}
