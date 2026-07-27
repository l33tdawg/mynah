import Foundation

/// A minimal, `Sendable` JSON tree.
///
/// The brain loop shuttles arbitrary JSON between two foreign systems — an MCP
/// server's `inputSchema` blobs on one side, Ollama's tool-call `arguments` on
/// the other — and never needs to understand their shape. `[String: Any]` would
/// do the job but is neither `Sendable` nor `Equatable`, which makes it awkward
/// to carry across `async` boundaries. This enum is the smallest thing that is.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Bridging to Foundation JSON

public extension JSONValue {
    /// Wraps the output of `JSONSerialization.jsonObject(with:)`.
    ///
    /// Returns `nil` only for values Foundation would never hand back from a
    /// JSON parse (a custom class, a non-string dictionary key, and so on).
    init?(foundationObject object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber erases Bool/Int/Double, so interrogate the ObjC type
            // encoding rather than attempting Swift casts, which happily
            // convert 1 into `true`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let intValue = Self.exactInt(number) {
                self = .int(intValue)
            } else {
                self = .double(number.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            var items: [JSONValue] = []
            items.reserveCapacity(value.count)
            for item in value {
                guard let converted = JSONValue(foundationObject: item) else {
                    return nil
                }
                items.append(converted)
            }
            self = .array(items)
        case let value as [String: Any]:
            var members: [String: JSONValue] = [:]
            members.reserveCapacity(value.count)
            for (key, item) in value {
                guard let converted = JSONValue(foundationObject: item) else {
                    return nil
                }
                members[key] = converted
            }
            self = .object(members)
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        default:
            return nil
        }
    }

    /// The value in a form `JSONSerialization` will re-encode.
    var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationObject)
        case .object(let members):
            return members.mapValues(\.foundationObject)
        }
    }

    /// Parses raw JSON text. Returns `nil` if the text is not valid JSON.
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return parse(data)
    }

    /// Parses raw JSON bytes. Returns `nil` if the bytes are not valid JSON.
    static func parse(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return nil
        }
        return JSONValue(foundationObject: object)
    }

    /// Compact JSON text for this value, or `"null"` if it cannot be encoded.
    func jsonString(prettyPrinted: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if prettyPrinted {
            options.insert(.prettyPrinted)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }

    private static func exactInt(_ number: NSNumber) -> Int? {
        switch UnicodeScalar(UInt8(number.objCType.pointee)) {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
            return number.intValue
        default:
            return nil
        }
    }
}

// MARK: - Accessors

public extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString() }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}
