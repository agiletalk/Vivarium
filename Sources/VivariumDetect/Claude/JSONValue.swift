import Foundation

/// Minimal recursive JSON tree used to decode arbitrary tool inputs and message content
/// without committing to a schema (unknown fields must never fail the whole line).
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not a valid JSON type"
            )
        }
    }
}
