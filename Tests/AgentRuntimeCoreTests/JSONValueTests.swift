import AgentRuntimeCore
import XCTest

final class JSONValueTests: XCTestCase {
    func testSignedAndUnsignedIntegersBeyondDoublePrecisionRoundTripExactly() throws {
        let signed = try JSONValue.parse("9007199254740993")
        let unsigned = try JSONValue.parse("18446744073709551615")

        XCTAssertEqual(signed, .integer(9_007_199_254_740_993))
        XCTAssertEqual(unsigned, .unsignedInteger(UInt64.max))
        XCTAssertEqual(try signed.encodedString(), "9007199254740993")
        XCTAssertEqual(try unsigned.encodedString(), "18446744073709551615")
    }

    func testHighPrecisionDecimalRoundTripsWithoutDoubleConversion() throws {
        let source = "1234567890.123456789012345678"
        let value = try JSONValue.parse(source)

        guard case .decimal = value else {
            return XCTFail("Expected an exact decimal representation")
        }
        XCTAssertEqual(try value.encodedString(), source)
        XCTAssertEqual(try JSONValue.parse(value.encodedData()), value)
    }

    func testOrdinaryNumbersKeepSourceCompatibility() throws {
        XCTAssertEqual(try JSONValue.parse("42"), .number(42))
        XCTAssertEqual(try JSONValue.parse("0.25"), .number(0.25))
        XCTAssertEqual(JSONValue(integerLiteral: 7), .number(7))
    }
}
