import Foundation

public struct JSONSchemaViolation: Sendable, Hashable, Error, CustomStringConvertible {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

/// A deliberately bounded JSON Schema validator for native tool boundaries.
///
/// The accepted subset is validated before values are evaluated. Unknown or
/// malformed validation keywords therefore fail closed instead of becoming a
/// silently ignored constraint supplied by an MCP server or host application.
public enum JSONSchemaValidator {
    private static let supportedKeywords: Set<String> = [
        "type", "enum", "const", "allOf", "anyOf", "oneOf",
        "properties", "required", "additionalProperties", "minProperties", "maxProperties",
        "items", "minItems", "maxItems", "uniqueItems",
        "minLength", "maxLength", "pattern",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
    ]

    // Annotation keywords do not alter validation and are safe to preserve in
    // schemas sent to model providers.
    private static let annotationKeywords: Set<String> = [
        "$schema", "$id", "$comment", "title", "description", "default",
        "examples", "deprecated", "readOnly", "writeOnly",
    ]

    private static let supportedTypes: Set<String> = [
        "null", "boolean", "number", "integer", "string", "array", "object",
    ]

    /// Validates both the schema and the value. Schema validation is performed
    /// on every direct call so callers cannot accidentally bypass fail-closed
    /// registration checks.
    public static func validate(_ value: JSONValue, against schema: JSONValue) throws {
        try validateSchema(schema)
        try validateValue(value, schema: schema, path: "$")
    }

    /// Validates that a schema uses only the supported, enforceable subset.
    public static func validateSchema(_ schema: JSONValue) throws {
        try validateSchema(schema, path: "$")
    }

    private static func validateSchema(_ schema: JSONValue, path: String) throws {
        if case .bool = schema { return }
        guard case .object(let definition) = schema else {
            throw JSONSchemaViolation(path: path, message: "schema must be an object or boolean")
        }

        for keyword in definition.keys.sorted() {
            guard supportedKeywords.contains(keyword)
                    || annotationKeywords.contains(keyword)
                    || keyword.hasPrefix("x-") else {
                throw JSONSchemaViolation(
                    path: "\(path).\(keyword)",
                    message: "unsupported JSON Schema keyword"
                )
            }
        }

        if let rawType = definition["type"] {
            guard case .string(let type) = rawType else {
                if case .array = rawType {
                    throw JSONSchemaViolation(
                        path: "\(path).type",
                        message: "type arrays are unsupported; use anyOf for nullable or union values"
                    )
                }
                throw JSONSchemaViolation(path: "\(path).type", message: "type must be a string")
            }
            guard supportedTypes.contains(type) else {
                throw JSONSchemaViolation(path: "\(path).type", message: "unknown type '\(type)'")
            }
        }

        if let enumValue = definition["enum"] {
            guard case .array(let values) = enumValue, !values.isEmpty else {
                throw JSONSchemaViolation(path: "\(path).enum", message: "enum must be a non-empty array")
            }
            guard Set(values).count == values.count else {
                throw JSONSchemaViolation(path: "\(path).enum", message: "enum values must be unique")
            }
        }

        for keyword in ["allOf", "anyOf", "oneOf"] {
            guard let rawSchemas = definition[keyword] else { continue }
            guard case .array(let schemas) = rawSchemas, !schemas.isEmpty else {
                throw JSONSchemaViolation(
                    path: "\(path).\(keyword)",
                    message: "\(keyword) must be a non-empty schema array"
                )
            }
            for (index, child) in schemas.enumerated() {
                try validateSchema(child, path: "\(path).\(keyword)[\(index)]")
            }
        }

        if let rawProperties = definition["properties"] {
            guard case .object(let properties) = rawProperties else {
                throw JSONSchemaViolation(
                    path: "\(path).properties",
                    message: "properties must be an object"
                )
            }
            for (name, child) in properties {
                try validateSchema(child, path: "\(path).properties.\(name)")
            }
        }

        if let rawRequired = definition["required"] {
            guard case .array(let values) = rawRequired,
                  values.allSatisfy({ $0.stringValue != nil }) else {
                throw JSONSchemaViolation(
                    path: "\(path).required",
                    message: "required must be an array of property names"
                )
            }
            let names = values.compactMap(\.stringValue)
            guard Set(names).count == names.count else {
                throw JSONSchemaViolation(
                    path: "\(path).required",
                    message: "required property names must be unique"
                )
            }
        }

        if let additional = definition["additionalProperties"] {
            switch additional {
            case .bool:
                break
            case .object:
                try validateSchema(additional, path: "\(path).additionalProperties")
            default:
                throw JSONSchemaViolation(
                    path: "\(path).additionalProperties",
                    message: "additionalProperties must be a boolean or schema"
                )
            }
        }

        if let items = definition["items"] {
            if case .array = items {
                throw JSONSchemaViolation(
                    path: "\(path).items",
                    message: "tuple-style items arrays are unsupported"
                )
            }
            try validateSchema(items, path: "\(path).items")
        }

        try validateNonNegativeIntegerKeyword("minProperties", in: definition, path: path)
        try validateNonNegativeIntegerKeyword("maxProperties", in: definition, path: path)
        try validateNonNegativeIntegerKeyword("minItems", in: definition, path: path)
        try validateNonNegativeIntegerKeyword("maxItems", in: definition, path: path)
        try validateNonNegativeIntegerKeyword("minLength", in: definition, path: path)
        try validateNonNegativeIntegerKeyword("maxLength", in: definition, path: path)

        if let uniqueItems = definition["uniqueItems"], uniqueItems.boolValue == nil {
            throw JSONSchemaViolation(
                path: "\(path).uniqueItems",
                message: "uniqueItems must be a boolean"
            )
        }

        if let pattern = definition["pattern"] {
            guard case .string(let expression) = pattern else {
                throw JSONSchemaViolation(path: "\(path).pattern", message: "pattern must be a string")
            }
            do {
                _ = try NSRegularExpression(pattern: expression)
            } catch {
                throw JSONSchemaViolation(path: "\(path).pattern", message: "pattern is not a valid regular expression")
            }
        }

        for keyword in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
            guard let bound = definition[keyword] else { continue }
            guard let number = bound.numberValue, number.isFinite else {
                throw JSONSchemaViolation(
                    path: "\(path).\(keyword)",
                    message: "\(keyword) must be a finite number"
                )
            }
        }

