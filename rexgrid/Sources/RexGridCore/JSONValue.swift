import Foundation

/// Loosely typed JSON, for reading Rex's replies and events.
///
/// Rex adds fields and event types between versions and asks clients to
/// ignore what they don't recognize. Reading by key, with every miss turning
/// into `.null`, does that without a struct per message.
public enum JSONValue: Decodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let fields) = self { return fields[key] ?? .null }
        return .null
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var array: [JSONValue] {
        if case .array(let values) = self { return values }
        return []
    }

    public var isNull: Bool { self == .null }
}
