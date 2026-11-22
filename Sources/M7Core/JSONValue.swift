import Foundation

/// A small, sendable JSON tree. Used instead of `[String: Any]` so replies can cross actors.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(any value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let exact = Int(exactly: number.doubleValue) {
                self = .int(exact)
            } else {
                self = .double(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JSONValue(any: value)
    }

    public var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value): return Int(exactly: value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Compact JSON text. Object keys are sorted so output is deterministic.
    public var serialized: String {
        switch self {
        case let .string(value): return JSONValue.quote(value)
        case let .int(value): return String(value)
        case let .double(value): return String(value)
        case let .bool(value): return value ? "true" : "false"
        case .null: return "null"
        case let .array(values): return "[" + values.map(\.serialized).joined(separator: ",") + "]"
        case let .object(values):
            let body = values.keys.sorted().map { "\(JSONValue.quote($0)):\(values[$0]!.serialized)" }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