        try validateOrderedBounds(definition, lower: "minimum", upper: "maximum", path: path)
        try validateOrderedBounds(
            definition,
            lower: "exclusiveMinimum",
            upper: "exclusiveMaximum",
            path: path
        )
    }

    private static func validateValue(_ value: JSONValue, schema: JSONValue, path: String) throws {
        if case .bool(let acceptsEverything) = schema {
            if !acceptsEverything {
                throw JSONSchemaViolation(path: path, message: "value is rejected by the false schema")
            }
            return
        }
        guard case .object(let definition) = schema else {
            // validateSchema has already rejected this shape.
            throw JSONSchemaViolation(path: path, message: "invalid schema")
        }

        if let enumValues = definition["enum"]?.arrayValue, !enumValues.contains(value) {
            throw JSONSchemaViolation(path: path, message: "value is not one of the allowed enum values")
        }
        if let constant = definition["const"], constant != value {
            throw JSONSchemaViolation(path: path, message: "value does not match const")
        }

        if let schemas = definition["allOf"]?.arrayValue {
            for schema in schemas {
                try validateValue(value, schema: schema, path: path)
            }
        }
        if let schemas = definition["anyOf"]?.arrayValue {
            let matches = schemas.contains { schema in
                (try? validateValue(value, schema: schema, path: path)) != nil
            }
            guard matches else {
                throw JSONSchemaViolation(path: path, message: "value does not match any anyOf schema")
            }
        }
        if let schemas = definition["oneOf"]?.arrayValue {
            let matchCount = schemas.reduce(into: 0) { count, schema in
                if (try? validateValue(value, schema: schema, path: path)) != nil { count += 1 }
            }
            guard matchCount == 1 else {
                throw JSONSchemaViolation(
                    path: path,
                    message: "value must match exactly one oneOf schema (matched \(matchCount))"
                )
            }
        }

        if let type = definition["type"]?.stringValue, !matches(value, type: type) {
            throw JSONSchemaViolation(path: path, message: "expected \(type)")
        }

        switch value {
        case .object(let object):
            let required = definition["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for key in required where object[key] == nil {
                throw JSONSchemaViolation(path: path, message: "missing required property '\(key)'")
            }
            if let minimum = definition["minProperties"]?.numberValue,
               Double(object.count) < minimum {
                throw JSONSchemaViolation(path: path, message: "expected at least \(integerDescription(minimum)) properties")
            }
            if let maximum = definition["maxProperties"]?.numberValue,
               Double(object.count) > maximum {
                throw JSONSchemaViolation(path: path, message: "expected at most \(integerDescription(maximum)) properties")
            }
            let properties = definition["properties"]?.objectValue ?? [:]
            for (key, child) in object {
                if let childSchema = properties[key] {
                    try validateValue(child, schema: childSchema, path: "\(path).\(key)")
                    continue
                }
                guard let additional = definition["additionalProperties"] else { continue }
                switch additional {
                case .bool(false):
                    throw JSONSchemaViolation(
                        path: "\(path).\(key)",
                        message: "additional property is not allowed"
                    )
                case .bool(true):
                    break
                default:
                    try validateValue(child, schema: additional, path: "\(path).\(key)")
                }
            }
        case .array(let array):
            if let minimum = definition["minItems"]?.numberValue, Double(array.count) < minimum {
                throw JSONSchemaViolation(path: path, message: "expected at least \(integerDescription(minimum)) items")
            }
            if let maximum = definition["maxItems"]?.numberValue, Double(array.count) > maximum {
                throw JSONSchemaViolation(path: path, message: "expected at most \(integerDescription(maximum)) items")
            }
            if definition["uniqueItems"] == .bool(true), Set(array).count != array.count {
                throw JSONSchemaViolation(path: path, message: "array items must be unique")
            }
            if let itemSchema = definition["items"] {
                for (index, child) in array.enumerated() {
                    try validateValue(child, schema: itemSchema, path: "\(path)[\(index)]")
                }
            }
        case .string(let string):
            if let minimum = definition["minLength"]?.numberValue, Double(string.count) < minimum {
                throw JSONSchemaViolation(path: path, message: "string is shorter than \(integerDescription(minimum))")
            }
            if let maximum = definition["maxLength"]?.numberValue, Double(string.count) > maximum {
                throw JSONSchemaViolation(path: path, message: "string is longer than \(integerDescription(maximum))")
            }
            if let expression = definition["pattern"]?.stringValue {
                let regex = try NSRegularExpression(pattern: expression)
                let range = NSRange(string.startIndex..<string.endIndex, in: string)
                if regex.firstMatch(in: string, range: range) == nil {
                    throw JSONSchemaViolation(path: path, message: "string does not match pattern")
                }
            }
        case .number, .integer, .unsignedInteger, .decimal:
            guard let number = value.numberValue else { break }
            if let minimum = definition["minimum"]?.numberValue, number < minimum {
                throw JSONSchemaViolation(path: path, message: "number is below \(minimum)")
            }
            if let maximum = definition["maximum"]?.numberValue, number > maximum {
                throw JSONSchemaViolation(path: path, message: "number is above \(maximum)")
            }
            if let minimum = definition["exclusiveMinimum"]?.numberValue, number <= minimum {
                throw JSONSchemaViolation(path: path, message: "number must be greater than \(minimum)")
            }
            if let maximum = definition["exclusiveMaximum"]?.numberValue, number >= maximum {
                throw JSONSchemaViolation(path: path, message: "number must be less than \(maximum)")
            }
        case .null, .bool:
            break
        }
    }

