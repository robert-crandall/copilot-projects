import SwiftUI

struct MarkdownListItem: Equatable {
    let marker: String
    let text: String
    let depth: Int
}

enum MarkdownColumnAlignment: Equatable {
    case leading
    case center
    case trailing
}

struct MarkdownTable: Equatable {
    let header: [String]
    let alignments: [MarkdownColumnAlignment]
    let rows: [[String]]
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(String)
    case quote(String)
    case list([MarkdownListItem])
    case table(MarkdownTable)
}

enum MarkdownParser {
    private static let maximumRenderedBytes = 256 * 1_024
    private static let maximumRenderedLines = 500
    private static let maximumRenderedPipes = 1_000
    private static let maximumInlineMarkers = 2_000

    static func isWithinRenderingLimits(_ text: String) -> Bool {
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
            } else if character == "*" || character == "_" || character == "~" || character == "`" {
                // Bounds inline-formatting complexity (bold/italic/strikethrough/code
                // spans). Without this, a large run of tiny delimited spans (e.g.
                // "**x** " repeated tens of thousands of times) stays under the byte,
                // line, and pipe caps yet still expands into tens of thousands of
                // AttributedString formatting runs, which can stall the desktop
                // drawer. Falling back to the plain-text renderer here matches the
                // bounded remote web renderer's inline node/scan budget.
                inlineMarkers += 1
                if inlineMarkers > maximumInlineMarkers { return false }
            }
        }
        return true
    }

    static func blocks(from text: String) -> [MarkdownBlock] {
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
                      !isClosingFence(
                        lines[index].trimmingCharacters(in: .whitespaces),
                        fence
                      ) {
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
                              !isBlockStart(
                                current.trimmingCharacters(in: .whitespaces)
                              ) {
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

    private static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func fenceLength(_ line: String) -> Int? {
        let ticks = line.prefix { $0 == "`" }.count
        return ticks >= 3 ? ticks : nil
    }

    private static func isClosingFence(_ line: String, _ openLength: Int) -> Bool {
        guard !line.isEmpty, line.allSatisfy({ $0 == "`" }) else { return false }
        return line.count >= openLength
    }

    private static func headingLevel(_ line: String) -> Int? {
        var hashes = 0
        for character in line {
            if character == "#" {
                hashes += 1
            } else {
                break
            }
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

    static func splitTableRow(_ line: String) -> [String] {
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

    static func tableDelimiterAlignments(
        _ line: String
    ) -> [MarkdownColumnAlignment]? {
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

struct MarkdownText: View {
    let text: String

    @ViewBuilder
    var body: some View {
        if !MarkdownParser.isWithinRenderingLimits(text) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let blocks = MarkdownParser.blocks(from: text)
            if blocks.allSatisfy({
                if case .paragraph = $0 { return true }
                return false
            }) {
                Text(inline(text))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(accessibilityHeadingLevel(for: level))
        case let .paragraph(text):
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .codeBlock(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary)
                    .frame(width: 3)
                Text(inline(text))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(inline(item.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, CGFloat(min(item.depth, 6)) * 14)
                }
            }
        case let .table(table):
            tableView(table)
        }
    }

    @ViewBuilder
    private func tableView(_ table: MarkdownTable) -> some View {
        let columns = table.header.count
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(inline(table.header[column]), table.alignments, column)
                            .fontWeight(.semibold)
                    }
                }
                Divider().gridCellColumns(max(columns, 1))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(
                                inline(column < row.count ? row[column] : ""),
                                table.alignments,
                                column
                            )
                        }
                    }
                }
            }
            .padding(10)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func cell(
        _ content: AttributedString,
        _ alignments: [MarkdownColumnAlignment],
        _ column: Int
    ) -> some View {
        Text(content)
            .frame(maxWidth: 280, alignment: .leading)
            .gridColumnAlignment(horizontalAlignment(alignments, column))
            .multilineTextAlignment(textAlignment(alignments, column))
    }

    private func horizontalAlignment(
        _ alignments: [MarkdownColumnAlignment],
        _ column: Int
    ) -> HorizontalAlignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(
        _ alignments: [MarkdownColumnAlignment],
        _ column: Int
    ) -> TextAlignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }

    private func accessibilityHeadingLevel(for level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(string)
    }
}
