import AgentRuntimeCore
import XCTest

final class JSONSchemaValidatorTests: XCTestCase {
    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "count": .object([
                "type": .string("integer"),
                "minimum": .number(1),
                "maximum": .number(3),
            ]),
            "labels": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "maxItems": .number(2),
            ]),
        ]),
        "required": .array([.string("count")]),
        "additionalProperties": .bool(false),
    ])

    func testValidSubset() throws {
        XCTAssertNoThrow(try JSONSchemaValidator.validate(
            .object(["count": .number(2), "labels": .array([.string("a")])]),
            against: schema
        ))
    }

    func testRequiredBoundsAndAdditionalProperties() {
        XCTAssertThrowsError(try JSONSchemaValidator.validate(.object([:]), against: schema))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(
            .object(["count": .number(4)]),
            against: schema
        ))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(
            .object(["count": .number(1), "extra": .bool(true)]),
            against: schema
        ))
    }

    func testConstPatternAndExclusiveBounds() throws {
        let constrained: JSONValue = [
            "type": "object",
            "properties": [
                "mode": ["const": "safe"],
                "code": ["type": "string", "pattern": "^[A-Z]{2}-[0-9]+$"],
                "score": [
                    "type": "number",
                    "exclusiveMinimum": 0,
                    "exclusiveMaximum": 1,
                ],
            ],
            "required": ["mode", "code", "score"],
            "additionalProperties": false,
        ]

        XCTAssertNoThrow(try JSONSchemaValidator.validate(
            ["mode": "safe", "code": "AB-12", "score": 0.5],
            against: constrained
        ))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(
            ["mode": "unsafe", "code": "AB-12", "score": 0.5],
            against: constrained
        ))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(
            ["mode": "safe", "code": "bad", "score": 0.5],
            against: constrained
        ))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(
            ["mode": "safe", "code": "AB-12", "score": 1],
            against: constrained
        ))
    }

    func testAnyOfAndOneOfAreEnforced() throws {
        let union: JSONValue = [
            "anyOf": [
                ["type": "string", "const": "automatic"],
                ["type": "integer", "minimum": 1],
            ],
        ]
        XCTAssertNoThrow(try JSONSchemaValidator.validate("automatic", against: union))
        XCTAssertNoThrow(try JSONSchemaValidator.validate(2, against: union))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(0, against: union))

        let exclusive: JSONValue = [
            "oneOf": [
                ["type": "number", "minimum": 0],
                ["type": "number", "maximum": 10],
            ],
        ]
        XCTAssertNoThrow(try JSONSchemaValidator.validate(-1, against: exclusive))
        XCTAssertNoThrow(try JSONSchemaValidator.validate(11, against: exclusive))
        XCTAssertThrowsError(try JSONSchemaValidator.validate(5, against: exclusive))
    }

    func testUnsupportedKeywordsMalformedSchemasAndTypeArraysFailClosed() {
        let schemas: [JSONValue] = [
            ["type": ["string", "null"]],
            ["format": "uuid"],
            ["pattern": "["],
            ["minimum": "zero"],
            ["items": [["type": "string"]]],
            ["anyOf": []],
        ]
        for schema in schemas {
            XCTAssertThrowsError(try JSONSchemaValidator.validateSchema(schema))
            XCTAssertThrowsError(try JSONSchemaValidator.validate(.null, against: schema))
        }
    }

    func testToolRegistryRejectsUnsupportedSchemasAtEveryRegistrationBoundary() async throws {
        let unsupported = SchemaTool(
            name: "unsupported",
            schema: ["type": "object", "dependentRequired": ["a": ["b"]]]
        )
        XCTAssertThrowsError(try AgentToolRegistry(tools: [unsupported]))

        let registry = try AgentToolRegistry()
        await XCTAssertThrowsErrorAsync(try await registry.register(unsupported))
        await XCTAssertThrowsErrorAsync(try await registry.replace(unsupported))
        let descriptors = await registry.descriptors()
        XCTAssertTrue(descriptors.isEmpty)
    }
}

private struct SchemaTool: AgentTool {
    let descriptor: AgentToolDescriptor

    init(name: String, schema: JSONValue) {
        descriptor = AgentToolDescriptor(
            name: name,
            description: "Schema registration test tool",
            inputSchema: schema
        )
    }

    func execute(
        arguments: JSONValue,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolOutput {
        AgentToolOutput(content: arguments)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
