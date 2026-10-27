import Foundation
import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One item within a Markdown list, preserving its authored marker (so ordered
/// lists keep their real numbers) and indentation depth (so nested items stay
/// nested).
public struct MarkdownListItem: Equatable, Sendable {
    public let marker: String
    public let text: String
    public let depth: Int

    public init(marker: String, text: String, depth: Int) {
        self.marker = marker
        self.text = text
        self.depth = depth
    }
}

/// Per-column alignment for a table, parsed from the colons in the delimiter row.
public enum MarkdownColumnAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

/// A GitHub-flavored table: a header row, per-column alignment, and body rows.
/// Rows are stored as raw cell strings so each cell can still render inline
/// Markdown.
public struct MarkdownTable: Equatable, Sendable {
    public let header: [String]
    public let alignments: [MarkdownColumnAlignment]
    public let rows: [[String]]

    public init(
        header: [String],
        alignments: [MarkdownColumnAlignment],
        rows: [[String]]
    ) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

/// A single block-level element parsed from Markdown.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(String)
    case quote(String)
    case list([MarkdownListItem])
    case table(MarkdownTable)
}

/// Bounded, thread-safe LRU cache keyed by raw Markdown text so repeated view
/// evaluations during streaming or scrolling reuse parsed block structures and
/// inline `AttributedString` values without re-parsing on `@MainActor`.
public final class MarkdownLRUCache<Value: Sendable>: @unchecked Sendable {
    private final class Node {
        let key: String
        var value: Value
        var cost: Int
        weak var prev: Node?
        var next: Node?

        init(key: String, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    public let maxEntries: Int
    public let maxCostBytes: Int
    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private var totalCostBytes = 0
    private var hits = 0
    private var misses = 0

    public init(maxEntries: Int, maxCostBytes: Int = 4 * 1_024 * 1_024) {
        self.maxEntries = max(1, maxEntries)
        self.maxCostBytes = max(1, maxCostBytes)
    }

    public func value(for key: String, compute: (String) -> Value) -> Value {
        lock.lock()
        if let existing = nodes[key] {
            moveToHead(existing)
            hits += 1
            let cached = existing.value
            lock.unlock()
            return cached
        }
        misses += 1
        lock.unlock()

        let computed = compute(key)
        let cost = max(1, key.utf8.count)
        guard cost <= maxCostBytes else {
            return computed
        }

        lock.lock()
        defer { lock.unlock() }
        if let raced = nodes[key] {
            totalCostBytes += cost - raced.cost
            raced.value = computed
            raced.cost = cost
            moveToHead(raced)
            evictIfNeeded()
            return computed
        }
        let node = Node(key: key, value: computed, cost: cost)
        nodes[key] = node
        insertAtHead(node)
        totalCostBytes += cost
        evictIfNeeded()
        return computed
    }

    public func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodes[key] != nil
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return nodes.count
    }

    public var totalCost: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalCostBytes
    }

    public var stats: (hits: Int, misses: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hits, misses)
    }

    public func removeAll() {
        lock.lock()
        var current = head
        while let node = current {
            let next = node.next
            node.prev = nil
            node.next = nil
            current = next
        }
        nodes.removeAll()
        head = nil
        tail = nil
        totalCostBytes = 0
        hits = 0
        misses = 0
        lock.unlock()
    }

    private func insertAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        detach(node)
        insertAtHead(node)
    }

    private func detach(_ node: Node) {
        let prev = node.prev
        let next = node.next
        if let prev {
            prev.next = next
        } else {
            head = next
        }
        if let next {
            next.prev = prev
        } else {
            tail = prev
        }
        node.prev = nil
        node.next = nil
    }

    private func evictIfNeeded() {
        while (nodes.count > maxEntries || totalCostBytes > maxCostBytes),
              let oldest = tail {
            detach(oldest)
            nodes.removeValue(forKey: oldest.key)
            totalCostBytes -= oldest.cost
        }
    }
}

/// Splits Markdown into block-level elements. Kept dependency-free and pure so
/// it can be unit tested without a view host.
public enum MarkdownParser {
    private static let maximumRenderedBytes = 256 * 1_024
    private static let maximumRenderedLines = 500
    private static let maximumRenderedPipes = 1_000
    private static let maximumInlineMarkers = 2_000
    public static let maximumRenderedTableCells = 1_000

    public static let maxBlockCacheEntries = 256
    public static let maxInlineCacheEntries = 1_024
    public static let maxCacheCostBytes = 4 * 1_024 * 1_024

    public static let blockCache = MarkdownLRUCache<[MarkdownBlock]>(
        maxEntries: maxBlockCacheEntries,
        maxCostBytes: maxCacheCostBytes
    )
    public static let inlineCache = MarkdownLRUCache<AttributedString>(
        maxEntries: maxInlineCacheEntries,
        maxCostBytes: maxCacheCostBytes
    )

    public static func clearCache() {
        blockCache.removeAll()
        inlineCache.removeAll()
    }

    public static func isWithinRenderingLimits(_ text: String) -> Bool {
        guard text.utf8.count <= maximumRenderedBytes else { return false }
        let normalized = normalizeLineEndings(text)
        var lines = 1
        var pipes = 0
        var inlineMarkers = 0
        for character in normalized {
            if character == "\n" {
                lines += 1
                if lines > maximumRenderedLines { return false }
            } else if character == "|" {
                pipes += 1
                if pipes > maximumRenderedPipes { return false }
            } else if character == "*" || character == "_" || character == "~"
                        || character == "`" || character == "[" {
                inlineMarkers += 1
                if inlineMarkers > maximumInlineMarkers { return false }
            }
        }
        return isWithinTableCellLimits(blocks(from: text))
    }