    private static func validateNonNegativeIntegerKeyword(
        _ keyword: String,
        in definition: [String: JSONValue],
        path: String
    ) throws {
        guard let rawValue = definition[keyword] else { return }
        guard let value = rawValue.numberValue,
              value.isFinite,
              value >= 0,
              value.rounded() == value else {
            throw JSONSchemaViolation(
                path: "\(path).\(keyword)",
                message: "\(keyword) must be a non-negative integer"
            )
        }
    }

    private static func validateOrderedBounds(
        _ definition: [String: JSONValue],
        lower: String,
        upper: String,
        path: String
    ) throws {
        guard let minimum = definition[lower]?.numberValue,
              let maximum = definition[upper]?.numberValue,
              minimum > maximum else { return }
        throw JSONSchemaViolation(
            path: path,
            message: "\(lower) must not exceed \(upper)"
        )
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.null, "null"), (.bool, "boolean"), (.number, "number"),
             (.integer, "number"), (.unsignedInteger, "number"), (.decimal, "number"),
             (.string, "string"), (.array, "array"), (.object, "object"):
            return true
        case (.number(let value), "integer"):
            return value.isFinite && value.rounded() == value
        case (.integer, "integer"), (.unsignedInteger, "integer"):
            return true
        case (.decimal(let value), "integer"):
            var value = value
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 0, .plain)
            return rounded == value
        default:
            return false
        }
    }

    private static func integerDescription(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0)))
    }
}

private extension JSONValue {
    var numberValue: Double? {
        switch self {
        case .number(let value): value
        case .integer(let value): Double(value)
        case .unsignedInteger(let value): Double(value)
        case .decimal(let value): NSDecimalNumber(decimal: value).doubleValue
        default: nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
