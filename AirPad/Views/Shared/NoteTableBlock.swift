import SwiftUI
import UIKit

// MARK: - 1.1-C (C6) — a table inside a note
//
// Storage: GFM pipe lines in the note's Markdown (`TableConverter.gfm`). Display: ONE attachment character on its own
// line (`NoteTableAttachment`), tagged `.airpadTableID`, the checklist / inline-image codec pattern. Under TextKit 2 the
// attachment hosts a live view (chat's table: its own body, sideways scroll, edge fade); under TextKit 1 it draws a
// static render of the same view (scrolling then happens in the full-screen view). A tap (or the corner button) opens
// `NoteTableEditorView`, full screen, where cells are edited and rows / columns added or deleted.

extension NSAttributedString.Key {
    /// The table attachment's id (one per decode / insert) — how an edit finds its block again.
    static let airpadTableID = NSAttributedString.Key("airpadTableID")
}

extension Notification.Name {
    /// Posted by a table block when tapped; `object` is the table id. The editor holding it presents the editor.
    static let noteTableOpen = Notification.Name("airpad.noteTableOpen")
}

final class NoteTableAttachment: NSTextAttachment {
    let tableID: String
    let table: MarkdownTable

    init(table: MarkdownTable, tableID: String = UUID().uuidString) {
        self.table = table
        self.tableID = tableID
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false   // drawn as an image (see image(for:…))
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Size — the chat grid's own measure at the note's width.

    static var bodyFont: EntryBodyFont {
        EntryBodyFont(rawValue: UserDefaults.standard.string(forKey: EntryBodyFont.defaultStorageKey) ?? "") ?? .fallback
    }

    /// The block's height at `width`: the corner button row + the grid at full height (as in an answer).
    static func height(for table: MarkdownTable, width: CGFloat) -> CGFloat {
        let t = ChatTable(headers: table.headers, rows: table.rows)
        let f = bodyFont
        let cell = f.uiFont(size: ChatTableView.cellSize), head = f.uiFont(size: ChatTableView.cellSize, weight: .semibold)
        let widths = ChatTable.fill(t.columnWidths(font: head, padding: 20), to: max(width, 1))
        let h = t.rowHeights(font: cell, widths: widths, header: head, padding: 20, vPadding: 14)
        return 30 + 4 + h.header + h.rows.reduce(0, +) + CGFloat(t.rows.count) * 0.5 + 1 + 6
    }

    func bounds(width: CGFloat) -> CGRect {
        let w = max(width, 1)
        return CGRect(x: 0, y: 0, width: w, height: Self.height(for: table, width: w))
    }

    // TextKit 2
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        bounds(width: proposedLineFragment.width)
    }

    /// The block as drawn in the note: a static render of chat's table at the text width (the trailing edge fades where
    /// the grid is wider), cached per width and appearance. A tap on it opens the full-screen table view (the editor's tap
    /// recognizer), which is where it scrolls sideways. TextKit 2 API only: overriding the TextKit 1 attachment methods
    /// switches UITextView into TextKit 1 compatibility mode. (A live view through NSTextAttachmentViewProvider came up
    /// unsized / as the system file placeholder inside this editor, so the block is an image.)
    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> UIImage? {
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let key = "\(Int(bounds.width))x\(Int(bounds.height))-\(dark)"
        if let c = cache, c.key == key { return c.image }
        let img: UIImage? = MainActor.assumeIsolated {
            let r = ImageRenderer(content: NoteTableBlockView(table: table, width: bounds.width)
                .environment(\.appBodyFont, Self.bodyFont)
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading))
            r.scale = UIScreen.main.scale
            return r.uiImage
        }
        cache = img.map { (key, $0) }
        return img
    }
    private var cache: (key: String, image: UIImage)?
}

struct NoteTableBlockView: View {
    let table: MarkdownTable
    let width: CGFloat

    @Environment(\.appBodyFont) private var appFont
    private static let hPad: CGFloat = 10, vPad: CGFloat = 7, fade: CGFloat = 28

