import SwiftUI
import UIKit

/// live-26 (3f) — a Markdown table in any model's answer, as a TABLE. T (device, TF 202610171546): a 5-column, 46-row table
/// came out as stacked records ("#: 44 / President: … / Party: …" per row). That was deliberate (2026-07-29, ws-instant-
/// search: "REFLOW, not Grid … revisit if column comparison matters"), not a parse miss; T's report reverses it.
/// The cells are normalised here: every row has exactly the header's cell count (a short row padded with empty cells,
/// a long row's extra cells kept in its last), so a ragged row lines up instead of dropping to a joined line.
struct ChatTable: Equatable {
    let headers: [String]
    let rows: [[String]]

    init(headers: [String], rows: [[String]]) {
        let n = max(headers.count, 1)
        self.headers = headers.isEmpty ? [""] : headers
        self.rows = rows.map { r in
            if r.count == n { return r }
            if r.count < n { return r + Array(repeating: "", count: n - r.count) }
            return Array(r.prefix(n - 1)) + [r.dropFirst(n - 1).joined(separator: " | ")]
        }
    }

    /// The table as GitHub Markdown (Copy as Markdown). Pipes inside a cell are escaped.
    var markdown: String {
        func line(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        return ([line(headers), "|" + headers.map { _ in " --- " }.joined(separator: "|") + "|"] + rows.map(line))
            .joined(separator: "\n")
    }

    /// The table as CSV (RFC 4180: a cell with a comma, quote or line break is quoted, its quotes doubled). Cells are
    /// plain text (the inline Markdown dropped).
    var csv: String {
        func field(_ s: String) -> String {
            let t = MarkdownPlain.inline(s)
            return t.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : t
        }
        return ([headers] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n")
    }

    /// VoiceOver reads a row as a record — "column: value", empty cells skipped. Never the visual.
    func spokenRow(_ i: Int) -> String {
        zip(headers, rows[i]).compactMap { h, v in
            let value = MarkdownPlain.inline(v)
            guard !value.isEmpty else { return nil }
            let head = MarkdownPlain.inline(h)
            return head.isEmpty ? value : "\(head): \(value)"
        }.joined(separator: ", ")
    }

    /// Each column's width: its widest cell (plain text, one line, at `font`) plus the cell padding, between `minWidth`
    /// and `maxWidth` — a longer cell wraps inside its column.
    func columnWidths(font: UIFont, minWidth: CGFloat = 44, maxWidth: CGFloat = 220, padding: CGFloat = 20) -> [CGFloat] {
        (0..<headers.count).map { c in
            let cells = [headers[c]] + rows.map { $0[c] }
            let widest = cells.map { (MarkdownPlain.inline($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            return min(max(ceil(widest) + padding, minWidth), maxWidth)
        }
    }

    /// Each row's height when its cells wrap inside `widths` (the tallest cell), plus the vertical padding.
    func rowHeights(font: UIFont, widths: [CGFloat], header headerFont: UIFont, padding: CGFloat = 20, vPadding: CGFloat = 14) -> (header: CGFloat, rows: [CGFloat]) {
        func h(_ cells: [String], _ f: UIFont) -> CGFloat {
            zip(cells, widths).map { cell, w in
                ceil((MarkdownPlain.inline(cell) as NSString).boundingRect(
                    with: CGSize(width: max(w - padding, 1), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: f], context: nil).height)
            }.max().map { $0 + vPadding } ?? vPadding
        }
        return (h(headers, headerFont), rows.map { h($0, font) })
    }
}

/// How a table block renders in an answer.
enum ChatTablePresentation { case grid, stackedRecords }

/// The grid: a header row, hairline row dividers, tabular numerals, cells wrapping inside their column. Wider than the
/// panel → it scrolls sideways inside the answer with the header row and the first column staying put; taller than
/// `maxHeight` → it scrolls down inside its frame, the header staying put. Never wider than the panel. A tap opens it
/// full screen (`ChatTableFullScreen`: landscape, Copy as Markdown / CSV). VoiceOver reads each row as a record.
struct ChatTableView: View {
    let table: ChatTable
    var maxHeight: CGFloat? = 380
    var opensFullScreen = true

    @Environment(\.appBodyFont) private var appFont
    @State private var offset: CGPoint = .zero
    @State private var showFull = false

    static let cellSize: CGFloat = 16
    private static let hPad: CGFloat = 10, vPad: CGFloat = 7

    var body: some View {
        let cellFont = appFont.uiFont(size: Self.cellSize), headFont = appFont.uiFont(size: Self.cellSize, weight: .semibold)
        let widths = table.columnWidths(font: headFont, padding: Self.hPad * 2)
        let heights = table.rowHeights(font: cellFont, widths: widths, header: headFont, padding: Self.hPad * 2, vPadding: Self.vPad * 2)
        let total = heights.header + heights.rows.reduce(0, +) + CGFloat(table.rows.count) * 0.5
        let sticky = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hexString: "141414")) : UIColor(Color(hexString: "FBF9F5")) })
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(table.rows.indices, id: \.self) { i in
                        row(table.rows[i], widths: widths, height: heights.rows[i], header: false, sticky: sticky)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(table.spokenRow(i))
                        Rectangle().fill(ChatTypography.secondaryText.opacity(0.3)).frame(height: 0.5)
                    }
                } header: {
                    VStack(spacing: 0) {
                        row(table.headers, widths: widths, height: heights.header, header: true, sticky: sticky)
                        Rectangle().fill(ChatTypography.secondaryText.opacity(0.6)).frame(height: 1)
                    }
                    .background(sticky)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Table, \(table.rows.count) rows. Columns: \(table.headers.map { MarkdownPlain.inline($0) }.joined(separator: ", "))")
                }
            }
        }
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, new in offset = new }
        .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: maxHeight.map { min(total + 1, $0) })
        .contentShape(Rectangle())
        .onTapGesture { if opensFullScreen { showFull = true } }
        .accessibilityAction(named: "Open the table full screen") { if opensFullScreen { showFull = true } }
        .accessibilityIdentifier("chatTable")
        .fullScreenCover(isPresented: $showFull) { ChatTableFullScreen(table: table) }
    }

    /// One row: the first cell rides the horizontal scroll back (`offset.x`) so the first column stays put; the others
    /// slide under it.
    private func row(_ cells: [String], widths: [CGFloat], height: CGFloat, header: Bool, sticky: Color) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { c in
                cell(cells[c], width: widths[c], height: height, header: header)
                    .background(c == 0 ? sticky : .clear)
                    .offset(x: c == 0 ? max(offset.x, 0) : 0)
                    .zIndex(c == 0 ? 1 : 0)
            }
        }
    }

    private func cell(_ text: String, width: CGFloat, height: CGFloat, header: Bool) -> some View {
        Text(MarkdownPlain.styled(text))
            .font(appFont.font(size: Self.cellSize, weight: header ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(header ? ChatTypography.headingText : ChatTypography.bodyText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.hPad).padding(.vertical, Self.vPad)
            .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// The table full screen: the same grid, the whole screen; Copy as Markdown / CSV. The app is portrait-only, so when the
/// phone turns the viewer lays the table out sideways itself (the device orientation, so the rotation lock still applies).
struct ChatTableFullScreen: View {
    let table: ChatTable
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?
    @State private var turn: Double = 0   // 0 · 90 (landscape left) · -90 (landscape right)

    var body: some View {
        GeometryReader { geo in
            let sideways = turn != 0
            content
                .frame(width: sideways ? geo.size.height : geo.size.width, height: sideways ? geo.size.width : geo.size.height)
                .rotationEffect(.degrees(turn))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(edges: turn != 0 ? .all : [])
        .statusBarHidden(turn != 0)
        .animation(.easeInOut(duration: 0.3), value: turn)
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications(); turn = Self.turn(UIDevice.current.orientation, was: 0) }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            turn = Self.turn(UIDevice.current.orientation, was: turn)
        }
    }

    /// Landscape left → the table turns 90°, right → −90°, portrait → upright; face up / down keep the last.
    static func turn(_ o: UIDeviceOrientation, was: Double) -> Double {
        switch o {
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .portrait, .portraitUpsideDown: return 0
        default: return was
        }
    }

    private var content: some View {
        NavigationStack {
            ChatTableView(table: table, maxHeight: nil, opensFullScreen: false)
                .padding(.horizontal, 12)
                .navigationTitle("\(table.rows.count) rows · \(table.headers.count) columns")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Copy as Markdown") { UIPasteboard.general.string = table.markdown; copied = "Markdown" }
                            Button("Copy as CSV") { UIPasteboard.general.string = table.csv; copied = "CSV" }
                        } label: { Label(copied.map { "Copied \($0)" } ?? "Copy", systemImage: "doc.on.doc") }
                        .accessibilityIdentifier("chatTableCopy")
                    }
                }
        }
        .accessibilityIdentifier("chatTableFullScreen")
    }
}
