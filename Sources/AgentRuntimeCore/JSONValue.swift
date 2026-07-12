import Foundation

/// A Sendable, Codable JSON tree used at provider and tool boundaries.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case decimal(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = Self.exactInteger(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = Self.exactUnsignedInteger(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = Self.exactDecimal(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .unsignedInteger(let value):
            try container.encode(value)
        case .decimal(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw JSONValueError.invalidUTF8
        }
        return try parse(data)
    }

    public func encodedData(sortedKeys: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if sortedKeys { encoder.outputFormatting = [.sortedKeys] }
        return try encoder.encode(self)
    }

    public func encodedString(sortedKeys: Bool = true) throws -> String {
        let data = try encodedData(sortedKeys: sortedKeys)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONValueError.invalidUTF8
        }
        return string
    }

    private static let maximumExactlyRepresentableInteger = Int64(9_007_199_254_740_991)

    private static func exactInteger(_ value: Int64) -> JSONValue {
        if value >= -maximumExactlyRepresentableInteger,
           value <= maximumExactlyRepresentableInteger {
            return .number(Double(value))
        }
        return .integer(value)
    }

    private static func exactUnsignedInteger(_ value: UInt64) -> JSONValue {
        if value <= UInt64(maximumExactlyRepresentableInteger) {
            return .number(Double(value))
        }
        return .unsignedInteger(value)
    }

    private static func exactDecimal(_ value: Decimal) -> JSONValue {
        let double = NSDecimalNumber(decimal: value).doubleValue
        if double.isFinite,
           let roundTrip = Decimal(
               string: String(double),
               locale: Locale(identifier: "en_US_POSIX")
           ),
           roundTrip == value {
            return .number(double)
        }
        return .decimal(value)
    }
}

public enum JSONValueError: Error, Sendable {
    case invalidUTF8
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = Self.exactInteger(Int64(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