    public static func isWithinTableCellLimits(_ blocks: [MarkdownBlock]) -> Bool {
        var totalCells = 0
        for block in blocks {
            guard case let .table(table) = block else { continue }
            let rowCount = table.rows.count + 1
            let (tableCells, overflow) = table.header.count.multipliedReportingOverflow(by: rowCount)
            if overflow { return false }
            let (nextTotal, sumOverflow) = totalCells.addingReportingOverflow(tableCells)
            if sumOverflow || nextTotal > maximumRenderedTableCells { return false }
            totalCells = nextTotal
        }
        return true
    }

    public static func blocks(from text: String) -> [MarkdownBlock] {
        blockCache.value(for: text, compute: parseBlocks(from:))
    }

    public static func inline(_ string: String) -> AttributedString {
        inlineCache.value(for: string, compute: parseInline(_:))
    }

    private static func parseInline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(string)
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func parseBlocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let normalized = normalizeLineEndings(text)
        let lines = normalized.components(separatedBy: "\n")
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceLength(trimmed) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !isClosingFence(lines[index].trimmingCharacters(in: .whitespaces), fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let level = headingLevel(trimmed) {
                flushParagraph()
                let content = trimmed
                    .drop { $0 == "#" }
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: content))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(
                        String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if listItem(from: line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = listItem(from: current) {
                        items.append(item)
                        index += 1
                    } else if !items.isEmpty,
                              !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              !isBlockStart(current.trimmingCharacters(in: .whitespaces)) {
                        let last = items.removeLast()
                        let continued = current.trimmingCharacters(in: .whitespaces)
                        items.append(MarkdownListItem(
                            marker: last.marker,
                            text: last.text + " " + continued,
                            depth: last.depth
                        ))
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            if index + 1 < lines.count,
               rowContainsUnescapedPipe(trimmed),
               let alignments = tableDelimiterAlignments(
                   lines[index + 1].trimmingCharacters(in: .whitespaces)
               ),
               splitTableRow(trimmed).count == alignments.count {
                flushParagraph()
                let header = splitTableRow(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !rowLine.isEmpty,
                          rowContainsUnescapedPipe(rowLine) else {
                        break
                    }
                    if !rowLine.hasPrefix("|") {
                        if isBlockStart(rowLine) { break }
                        if let item = listItem(from: lines[index]),
                           !item.text.hasPrefix("|") {
                            break
                        }
                    }
                    rows.append(splitTableRow(rowLine))
                    index += 1
                }
                blocks.append(.table(MarkdownTable(
                    header: header,
                    alignments: alignments,
                    rows: rows
                )))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func fenceLength(_ line: String) -> Int? {
        let ticks = line.prefix { $0 == "`" }.count
        guard ticks >= 3, !line.dropFirst(ticks).contains("`") else { return nil }
        return ticks
    }

    private static func isClosingFence(_ line: String, _ openLength: Int) -> Bool {
        guard !line.isEmpty, line.allSatisfy({ $0 == "`" }) else { return false }
        return line.count >= openLength
    }

    private static func headingLevel(_ line: String) -> Int? {
        var hashes = 0
        for character in line {
            if character == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return hashes
    }

    private static func isBlockStart(_ trimmed: String) -> Bool {
        fenceLength(trimmed) != nil
            || headingLevel(trimmed) != nil
            || trimmed.hasPrefix(">")
    }

    private static func listItem(from line: String) -> MarkdownListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let depth = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(leading.count)

        if let first = body.first, "-*+".contains(first) {
            let rest = body.dropFirst()
            guard rest.first == " " else { return nil }
            return MarkdownListItem(
                marker: "\u{2022}",
                text: rest.trimmingCharacters(in: .whitespaces),
                depth: depth
            )
        }

        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = body.dropFirst(digits.count)
            guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else {
                return nil
            }
            return MarkdownListItem(
                marker: "\(digits).",
                text: afterDigits.dropFirst().trimmingCharacters(in: .whitespaces),
                depth: depth
            )
        }

        return nil
    }

    private static func rowContainsUnescapedPipe(_ line: String) -> Bool {
        var backslashes = 0
        for character in line {
            if character == "|", backslashes % 2 == 0 { return true }
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        return false
    }

    public static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var backslashes = 0
        for character in line {
            if character == "|" {
                if backslashes % 2 == 0 {
                    cells.append(current)
                    current = ""
                } else {
                    current.removeLast()
                    current.append("|")
                }
            } else {
                current.append(character)
            }
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        cells.append(current)
        var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.first == "" { trimmed.removeFirst() }
        if trimmed.last == "" { trimmed.removeLast() }
        return trimmed
    }

    public static func tableDelimiterAlignments(_ line: String) -> [MarkdownColumnAlignment]? {
        guard rowContainsUnescapedPipe(line) else { return nil }
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownColumnAlignment] = []
        for cell in cells {
            let leadingColon = cell.hasPrefix(":")
            let trailingColon = cell.hasSuffix(":")
            let dashes = cell.dropFirst(leadingColon ? 1 : 0)
                .dropLast(trailingColon ? 1 : 0)
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else {
                return nil
            }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }
}

#if (canImport(UIKit) && !os(watchOS)) || canImport(AppKit)

#if canImport(UIKit) && !os(watchOS)
private typealias PlatformFont = UIFont
private typealias PlatformFontDescriptor = UIFontDescriptor
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
private typealias PlatformFont = NSFont
private typealias PlatformFontDescriptor = NSFontDescriptor
private typealias PlatformColor = NSColor
#endif

/// Renders a practical subset of Markdown (headings, ordered/unordered lists,
/// fenced code blocks, blockquotes, tables, plus inline emphasis, links, and
/// inline code) as native views with standard platform text selection controls.
public struct MarkdownText: View, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public static let quoteBarAttribute = NSAttributedString.Key(
        "CopilotProjects.MarkdownQuoteBar"
    )
    public static let tableHeaderDividerAttribute = NSAttributedString.Key(
        "CopilotProjects.MarkdownTableHeaderDivider"
    )

    #if canImport(UIKit) && !os(watchOS)
    public static let headingLevelAttribute = NSAttributedString.Key.accessibilityTextHeadingLevel
    #else
    public static let headingLevelAttribute = NSAttributedString.Key("AXHeadingLevel")
    #endif

    private enum TextRole {
        case heading(Int)
        case body
        case footnote
    }

    private enum ProsePart: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case quote(String)
    }

    private enum RenderSegment: Equatable {
        case prose([ProsePart])
        case codeBlock(String)
        case table(MarkdownTable)
    }

    public var body: some View {
        if !MarkdownParser.isWithinRenderingLimits(text) {
            SelectableMarkdownText(wraps: true) { styleContext, _ in
                Self.makePlainAttributedText(text, styleContext: styleContext)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                let segments = Self.segments(from: MarkdownParser.blocks(from: text))
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    view(for: segment)
                }
            }
        }
    }

    private static func segments(from blocks: [MarkdownBlock]) -> [RenderSegment] {
        var result: [RenderSegment] = []
        var currentProse: [ProsePart] = []

        func flushProse() {
            guard !currentProse.isEmpty else { return }
            result.append(.prose(currentProse))
            currentProse = []
        }

        for block in blocks {
            switch block {
            case let .heading(level, text):
                currentProse.append(.heading(level: level, text: text))
            case let .paragraph(text):
                currentProse.append(.paragraph(text))
            case let .list(items):
                currentProse.append(.list(items))
            case let .quote(text):
                currentProse.append(.quote(text))
            case let .codeBlock(code):
                flushProse()
                result.append(.codeBlock(code))
            case let .table(table):
                flushProse()
                result.append(.table(table))
            }
        }
        flushProse()
        return result
    }

    @ViewBuilder
    private func view(for segment: RenderSegment) -> some View {
        switch segment {
        case let .prose(parts):
            SelectableMarkdownText(wraps: true) { styleContext, _ in
                Self.makeProseAttributedText(
                    parts,
                    styleContext: styleContext
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .codeBlock(code):
            ScrollView(.horizontal, showsIndicators: false) {
                SelectableMarkdownText(wraps: false) { styleContext, _ in
                    Self.makeCodeBlockAttributedText(
                        code,
                        styleContext: styleContext
                    )
                }
                .padding(10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Self.containerBackgroundColor,
                in: RoundedRectangle(cornerRadius: 8)
            )
        case let .table(table):
            tableView(table)
        }
    }

    @ViewBuilder
    private func tableView(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SelectableMarkdownText(wraps: false) { styleContext, layoutDirection in
                Self.makeTableAttributedText(
                    table,
                    styleContext: styleContext,
                    layoutDirection: layoutDirection
                )
            }
            .padding(10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Self.containerBackgroundColor,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private static let cellWidth: CGFloat = 280
    private static let minCellWidth: CGFloat = 36
    private static let tableColumnSpacing: CGFloat = 14

    private static var containerBackgroundColor: Color {
        #if canImport(UIKit) && !os(watchOS)
        Color(uiColor: .tertiarySystemBackground)
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    fileprivate static var primaryLabelColor: PlatformColor {
        #if canImport(UIKit) && !os(watchOS)
        .label
        #else
        .labelColor
        #endif
    }

    fileprivate static var secondaryLabelColor: PlatformColor {
        #if canImport(UIKit) && !os(watchOS)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    public static func resolvedTableTextAlignment(
        _ alignments: [MarkdownColumnAlignment],
        column: Int,
        layoutDirection: LayoutDirection
    ) -> NSTextAlignment {
        let isRTL = layoutDirection == .rightToLeft
        let columnAlignment = column < alignments.count ? alignments[column] : .leading
        switch columnAlignment {
        case .leading: return isRTL ? .right : .left
        case .center: return .center
        case .trailing: return isRTL ? .left : .right
        }
    }

    private func inline(_ string: String) -> AttributedString {
        MarkdownParser.inline(string)
    }

    fileprivate struct StyleContext: Equatable {
        let dynamicTypeSize: DynamicTypeSize
        let legibilityWeight: LegibilityWeight?

        #if canImport(UIKit) && !os(watchOS)
        var traitCollection: UITraitCollection {
            var traits: [UITraitCollection] = [
                UITraitCollection(
                    preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)
                ),
            ]
            if let legibilityWeight {
                traits.append(
                    UITraitCollection(
                        legibilityWeight: legibilityWeight == .bold ? .bold : .regular
                    )
                )
            }
            return UITraitCollection(traitsFrom: traits)
        }
        #endif
    }

    private static func makePlainAttributedText(
        _ string: String,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let font = scaledSystemFont(
            role: .body,
            weight: .regular,
            styleContext: styleContext
        )
        let paragraphStyle = defaultParagraphStyle(
            alignment: .natural,
            wraps: true,
            firstLineHeadIndent: 0,
            headIndent: 0,
            tabStopLocation: nil,
            paragraphSpacing: 0
        )
        return NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: primaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private static func makeProseAttributedText(
        _ parts: [ProsePart],
        styleContext: StyleContext
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (partIndex, part) in parts.enumerated() {
            let isLastPart = partIndex == parts.count - 1
            switch part {
            case let .heading(level, text):
                let attributed = NSMutableAttributedString(
                    attributedString: makeAttributedText(
                        MarkdownParser.inline(text),
                        role: .heading(level),
                        weight: .semibold,
                        foregroundColor: primaryLabelColor,
                        alignment: .natural,
                        wraps: true,
                        trailingParagraphSpacing: isLastPart ? 0 : 8,
                        styleContext: styleContext
                    )
                )
                if attributed.length > 0 {
                    attributed.addAttribute(
                        headingLevelAttribute,
                        value: NSNumber(value: min(max(level, 1), 6)),
                        range: NSRange(location: 0, length: attributed.length)
                    )
                }
                result.append(attributed)
                if !isLastPart {
                    result.append(NSAttributedString(string: "\n"))
                }
            case let .paragraph(text):
                let attributed = makeAttributedText(
                    MarkdownParser.inline(text),
                    role: .body,
                    weight: .regular,
                    foregroundColor: primaryLabelColor,
                    alignment: .natural,
                    wraps: true,
                    trailingParagraphSpacing: isLastPart ? 0 : 8,
                    styleContext: styleContext
                )
                result.append(attributed)
                if !isLastPart {
                    result.append(NSAttributedString(string: "\n"))
                }
            case let .quote(text):
                let attributed = NSMutableAttributedString(
                    attributedString: makeAttributedText(
                        MarkdownParser.inline(text),
                        role: .body,
                        weight: .regular,
                        foregroundColor: secondaryLabelColor,
                        alignment: .natural,
                        wraps: true,
                        firstLineHeadIndent: 11,
                        headIndent: 11,
                        trailingParagraphSpacing: isLastPart ? 0 : 8,
                        styleContext: styleContext
                    )
                )
                if attributed.length > 0 {
                    attributed.addAttribute(
                        quoteBarAttribute,
                        value: partIndex + 1,
                        range: NSRange(location: 0, length: attributed.length)
                    )
                }
                result.append(attributed)
                if !isLastPart {
                    result.append(NSAttributedString(string: "\n"))
                }
            case let .list(items):
                for (itemIndex, item) in items.enumerated() {
                    let isLastItem = itemIndex == items.count - 1
                    let spacing: CGFloat = isLastItem ? (isLastPart ? 0 : 8) : 4
                    let attributedItem = makeListItemAttributedText(
                        item,
                        trailingParagraphSpacing: spacing,
                        styleContext: styleContext
                    )
                    result.append(attributedItem)
                    if !(isLastPart && isLastItem) {
                        result.append(NSAttributedString(string: "\n"))
                    }
                }
            }
        }
        return result
    }

    private static func makeListItemAttributedText(
        _ item: MarkdownListItem,
        trailingParagraphSpacing: CGFloat,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let baseFont = scaledSystemFont(
            role: .body,
            weight: .regular,
            monospacedDigits: true,
            styleContext: styleContext
        )
        let baseIndent = CGFloat(min(item.depth, 6)) * 14
        let markerWidth = ceil(
            (item.marker as NSString).size(withAttributes: [.font: baseFont]).width
        )
        let textIndent = baseIndent + markerWidth + 8

        let bodyAttributed = makeAttributedText(
            MarkdownParser.inline(item.text),
            role: .body,
            weight: .regular,
            foregroundColor: primaryLabelColor,
            alignment: .natural,
            wraps: true,
            firstLineHeadIndent: baseIndent,
            headIndent: textIndent,
            tabStopLocation: textIndent,
            trailingParagraphSpacing: trailingParagraphSpacing,
            styleContext: styleContext
        )
        let itemParagraphStyle = (bodyAttributed.length > 0
            ? bodyAttributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil) ?? defaultParagraphStyle(
                alignment: .natural,
                wraps: true,
                firstLineHeadIndent: baseIndent,
                headIndent: textIndent,
                tabStopLocation: textIndent,
                paragraphSpacing: trailingParagraphSpacing
            )

        let prefix = NSMutableAttributedString(
            string: "\(item.marker)\t",
            attributes: [
                .font: baseFont,
                .foregroundColor: secondaryLabelColor,
                .paragraphStyle: itemParagraphStyle,
            ]
        )
        prefix.append(bodyAttributed)
        return prefix
    }

    private static func makeCodeBlockAttributedText(
        _ code: String,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let font = scaledMonospacedFont(
            role: .footnote,
            weight: .regular,
            styleContext: styleContext
        )
        let paragraphStyle = defaultParagraphStyle(
            alignment: .natural,
            wraps: false,
            firstLineHeadIndent: 0,
            headIndent: 0,
            tabStopLocation: nil,
            paragraphSpacing: 0
        )
        return NSAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: primaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private static func makeTableAttributedText(
        _ table: MarkdownTable,
        styleContext: StyleContext,
        layoutDirection: LayoutDirection
    ) -> NSAttributedString {
        let columns = max(table.header.count, 1)
        let headerCells: [NSAttributedString] = (0..<columns).map { column in
            let text = column < table.header.count ? table.header[column] : ""
            return makeAttributedText(
                MarkdownParser.inline(text),
                role: .body,
                weight: .semibold,
                foregroundColor: primaryLabelColor,
                alignment: .natural,
                wraps: true,
                styleContext: styleContext
            )
        }
        let bodyRows: [[NSAttributedString]] = table.rows.map { row in
            (0..<columns).map { column in
                let text = column < row.count ? row[column] : ""
                return makeAttributedText(
                    MarkdownParser.inline(text),
                    role: .body,
                    weight: .regular,
                    foregroundColor: primaryLabelColor,
                    alignment: .natural,
                    wraps: true,
                    styleContext: styleContext
                )
            }
        }

        let columnWidths: [CGFloat] = (0..<columns).map { column in
            var widest = minCellWidth
            for cell in [headerCells[column]] + bodyRows.map({ $0[column] }) where cell.length > 0 {
                let measured = ceil(
                    cell.boundingRect(
                        with: CGSize(
                            width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude
                        ),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    ).width
                )
                widest = max(widest, min(cellWidth, measured))
            }
            return widest
        }

        var columnOrigins: [CGFloat] = []
        var runningX: CGFloat = 0
        for (column, width) in columnWidths.enumerated() {
            columnOrigins.append(runningX)
            runningX += width + (column < columns - 1 ? tableColumnSpacing : 0)
        }

        let tabStops: [NSTextTab] = (1..<columns).map { column in
            let alignment = resolvedTableTextAlignment(
                table.alignments,
                column: column,
                layoutDirection: layoutDirection
            )
            let location: CGFloat = switch alignment {
            case .center:
                columnOrigins[column] + columnWidths[column] / 2
            case .right:
                columnOrigins[column] + columnWidths[column]
            default:
                columnOrigins[column]
            }
            return NSTextTab(textAlignment: alignment, location: location)
        }
        let firstColumnAlignment = columns == 1
            ? resolvedTableTextAlignment(
                table.alignments,
                column: 0,
                layoutDirection: layoutDirection
            )
            : .left

        let allRows = [headerCells] + bodyRows
        let result = NSMutableAttributedString()
        let fallbackFont = scaledSystemFont(
            role: .body,
            weight: .regular,
            styleContext: styleContext
        )

        for (rowIndex, rowCells) in allRows.enumerated() {
            let isHeader = rowIndex == 0
            let isLastRow = rowIndex == allRows.count - 1
            let wrappedColumns: [[NSAttributedString]] = (0..<columns).map { column in
                wrapCellIntoLines(rowCells[column], width: columnWidths[column])
            }
            let visualLineCount = max(1, wrappedColumns.map(\.count).max() ?? 1)
            let rowStart = result.length

            for lineIndex in 0..<visualLineCount {
                let isLastVisualLine = lineIndex == visualLineCount - 1
                let spacingAfterLine: CGFloat = if !isLastVisualLine {
                    0
                } else if isLastRow {
                    0
                } else if isHeader {
                    12
                } else {
                    6
                }
                let lineStyle = NSMutableParagraphStyle()
                lineStyle.alignment = firstColumnAlignment
                lineStyle.lineBreakMode = .byClipping
                lineStyle.paragraphSpacing = spacingAfterLine
                lineStyle.tabStops = tabStops

                let lineAttributed = NSMutableAttributedString()
                for column in 0..<columns {
                    if column > 0 {
                        lineAttributed.append(
                            NSAttributedString(
                                string: "\t",
                                attributes: [
                                    .font: fallbackFont,
                                    .foregroundColor: primaryLabelColor,
                                ]
                            )
                        )
                    }
                    let columnLines = wrappedColumns[column]
                    if lineIndex < columnLines.count {
                        lineAttributed.append(columnLines[lineIndex])
                    }
                }
                if lineAttributed.length == 0 {
                    lineAttributed.append(
                        NSAttributedString(
                            string: " ",
                            attributes: [
                                .font: fallbackFont,
                                .foregroundColor: primaryLabelColor,
                            ]
                        )
                    )
                }
                lineAttributed.addAttribute(
                    .paragraphStyle,
                    value: lineStyle,
                    range: NSRange(location: 0, length: lineAttributed.length)
                )
                result.append(lineAttributed)
                if !(isLastRow && isLastVisualLine) {
                    result.append(
                        NSAttributedString(
                            string: "\n",
                            attributes: [
                                .font: fallbackFont,
                                .foregroundColor: primaryLabelColor,
                                .paragraphStyle: lineStyle,
                            ]
                        )
                    )
                }
            }

            if isHeader, !table.rows.isEmpty, result.length > rowStart {
                result.addAttribute(
                    tableHeaderDividerAttribute,
                    value: max(runningX, 1),
                    range: NSRange(location: rowStart, length: result.length - rowStart)
                )
            }
        }

        return result
    }

    private static func wrapCellIntoLines(
        _ cell: NSAttributedString,
        width: CGFloat
    ) -> [NSAttributedString] {
        guard cell.length > 0 else { return [NSAttributedString()] }
        let singleLineWidth = ceil(
            cell.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).width
        )
        if singleLineWidth <= width && !cell.string.contains("\n") {
            return [cell]
        }

        let storage = NSTextStorage(attributedString: cell)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var lines: [NSAttributedString] = []
        let totalGlyphs = layoutManager.numberOfGlyphs
        var glyphIndex = 0
        let nsString = storage.string as NSString
        while glyphIndex < totalGlyphs {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange
            )
            guard lineGlyphRange.length > 0 else { break }
            var charRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            while charRange.length > 0 {
                let lastChar = nsString.character(at: NSMaxRange(charRange) - 1)
                if lastChar == 0x0A || lastChar == 0x0D || lastChar == 0x20 || lastChar == 0x09 {
                    charRange.length -= 1
                } else {
                    break
                }
            }
            lines.append(storage.attributedSubstring(from: charRange))
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        return lines.isEmpty ? [NSAttributedString()] : lines
    }

    private static func makeAttributedText(
        _ content: AttributedString,
        role: TextRole,
        weight: PlatformFont.Weight,
        foregroundColor: PlatformColor,
        alignment: NSTextAlignment,
        wraps: Bool,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0,
        tabStopLocation: CGFloat? = nil,
        trailingParagraphSpacing: CGFloat = 0,
        styleContext: StyleContext
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseParagraphStyle = defaultParagraphStyle(
            alignment: alignment,
            wraps: wraps,
            firstLineHeadIndent: firstLineHeadIndent,
            headIndent: headIndent,
            tabStopLocation: tabStopLocation,
            paragraphSpacing: 0
        )

        for run in content.runs {
            let substring = String(content[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font: PlatformFont
            if intent.contains(.code) {
                font = scaledMonospacedFont(
                    role: role,
                    weight: intent.contains(.stronglyEmphasized) ? .bold : weight,
                    styleContext: styleContext
                )
            } else {
                font = scaledSystemFont(
                    role: role,
                    weight: weight,
                    bold: intent.contains(.stronglyEmphasized),
                    styleContext: styleContext
                )
            }
            if intent.contains(.emphasized) {
                font = applyingItalicTrait(to: font)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foregroundColor,
                .paragraphStyle: baseParagraphStyle,
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: substring, attributes: attributes))
        }

        if result.length > 0 {
            let nsString = result.string as NSString
            let lastBreak = nsString.range(of: "\n", options: .backwards)
            let lastParagraphStart = lastBreak.location == NSNotFound ? 0 : lastBreak.location + 1
            let lastParagraphRange = NSRange(
                location: lastParagraphStart,
                length: nsString.length - lastParagraphStart
            )
            let trailingStyle = defaultParagraphStyle(
                alignment: alignment,
                wraps: wraps,
                firstLineHeadIndent: lastParagraphStart == 0 ? firstLineHeadIndent : headIndent,
                headIndent: headIndent,
                tabStopLocation: tabStopLocation,
                paragraphSpacing: trailingParagraphSpacing
            )
            result.addAttribute(.paragraphStyle, value: trailingStyle, range: lastParagraphRange)

            if lastParagraphStart > 0 && firstLineHeadIndent != headIndent {
                let firstBreak = nsString.range(of: "\n")
                if firstBreak.location != NSNotFound && firstBreak.location + 1 < lastParagraphStart {
                    let middleRange = NSRange(
                        location: firstBreak.location + 1,
                        length: lastParagraphStart - (firstBreak.location + 1)
                    )
                    let middleStyle = defaultParagraphStyle(
                        alignment: alignment,
                        wraps: wraps,
                        firstLineHeadIndent: headIndent,
                        headIndent: headIndent,
                        tabStopLocation: tabStopLocation,
                        paragraphSpacing: 0
                    )
                    result.addAttribute(.paragraphStyle, value: middleStyle, range: middleRange)
                }
            }
        }

        return result
    }

    private static func defaultParagraphStyle(
        alignment: NSTextAlignment,
        wraps: Bool,
        firstLineHeadIndent: CGFloat,
        headIndent: CGFloat,
        tabStopLocation: CGFloat?,
        paragraphSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        style.paragraphSpacing = paragraphSpacing
        if let tabStopLocation {
            style.tabStops = [NSTextTab(textAlignment: .left, location: tabStopLocation)]
        }
        return style
    }

    private static func effectiveFontWeight(
        _ weight: PlatformFont.Weight,
        bold: Bool = false,
        styleContext: StyleContext
    ) -> PlatformFont.Weight {
        let baseWeight: PlatformFont.Weight = bold ? .bold : weight
        guard styleContext.legibilityWeight == .bold else {
            return baseWeight
        }
        switch baseWeight {
        case .regular: return .semibold
        case .medium, .semibold: return .bold
        default: return .heavy
        }
    }

    private static func pointSize(
        for role: TextRole,
        styleContext: StyleContext
    ) -> CGFloat {
        #if canImport(UIKit) && !os(watchOS)
        let textStyle: UIFont.TextStyle = switch role {
        case .heading(1): .title2
        case .heading(2): .title3
        case .heading(3): .headline
        case .heading: .subheadline
        case .body: .body
        case .footnote: .footnote
        }
        return UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: textStyle,
            compatibleWith: styleContext.traitCollection
        ).pointSize
        #else
        let textStyle: NSFont.TextStyle = switch role {
        case .heading(1): .title2
        case .heading(2): .title3
        case .heading(3): .headline
        case .heading: .subheadline
        case .body: .body
        case .footnote: .footnote
        }
        return NSFont.preferredFont(forTextStyle: textStyle).pointSize
        #endif
    }

    private static func scaledSystemFont(
        role: TextRole,
        weight: PlatformFont.Weight,
        bold: Bool = false,
        monospacedDigits: Bool = false,
        styleContext: StyleContext
    ) -> PlatformFont {
        let size = pointSize(for: role, styleContext: styleContext)
        let effectiveWeight = effectiveFontWeight(
            weight,
            bold: bold,
            styleContext: styleContext
        )
        return monospacedDigits
            ? PlatformFont.monospacedDigitSystemFont(ofSize: size, weight: effectiveWeight)
            : PlatformFont.systemFont(ofSize: size, weight: effectiveWeight)
    }

    private static func scaledMonospacedFont(
        role: TextRole,
        weight: PlatformFont.Weight,
        styleContext: StyleContext
    ) -> PlatformFont {
        let size = pointSize(for: role, styleContext: styleContext)
        return PlatformFont.monospacedSystemFont(
            ofSize: size,
            weight: effectiveFontWeight(weight, styleContext: styleContext)
        )
    }

    private static func applyingItalicTrait(to font: PlatformFont) -> PlatformFont {
        #if canImport(UIKit) && !os(watchOS)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.italic)
        )
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
/// A read-only `UITextView` that provides standard iOS text selection controls
/// (word/range highlighting, draggable grabber handles, and the system edit menu)
/// without scrolling independently or clipping selection handles.
public final class MarkdownSelectableTextView: UITextView {
    public var wrapsText = true
    public var preferredMaxLayoutWidth: CGFloat = 0 {
        didSet {
            if abs(oldValue - preferredMaxLayoutWidth) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    fileprivate var minimumTableWidth: CGFloat {
        guard let attributedText, attributedText.length > 0 else { return 0 }
        var maxTableWidth: CGFloat = 0
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(
            MarkdownText.tableHeaderDividerAttribute,
            in: fullRange
        ) { value, _, _ in
            if let width = value as? CGFloat {
                maxTableWidth = max(maxTableWidth, width)
            }
        }
        return ceil(maxTableWidth)
    }

    public override var intrinsicContentSize: CGSize {
        let targetWidth = wrapsText && preferredMaxLayoutWidth > 0
            ? preferredMaxLayoutWidth
            : CGFloat.greatestFiniteMagnitude
        let measured = sizeThatFits(
            CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        )
        return CGSize(
            width: max(ceil(measured.width), minimumTableWidth),
            height: ceil(measured.height)
        )
    }

    public override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let attributedText, attributedText.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.enumerateAttribute(
            MarkdownText.quoteBarAttribute,
            in: fullRange
        ) { value, range, _ in
            guard value != nil,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end) else { return }
            let rects = selectionRects(for: textRange)
                .map(\.rect)
                .filter { !$0.height.isZero && !$0.height.isInfinite }
            guard let minY = rects.map(\.minY).min(),
                  let maxY = rects.map(\.maxY).max(),
                  maxY > minY else { return }
            let barX = effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? bounds.maxX - 3
                : 0
            let barRect = CGRect(x: barX, y: minY, width: 3, height: maxY - minY)
            UIColor.secondaryLabel.setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: 2).fill()
        }
        attributedText.enumerateAttribute(
            MarkdownText.tableHeaderDividerAttribute,
            in: fullRange
        ) { value, range, _ in
            guard let tableWidth = value as? CGFloat,
                  let start = position(from: beginningOfDocument, offset: range.location),
                  let end = position(from: start, offset: range.length),
                  let textRange = textRange(from: start, to: end) else { return }
            let rects = selectionRects(for: textRange)
                .map(\.rect)
                .filter { !$0.height.isZero && !$0.height.isInfinite }
            guard let maxY = rects.map(\.maxY).max() else { return }
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let thickness = 1 / max(scale, 1)
            let lineRect = CGRect(
                x: 0,
                y: maxY - 6,
                width: max(bounds.width, tableWidth),
                height: thickness
            )
            UIColor.separator.setFill()
            UIRectFill(lineRect)
        }
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange.length > 0 {
            selectedRange = NSRange(location: 0, length: 0)
        }
        return resigned
    }
}

private struct SelectableMarkdownText: UIViewRepresentable {
    let wraps: Bool
    let makeAttributedText: (MarkdownText.StyleContext, LayoutDirection) -> NSAttributedString

    private func resolvedAttributedText(context: Context) -> NSAttributedString {
        makeAttributedText(
            MarkdownText.StyleContext(
                dynamicTypeSize: context.environment.dynamicTypeSize,
                legibilityWeight: context.environment.legibilityWeight
            ),
            context.environment.layoutDirection
        )
    }

    func makeUIView(context: Context) -> MarkdownSelectableTextView {
        let attributedText = resolvedAttributedText(context: context)
        let textView = MarkdownSelectableTextView()
        textView.wrapsText = wraps
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.contentMode = .redraw
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        textView.clipsToBounds = false
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = []
        textView.textDragInteraction?.isEnabled = false
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(
            wraps ? .defaultLow : .required,
            for: .horizontal
        )
        textView.attributedText = attributedText
        textView.accessibilityLabel = attributedText.string
        return textView
    }

    func updateUIView(_ uiView: MarkdownSelectableTextView, context: Context) {
        let attributedText = resolvedAttributedText(context: context)
        uiView.wrapsText = wraps
        uiView.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        if uiView.attributedText != attributedText {
            let previousSelection = uiView.selectedRange
            let previousString = uiView.attributedText.string as NSString
            let nextString = attributedText.string as NSString
            uiView.attributedText = attributedText
            uiView.accessibilityLabel = attributedText.string
            if previousSelection.length > 0,
               NSMaxRange(previousSelection) <= nextString.length,
               previousString.substring(with: previousSelection) == nextString.substring(with: previousSelection) {
                uiView.selectedRange = previousSelection
            } else if uiView.selectedRange.location != 0 || uiView.selectedRange.length != 0 {
                uiView.selectedRange = NSRange(location: 0, length: 0)
            }
            uiView.invalidateIntrinsicContentSize()
            uiView.setNeedsDisplay()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MarkdownSelectableTextView,
        context: Context
    ) -> CGSize? {
        if wraps {
            if let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 {
                uiView.preferredMaxLayoutWidth = proposedWidth
                let measured = uiView.sizeThatFits(
                    CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
                )
                return CGSize(width: proposedWidth, height: ceil(measured.height))
            }
            let fallbackWidth = uiView.preferredMaxLayoutWidth > 0
                ? uiView.preferredMaxLayoutWidth
                : CGFloat.greatestFiniteMagnitude
            let measured = uiView.sizeThatFits(
                CGSize(width: fallbackWidth, height: .greatestFiniteMagnitude)
            )
            return CGSize(
                width: uiView.preferredMaxLayoutWidth > 0 ? fallbackWidth : ceil(measured.width),
                height: ceil(measured.height)
            )
        } else {
            let measured = uiView.sizeThatFits(
                CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            )
            return CGSize(
                width: max(ceil(measured.width), uiView.minimumTableWidth),
                height: ceil(measured.height)
            )
        }
    }
}

#elseif canImport(AppKit)

/// A read-only `NSTextView` that provides standard macOS text selection controls
/// across contiguous Markdown blocks without scrolling independently.
public final class MarkdownSelectableTextView: NSTextView {
    public var wrapsText = true
    public var preferredMaxLayoutWidth: CGFloat = 0 {
        didSet {
            if abs(oldValue - preferredMaxLayoutWidth) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }
    }

    public var attributedText: NSAttributedString {
        get { textStorage ?? NSAttributedString() }
        set {
            textStorage?.setAttributedString(newValue)
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    fileprivate var minimumTableWidth: CGFloat {
        guard let textStorage, textStorage.length > 0 else { return 0 }
        var maxTableWidth: CGFloat = 0
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(
            MarkdownText.tableHeaderDividerAttribute,
            in: fullRange
        ) { value, _, _ in
            if let width = value as? CGFloat {
                maxTableWidth = max(maxTableWidth, width)
            }
        }
        return ceil(maxTableWidth)
    }

    public override var intrinsicContentSize: NSSize {
        let targetWidth = wrapsText && preferredMaxLayoutWidth > 0
            ? preferredMaxLayoutWidth
            : CGFloat.greatestFiniteMagnitude
        return measuredSize(forWidth: targetWidth)
    }

    func measuredSize(forWidth width: CGFloat) -> CGSize {
        guard let textContainer, let layoutManager else { return .zero }
        textContainer.lineFragmentPadding = 0
        let finiteWidth = wrapsText && width.isFinite && width > 0
            && width < CGFloat.greatestFiniteMagnitude
        let targetWidth = finiteWidth ? width : CGFloat.greatestFiniteMagnitude
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(
            width: targetWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let naturalWidth: CGFloat
        if finiteWidth {
            naturalWidth = width
        } else {
            let bounded = attributedText.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).width
            naturalWidth = max(ceil(bounded), minimumTableWidth)
        }
        return CGSize(
            width: naturalWidth,
            height: ceil(used.height)
        )
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if wrapsText, newSize.width > 0, let textContainer {
            textContainer.size = CGSize(
                width: newSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let textStorage,
              let layoutManager,
              let textContainer,
              textStorage.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(
            MarkdownText.quoteBarAttribute,
            in: fullRange
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            guard rect.height > 0 else { return }
            let barX = userInterfaceLayoutDirection == .rightToLeft
                ? bounds.maxX - 3
                : 0
            let barRect = NSRect(
                x: barX,
                y: rect.minY,
                width: 3,
                height: rect.height
            )
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()
        }
        textStorage.enumerateAttribute(
            MarkdownText.tableHeaderDividerAttribute,
            in: fullRange
        ) { value, range, _ in
            guard let tableWidth = value as? CGFloat else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            guard rect.height > 0 else { return }
            let lineRect = NSRect(
                x: 0,
                y: rect.maxY - 6,
                width: max(bounds.width, tableWidth),
                height: 1
            )
            NSColor.separatorColor.setFill()
            lineRect.fill()
        }
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange().length > 0 {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        return resigned
    }
}

private struct SelectableMarkdownText: NSViewRepresentable {
    let wraps: Bool
    let makeAttributedText: (MarkdownText.StyleContext, LayoutDirection) -> NSAttributedString

    private func resolvedAttributedText(context: Context) -> NSAttributedString {
        makeAttributedText(
            MarkdownText.StyleContext(
                dynamicTypeSize: context.environment.dynamicTypeSize,
                legibilityWeight: context.environment.legibilityWeight
            ),
            context.environment.layoutDirection
        )
    }

    func makeNSView(context: Context) -> MarkdownSelectableTextView {
        let attributedText = resolvedAttributedText(context: context)
        let textView = MarkdownSelectableTextView(frame: .zero)
        textView.wrapsText = wraps
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(
            wraps ? .defaultLow : .required,
            for: .horizontal
        )
        textView.attributedText = attributedText
        textView.setAccessibilityLabel(attributedText.string)
        return textView
    }

    func updateNSView(_ nsView: MarkdownSelectableTextView, context: Context) {
        let attributedText = resolvedAttributedText(context: context)
        nsView.wrapsText = wraps
        nsView.isHorizontallyResizable = !wraps
        nsView.textContainer?.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        if nsView.attributedText != attributedText {
            let previousSelection = nsView.selectedRange()
            let previousString = nsView.attributedText.string as NSString
            let nextString = attributedText.string as NSString
            nsView.attributedText = attributedText
            nsView.setAccessibilityLabel(attributedText.string)
            if previousSelection.length > 0,
               NSMaxRange(previousSelection) <= nextString.length,
               previousString.substring(with: previousSelection) == nextString.substring(with: previousSelection) {
                nsView.setSelectedRange(previousSelection)
            } else if nsView.selectedRange().location != 0 || nsView.selectedRange().length != 0 {
                nsView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            nsView.invalidateIntrinsicContentSize()
            nsView.needsDisplay = true
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MarkdownSelectableTextView,
        context: Context
    ) -> CGSize? {
        if wraps {
            if let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 {
                nsView.preferredMaxLayoutWidth = proposedWidth
                return nsView.measuredSize(forWidth: proposedWidth)
            }
            let fallbackWidth = nsView.preferredMaxLayoutWidth > 0
                ? nsView.preferredMaxLayoutWidth
                : CGFloat.greatestFiniteMagnitude
            let measured = nsView.measuredSize(forWidth: fallbackWidth)
            return CGSize(
                width: nsView.preferredMaxLayoutWidth > 0 ? fallbackWidth : measured.width,
                height: measured.height
            )
        } else {
            return nsView.measuredSize(forWidth: CGFloat.greatestFiniteMagnitude)
        }
    }
}
#endif

#endif
