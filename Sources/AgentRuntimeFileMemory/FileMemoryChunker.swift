import CryptoKit
import Foundation

public struct FileMemoryChunk: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var anchor: String
    public var content: String
    public var headingPath: [String]
    public var paragraphIndex: Int
    public var segmentIndex: Int
    public var contentSHA256: String

    public init(
        id: String,
        anchor: String,
        content: String,
        headingPath: [String],
        paragraphIndex: Int,
        segmentIndex: Int,
        contentSHA256: String
    ) {
        self.id = id
        self.anchor = anchor
        self.content = content
        self.headingPath = headingPath
        self.paragraphIndex = paragraphIndex
        self.segmentIndex = segmentIndex
        self.contentSHA256 = contentSHA256
    }
}

/// Deterministic Markdown/text chunking. Stable identity comes from the
/// root-relative path plus structural heading/paragraph position, while
/// mutable content is represented by a separate SHA-256 digest.
public enum FileMemoryChunker {
    /// Maximum visible characters retained from one Markdown heading in chunk
    /// context and metadata. The structural anchor still incorporates a slug
    /// derived from the full heading.
    public static let maximumHeadingComponentCharacterCount = 256

    public static func chunks(
        in text: String,
        path: FileMemoryPath,
        maximumCharacterCount: Int,
        maximumChunkCount: Int = 10_000,
        maximumGeneratedCharacterCount: Int = 33_554_432
    ) throws -> [FileMemoryChunk] {
        guard maximumCharacterCount > 0,
              maximumChunkCount > 0,
              maximumGeneratedCharacterCount > 0 else {
            throw FileMemoryError.invalidConfiguration(
                "Chunking limits must be greater than zero."
            )
        }

        let normalized = normalize(text)
        let isMarkdown = ["md", "markdown"].contains(fileExtension(of: path))
        let paragraphs = parseParagraphs(normalized, markdown: isMarkdown)
        var chunks: [FileMemoryChunk] = []
        var generatedCharacterCount = 0

        for paragraph in paragraphs {
            let pieces = split(paragraph.content, maximumCharacterCount: maximumCharacterCount)
            for (segmentIndex, piece) in pieces.enumerated() {
                guard chunks.count < maximumChunkCount else {
                    throw FileMemoryError.limitExceeded(
                        .chunkCount,
                        limit: maximumChunkCount
                    )
                }
                let headingAnchor = paragraph.headingAnchors.isEmpty
                    ? "root"
                    : paragraph.headingAnchors.joined(separator: "/")
                let anchor = "\(headingAnchor)/p\(paragraph.index)/s\(segmentIndex)"
                let stableMaterial = "file-memory-chunk-v1\0\(path.relativePath)\0\(anchor)"
                let content = contextualized(piece, headingPath: paragraph.headingPath)
                let headingCharacterCount = paragraph.headingPath.reduce(into: 0) {
                    $0 += $1.count
                }
                let (contentAndHeading, contributionOverflow) = content.count
                    .addingReportingOverflow(headingCharacterCount)
                let (nextGeneratedCharacterCount, totalOverflow) = generatedCharacterCount
                    .addingReportingOverflow(contentAndHeading)
                guard !contributionOverflow,
                      !totalOverflow,
                      nextGeneratedCharacterCount <= maximumGeneratedCharacterCount else {
                    throw FileMemoryError.limitExceeded(
                        .generatedCharacters,
                        limit: maximumGeneratedCharacterCount
                    )
                }
                generatedCharacterCount = nextGeneratedCharacterCount
                chunks.append(FileMemoryChunk(
                    id: sha256(stableMaterial),
                    anchor: anchor,
                    content: content,
                    headingPath: paragraph.headingPath,
                    paragraphIndex: paragraph.index,
                    segmentIndex: segmentIndex,
                    contentSHA256: sha256(content)
                ))
            }
        }
        return chunks
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    private struct ParsedParagraph {
        var content: String
        var headingPath: [String]
        var headingAnchors: [String]
        var index: Int
    }

    private static func parseParagraphs(_ text: String, markdown: Bool) -> [ParsedParagraph] {
        guard markdown else {
            return plainParagraphs(text).enumerated().map {
                ParsedParagraph(content: $0.element, headingPath: [], headingAnchors: [], index: $0.offset)
            }
        }

        var headingPath: [String] = []
        var headingAnchors: [String] = []
        var headingOccurrences: [String: Int] = [:]
        var paragraphCounters: [String: Int] = [:]
        var paragraphLines: [String] = []
        var output: [ParsedParagraph] = []
        var fence: Character?

        func currentHeadingKey() -> String {
            headingAnchors.joined(separator: "/")
        }

        func flushParagraph() {
            let content = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll(keepingCapacity: true)
            guard !content.isEmpty else { return }
            let key = currentHeadingKey()
            let index = paragraphCounters[key, default: 0]
            paragraphCounters[key] = index + 1
            output.append(ParsedParagraph(
                content: content,
                headingPath: headingPath,
                headingAnchors: headingAnchors,
                index: index
            ))
        }

        for lineSlice in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSlice)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker(trimmed) {
                if fence == nil {
                    fence = marker
                } else if fence == marker {
                    fence = nil
                }
                paragraphLines.append(line)
                continue
            }

            if fence == nil, let heading = markdownHeading(line) {
                flushParagraph()
                let level = heading.level
                if headingPath.count >= level {
                    headingPath.removeSubrange((level - 1)..<headingPath.count)
                    headingAnchors.removeSubrange((level - 1)..<headingAnchors.count)
                }
                while headingPath.count < level - 1 {
                    headingPath.append("Untitled")
                    headingAnchors.append("untitled-1")
                }

                let parentKey = headingAnchors.joined(separator: "/")
                let base = slug(heading.title)
                let occurrenceKey = "\(parentKey)\0\(level)\0\(base)"
                let occurrence = headingOccurrences[occurrenceKey, default: 0] + 1
                headingOccurrences[occurrenceKey] = occurrence
                headingPath.append(
                    String(heading.title.prefix(maximumHeadingComponentCharacterCount))
                )
                headingAnchors.append("\(base)-\(occurrence)")
                continue
            }

            if fence == nil, trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()

        // A heading-only document is still meaningful memory.
        if output.isEmpty, !headingPath.isEmpty {
            output.append(ParsedParagraph(
                content: headingPath.last ?? "",
                headingPath: Array(headingPath.dropLast()),
                headingAnchors: headingAnchors,
                index: 0
            ))
        }
        return output
    }

