import Foundation

/// A parsed Server-Sent Event. `retryMilliseconds` and `id` are retained for callers
/// that need reconnection semantics, although model-provider streams normally do not.
public struct ServerSentEvent: Sendable, Hashable {
    public var event: String?
    public var data: String
    public var id: String?
    public var retryMilliseconds: Int?

    public init(
        event: String? = nil,
        data: String,
        id: String? = nil,
        retryMilliseconds: Int? = nil
    ) {
        self.event = event
        self.data = data
        self.id = id
        self.retryMilliseconds = retryMilliseconds
    }
}
/// Incremental, chunk-boundary-independent SSE parser following the HTML event-stream grammar.
///
/// The parser accepts LF, CRLF, and CR line endings, joins repeated `data` fields with a
/// newline, ignores comments and unknown fields, strips a leading UTF-8 BOM, and dispatches
/// a final unterminated event from `finish()`.
public struct ServerSentEventsParser: Sendable {
    private var buffer = Data()
    private var eventType: String?
    private var dataLines: [String] = []
    private var lastEventID: String?
    private var retryMilliseconds: Int?
    private var hasDataField = false
    private var isAtStreamStart = true

    public init() {}

    public mutating func feed(_ chunk: Data) -> [ServerSentEvent] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        return drainLines(final: false)
    }

    public mutating func finish() -> [ServerSentEvent] {
        var events = drainLines(final: true)
        if !buffer.isEmpty {
            processLine(buffer)
            buffer.removeAll(keepingCapacity: false)
        }
        if let event = dispatchEvent() {
            events.append(event)
        }
        return events
    }

    private mutating func drainLines(final: Bool) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []

        while let terminatorIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let terminator = buffer[terminatorIndex]
            let nextIndex = buffer.index(after: terminatorIndex)

            // A CR at the end of a non-final chunk may be the first byte of CRLF.
            if terminator == 0x0D, nextIndex == buffer.endIndex, !final {
                break
            }

            let line = Data(buffer[..<terminatorIndex])
            var removalEnd = nextIndex
            if terminator == 0x0D,
               nextIndex < buffer.endIndex,
               buffer[nextIndex] == 0x0A {
                removalEnd = buffer.index(after: nextIndex)
            }
            buffer.removeSubrange(buffer.startIndex..<removalEnd)

            if line.isEmpty {
                if let event = dispatchEvent() {
                    events.append(event)
                }
            } else {
                processLine(line)
            }
        }
        return events
    }

    private mutating func processLine(_ bytes: Data) {
        var line = String(decoding: bytes, as: UTF8.self)
        if isAtStreamStart {
            isAtStreamStart = false
            if line.first == "\u{FEFF}" {
                line.removeFirst()
            }
        }
        guard !line.hasPrefix(":") else { return }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            eventType = String(value)
        case "data":
            hasDataField = true
            dataLines.append(String(value))
        case "id":
            if !value.unicodeScalars.contains(where: { $0.value == 0 }) {
                lastEventID = String(value)
            }
        case "retry":
            if !value.isEmpty,
               value.allSatisfy(\.isNumber),
               let parsed = Int(value),
               parsed >= 0 {
                retryMilliseconds = parsed
            }
        default:
            break
        }
    }

    private mutating func dispatchEvent() -> ServerSentEvent? {
        defer {
            eventType = nil
            dataLines.removeAll(keepingCapacity: true)
            retryMilliseconds = nil
            hasDataField = false
        }
        guard hasDataField else { return nil }
        return ServerSentEvent(
            event: eventType?.isEmpty == false ? eventType : nil,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID,
            retryMilliseconds: retryMilliseconds
        )
    }
}
