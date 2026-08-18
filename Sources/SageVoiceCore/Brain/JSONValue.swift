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
            if Self.isBoolean(number) {
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
    ///
    /// **Two implementations, because `true` and `1` are the same object on one
    /// of these platforms and not the other.** On a Mac, `JSONSerialization`
    /// hands back a `CFBoolean` for `true` and an ordinary `NSNumber` for `1`,
    /// and `CFGetTypeID` tells them apart exactly. There is no `CFGetTypeID` off
    /// Darwin, and worse, no cast that answers: swift-corelibs-foundation
    /// bridges `Bool` to `NSNumber` *unconditionally in both directions*, so
    /// `true as? NSNumber` succeeds and `NSNumber(value: 5) as? Bool` also
    /// succeeds — every question you can ask a parsed value there gets a yes.
    ///
    /// So off Darwin this does not ask a parsed value anything. `JSONDecoder`
    /// keeps `true` and `1` as different tokens inside its own scanner and will
    /// only give you a `Bool` for the literal, which makes the distinction a
    /// property of the parse rather than a guess about the result.
    ///
    /// The array wrapper is what buys `.fragmentsAllowed`: a top-level `true` or
    /// `42` is not a document `JSONDecoder` is obliged to accept, and `[true]`
    /// always is. Exactly one element must come back — otherwise `1,2` would
    /// parse as a fragment, which `JSONSerialization` rejects and so must this.
    ///
    /// This matters far past a corner case: every model reply, every MCP tool
    /// result and every SAGE payload goes through here, and a `true` silently
    /// arriving as `1` is a tool argument that reads as a number to whatever it
    /// is handed to. `JSONBooleansAreNotOnesTests` pins both platforms.
    static func parse(_ data: Data) -> JSONValue? {
        #if canImport(Darwin)
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return nil
        }
        return JSONValue(foundationObject: object)
        #else
        var wrapped = Data("[".utf8)
        wrapped.append(data)
        wrapped.append(contentsOf: Data("]".utf8))
        guard let decoded = try? JSONDecoder().decode([DecodedJSONValue].self, from: wrapped),
              decoded.count == 1 else {
            return nil
        }
        return decoded[0].value
        #endif
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

    /// Whether this number is a JSON `true`/`false` rather than a JSON number.
    ///
    /// On Darwin that is a type identity and nothing else will do — a boolean
    /// from `JSONSerialization` is a `CFBoolean`, and `1` is not.
    ///
    /// Off Darwin there is no `CFGetTypeID` to ask, so this reads the type
    /// encoding, which is the one thing about a corelibs `NSNumber` that a
    /// `Bool` cannot fake: a bridged boolean reports `B` or `c`, and an integer
    /// parsed out of JSON reports `q` or `l`. It is right whether corelibs hands
    /// back a bridged `Bool` or a genuine `NSNumber`, which is why it is written
    /// this way rather than as a cast.
    ///
    /// **The one thing it cannot tell apart is a hand-made `NSNumber(value:
    /// Int8(1))`**, which reports `c` as well and would be read as `true`. No
    /// JSON parse produces one — corelibs widens every integer — and the parse
    /// path off Darwin does not come through here at all. A caller building
    /// NSNumbers by hand and expecting 8-bit integers to survive is the case to
    /// know about.
    internal static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        switch UnicodeScalar(UInt8(bitPattern: number.objCType.pointee)) {
        case "B", "c": return true
        default: return false
        }
        #endif
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

#if !canImport(Darwin)

// MARK: - Parsing where `true` and `1` are not the same object

/// A `JSONValue` in the one form a platform without `CFBoolean` can parse
/// without guessing.
///
/// **The distinction lives in the scanner, not in the result.** `JSONDecoder`'s
/// own parser holds `true` and `1` as different tokens, and `decode(Bool.self)`
/// throws a type mismatch on a number rather than helpfully converting it. So
/// asking for a `Bool` first and taking the answer is a question about what was
/// written in the document — which is the thing that was lost off Darwin, where
/// every cast on a parsed value says yes.
///
/// A private box rather than a `Decodable` conformance on `JSONValue` itself,
/// so the type's public surface is the same on every platform. A conformance
/// that exists on Linux and not on a Mac is a source file that compiles here and
/// not there, discovered by whoever ports the next thing.
private struct DecodedJSONValue: Decodable {

    let value: JSONValue

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .null
        } else if let bool = try? container.decode(Bool.self) {
            // First, and it would still be right last: a JSON number refuses to
            // decode as `Bool` here. The order says which question matters.
            value = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            value = .int(int)
        } else if let double = try? container.decode(Double.self) {
            value = .double(double)
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else if let array = try? container.decode([DecodedJSONValue].self) {
            value = .array(array.map(\.value))
        } else if let object = try? container.decode([String: DecodedJSONValue].self) {
            value = .object(object.mapValues(\.value))
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value this appliance understands"
            )
        }
    }
}

#endif