    private static func plainParagraphs(_ text: String) -> [String] {
        var output: [String] = []
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                let paragraph = lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !paragraph.isEmpty { output.append(paragraph) }
                lines.removeAll(keepingCapacity: true)
            } else {
                lines.append(line)
            }
        }
        let paragraph = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !paragraph.isEmpty { output.append(paragraph) }
        return output
    }

    private static func split(_ content: String, maximumCharacterCount: Int) -> [String] {
        var output: [String] = []
        var start = content.startIndex
        let end = content.endIndex

        while start < end {
            let hardEnd = content.index(
                start,
                offsetBy: maximumCharacterCount,
                limitedBy: end
            ) ?? end
            if hardEnd == end {
                let tail = content[start..<end]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { output.append(tail) }
                break
            }
            let candidate = content[start..<hardEnd]
            let boundary = candidate.lastIndex(where: { $0.isWhitespace }) ?? hardEnd
            let piece = content[start..<boundary]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { output.append(piece) }
            start = boundary
            while start < end, content[start].isWhitespace {
                content.formIndex(after: &start)
            }
        }
        return output
    }

    private static func contextualized(_ content: String, headingPath: [String]) -> String {
        guard !headingPath.isEmpty else { return content }
        return headingPath.joined(separator: " › ") + "\n\n" + content
    }

    private static func normalize(_ text: String) -> String {
        var result = text
        if result.hasPrefix("\u{feff}") { result.removeFirst() }
        return result
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    private static func fileExtension(of path: FileMemoryPath) -> String {
        guard let name = path.name, let separator = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: separator)...]).lowercased()
    }

    private static func markdownHeading(_ line: String) -> (level: Int, title: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "#" else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let afterHashes = trimmed.dropFirst(hashes.count)
        guard afterHashes.isEmpty || afterHashes.first?.isWhitespace == true else { return nil }
        let title = afterHashes
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (hashes.count, title)
    }

    private static func fenceMarker(_ trimmedLine: String) -> Character? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
        return trimmedLine.prefix(while: { $0 == first }).count >= 3 ? first : nil
    }

    private static func slug(_ value: String) -> String {
        let original = value
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var scalars: [Unicode.Scalar] = []
        var lastWasSeparator = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append("-")
                lastWasSeparator = true
            }
        }
        let value = String(String.UnicodeScalarView(scalars)).trimmingCharacters(
            in: CharacterSet(charactersIn: "-")
        )
        if value.isEmpty { return "section-\(sha256(original).prefix(12))" }
        return String(value.prefix(80))
    }
}
