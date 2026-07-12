import AgentRuntimeProviders
import Foundation
import XCTest

final class ServerSentEventsParserTests: XCTestCase {
    func testParsesFixtureAcrossEveryByteBoundary() throws {
        let fixture = try loadFixture("sse-edge-cases.sse")
        var parser = ServerSentEventsParser()
        var events: [ServerSentEvent] = []

        for byte in fixture {
            events.append(contentsOf: parser.feed(Data([byte])))
        }
        events.append(contentsOf: parser.finish())

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "update")
        XCTAssertEqual(events[0].id, "event-42")
        XCTAssertEqual(events[0].retryMilliseconds, 1_500)
        XCTAssertEqual(events[0].data, "first line\nsecond line")
        XCTAssertNil(events[1].event)
        XCTAssertEqual(events[1].id, "event-42", "The SSE last-event ID persists across events")
        XCTAssertEqual(events[1].data, "final event without trailing delimiter")
    }

    func testHandlesCRLFWhenChunkEndsAfterCarriageReturn() {
        let source = "event: token\r\ndata: one\r\ndata: two\r\n\r\n"
        let bytes = Data(source.utf8)
        var parser = ServerSentEventsParser()
        var events: [ServerSentEvent] = []

        for chunk in chunked(bytes, sizes: [13, 1, 4, 1]) {
            events.append(contentsOf: parser.feed(chunk))
        }
        events.append(contentsOf: parser.finish())

        XCTAssertEqual(events, [ServerSentEvent(event: "token", data: "one\ntwo")])
    }

    func testStripsBOMIgnoresCommentsAndRejectsNULInID() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("id: safe\n: comment\nid: bad\0id\ndata:\n\n".utf8))
        var parser = ServerSentEventsParser()

        let events = parser.feed(bytes) + parser.finish()

        XCTAssertEqual(events, [ServerSentEvent(event: nil, data: "", id: "safe")])
    }

    func testIgnoresDispatchWithoutDataField() {
        var parser = ServerSentEventsParser()
        let events = parser.feed(Data("event: ping\nid: 1\n\n".utf8)) + parser.finish()
        XCTAssertTrue(events.isEmpty)
    }
}