    // Chat's table look (cells, header, rules, the corner expand mark, the edge fade), drawn as one static grid.
    var body: some View {
        let t = ChatTable(headers: table.headers, rows: table.rows)
        let cellFont = appFont.uiFont(size: ChatTableView.cellSize), headFont = appFont.uiFont(size: ChatTableView.cellSize, weight: .semibold)
        let widths = ChatTable.fill(t.columnWidths(font: headFont, padding: Self.hPad * 2), to: width)
        let heights = t.rowHeights(font: cellFont, widths: widths, header: headFont, padding: Self.hPad * 2, vPadding: Self.vPad * 2)
        let cut = widths.reduce(0, +) > width + 1
        VStack(alignment: .trailing, spacing: 4) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatTypography.bodyText)
                .frame(width: 30, height: 30)
                .background(AppearancePalette.ink.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(AppearancePalette.ink.opacity(0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 0) {
                row(t.headers, widths: widths, height: heights.header, header: true)
                Rectangle().fill(ChatTypography.secondaryText.opacity(0.6)).frame(height: 1)
                ForEach(t.rows.indices, id: \.self) { i in
                    row(t.rows[i], widths: widths, height: heights.rows[i], header: false)
                    Rectangle().fill(ChatTypography.secondaryText.opacity(0.3)).frame(height: 0.5)
                }
            }
            .frame(width: width, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, cut ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                }
            }
        }
        .frame(width: width, alignment: .topTrailing)
    }

    private func row(_ cells: [String], widths: [CGFloat], height: CGFloat, header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { c in
                Text(MarkdownPlain.styled(cells[c]))
                    .font(appFont.font(size: ChatTableView.cellSize, weight: header ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(header ? ChatTypography.headingText : ChatTypography.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.hPad).padding(.vertical, Self.vPad)
                    .frame(width: widths[c], height: height, alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension MarkdownCodec {
    /// One attachment character for a table, tagged with a fresh id.
    static func tableAttachmentString(_ table: MarkdownTable, tableID: String = UUID().uuidString) -> NSAttributedString {
        let mut = NSMutableAttributedString(attributedString: NSAttributedString(attachment: NoteTableAttachment(table: table, tableID: tableID)))
        let range = NSRange(location: 0, length: mut.length)
        mut.addAttribute(.airpadTableID, value: tableID, range: range)
        mut.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: range)
        return mut
    }

    /// The table a run of the display text carries (its attachment), if any.
    static func table(in attrs: [NSAttributedString.Key: Any]) -> MarkdownTable? {
        guard attrs[.airpadTableID] != nil else { return nil }
        return (attrs[.attachment] as? NoteTableAttachment)?.table
    }
}

// MARK: - Full-screen table view (edit cells · add / delete row and column)

struct NoteTableEditorView: View {
    @State var table: MarkdownTable
    /// nil = delete the table.
    let onDone: (MarkdownTable?) -> Void
    let onCancel: () -> Void

    @Environment(\.appBodyFont) private var appFont
    @State private var selected: (row: Int, col: Int) = (-1, 0)   // row −1 = the header
    @State private var confirmDelete = false
    @FocusState private var focus: Cell?

    struct Cell: Hashable { let row: Int; let col: Int }

    private static let colWidth: CGFloat = 150

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    rowView(-1)
                    Rectangle().fill(AppearancePalette.ink.opacity(0.35)).frame(height: 1)
                    ForEach(table.rows.indices, id: \.self) { r in
                        rowView(r)
                        Rectangle().fill(AppearancePalette.ink.opacity(0.15)).frame(height: 0.5)
                    }
                }
                .padding(16)
            }
            .background(AppearancePalette.bgBase)
            .navigationTitle("Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.accessibilityIdentifier("tableEditor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(table) }.fontWeight(.semibold).accessibilityIdentifier("tableEditor.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Delete table", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("tableEditor.more")
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Add after / delete the selected cell's row and column (the header row stays).
                HStack(spacing: 10) {
                    bar("Row", "plus", id: "tableEditor.addRow") { insertRow(at: selected.row + 1) }
                    bar("Column", "plus", id: "tableEditor.addColumn") { insertColumn(at: selected.col + 1) }
                    Spacer(minLength: 0)
                    bar("Row", "minus", id: "tableEditor.deleteRow") { deleteRow(selected.row) }
                        .disabled(selected.row < 0 || table.rows.isEmpty)
                    bar("Column", "minus", id: "tableEditor.deleteColumn") { deleteColumn(selected.col) }
                        .disabled(table.columnCount <= 1)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
            }
            .confirmationDialog("Delete this table?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete table", role: .destructive) { onDone(nil) }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { if table.isEmpty { focus = Cell(row: -1, col: 0) } }
        .onChange(of: focus) { _, f in if let f { selected = (f.row, f.col) } }
    }

    private func bar(_ title: String, _ icon: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(appFont.font(size: 15, weight: .medium)) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
    }

    private func rowView(_ r: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { c in
                TextField(r < 0 ? "Heading" : "", text: binding(r, c), axis: .vertical)
                    .font(appFont.font(size: 16, weight: r < 0 ? .semibold : .regular))
                    .foregroundStyle(AppearancePalette.ink)
                    .focused($focus, equals: Cell(row: r, col: c))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(width: Self.colWidth, alignment: .topLeading)
                    .background(selected.row == r && selected.col == c ? AppearancePalette.ink.opacity(0.06) : .clear)
                    .overlay(alignment: .trailing) { Rectangle().fill(AppearancePalette.ink.opacity(0.12)).frame(width: 0.5) }
                    .accessibilityIdentifier("tableCell-\(r)-\(c)")
            }
        }
    }

    private func binding(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(get: {
            r < 0 ? (c < table.headers.count ? table.headers[c] : "") : (c < table.rows[r].count ? table.rows[r][c] : "")
        }, set: { v in
            if r < 0 { table.headers[c] = v } else { table.rows[r][c] = v }
            selected = (r, c)
        })
    }

    private func insertRow(at i: Int) {
        let at = min(max(i, 0), table.rows.count)
        table.rows.insert(Array(repeating: "", count: table.columnCount), at: at)
        selected = (at, selected.col); focus = Cell(row: at, col: max(selected.col, 0))
    }
    private func insertColumn(at i: Int) {
        let at = min(max(i, 0), table.columnCount)
        table.headers.insert("", at: at)
        for r in table.rows.indices { table.rows[r].insert("", at: at) }
        selected = (selected.row, at); focus = Cell(row: selected.row, col: at)
    }
    private func deleteRow(_ r: Int) {
        guard r >= 0, r < table.rows.count else { return }
        table.rows.remove(at: r)
        selected = (min(r, table.rows.count - 1), selected.col)
    }
    private func deleteColumn(_ c: Int) {
        guard table.columnCount > 1, c >= 0, c < table.columnCount else { return }
        table.headers.remove(at: c)
        for r in table.rows.indices { table.rows[r].remove(at: c) }
        selected = (selected.row, min(c, table.columnCount - 1))
    }
}
