import WidgetKit
import SwiftUI
import AppIntents

// MARK: - ws-1.0-widget — "Pinned Entry", a Home Screen widget (small + medium)

/// The user adds the widget, touches and holds, chooses Edit Widget and picks one entry (search + recent entries).
/// The widget shows the entry's title and first lines; a checklist shows its rows with their ticked state (read-only).
/// Tapping opens that entry in AirPad. Everything it shows comes from the app's saved copy (`PinnedEntryMirror`); the
/// widget never opens the library, makes no model call and uses no network.
struct PinnedEntryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: PinnedEntryMirrorFile.widgetKind,
                               intent: PinnedEntryIntent.self,
                               provider: PinnedEntryProvider()) { timeline in
            PinnedEntryView(timeline: timeline)
        }
        .configurationDisplayName("Pinned Entry")
        .description("Keep one entry on your Home Screen. Tap it to open the entry in AirPad.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Configuration: pick one entry

struct PinnedEntryIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pinned Entry"
    static let description = IntentDescription("Choose the entry this widget shows.")

    @Parameter(title: "Entry")
    var entry: PinnedEntryEntity?

    init() {}
    init(entry: PinnedEntryEntity?) { self.entry = entry }
}

struct PinnedEntryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Entry"
    static let defaultQuery = PinnedEntryQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// The picker: suggestions = the most recently changed entries; search = title and first line. Reads the saved copy
/// only. A saved choice whose entry is gone still resolves (so the widget can say it is gone instead of silently
/// falling back to "choose an entry").
struct PinnedEntryQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PinnedEntryEntity] {
        let byID = Dictionary((PinnedEntryMirrorFile.read()?.entries ?? []).map { ($0.id, $0.title) },
                              uniquingKeysWith: { a, _ in a })
        return identifiers.map { PinnedEntryEntity(id: $0, title: byID[$0] ?? "Unavailable entry") }
    }

    func entities(matching string: String) async throws -> [PinnedEntryEntity] {
        (PinnedEntryMirrorFile.read()?.search(string) ?? []).map { PinnedEntryEntity(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [PinnedEntryEntity] {
        (PinnedEntryMirrorFile.read()?.suggestions() ?? []).map { PinnedEntryEntity(id: $0.id, title: $0.title) }
    }
}

// MARK: - Timeline

struct PinnedEntryTimelineEntry: TimelineEntry {
    let date: Date
    let state: PinnedEntryMirror.Display
    var font: String = "lato"
}

struct PinnedEntryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PinnedEntryTimelineEntry {
        PinnedEntryTimelineEntry(date: .now, state: .entry(.init(
            id: "placeholder", title: "Pinned entry", updatedAt: .now,
            lines: [.init(kind: .check, done: true, text: "First thing"),
                    .init(kind: .check, done: false, text: "Second thing"),
                    .init(kind: .check, done: false, text: "Third thing")])))
    }

    func snapshot(for configuration: PinnedEntryIntent, in context: Context) async -> PinnedEntryTimelineEntry {
        let mirror = PinnedEntryMirrorFile.read()
        // The gallery preview (nothing chosen yet) shows the most recent entry rather than an instruction.
        if context.isPreview, configuration.entry == nil, let m = mirror, !m.locked, let first = m.entries.first {
            return PinnedEntryTimelineEntry(date: .now, state: .entry(first), font: m.font)
        }
        return Self.resolve(configuration.entry?.id, mirror: mirror)
    }

    func timeline(for configuration: PinnedEntryIntent, in context: Context) async -> Timeline<PinnedEntryTimelineEntry> {
        // No schedule: the app reloads this widget whenever the saved copy changes.
        Timeline(entries: [Self.resolve(configuration.entry?.id, mirror: PinnedEntryMirrorFile.read())], policy: .never)
    }

    static func resolve(_ chosenID: String?, mirror: PinnedEntryMirror?) -> PinnedEntryTimelineEntry {
        .init(date: .now, state: PinnedEntryMirror.display(chosenID: chosenID, mirror: mirror),
              font: mirror?.font ?? "lato")
    }
}

// MARK: - Views

struct PinnedEntryView: View {
    let timeline: PinnedEntryTimelineEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    private var type: PinnedEntryType { PinnedEntryType(raw: timeline.font) }
    /// Full colour uses AirPad's own surfaces; tinted / clear let the system colour the text.
    private var fullColor: Bool { renderingMode == .fullColor }
    private var ink: Color { fullColor ? (colorScheme == .dark ? WidgetPalette.inkDark : WidgetPalette.inkLight) : .primary }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                colorScheme == .dark ? WidgetPalette.surfaceDark : WidgetPalette.surfaceLight
            }
            .widgetURL(entryURL)
    }

    private var entryURL: URL? {
        guard case .entry(let e) = timeline.state else { return nil }
        return PinnedEntryMirrorFile.entryURL(for: e.id)
    }

    @ViewBuilder private var content: some View {
        switch timeline.state {
        case .entry(let e): entryView(e)
        case .notSetUp:     message("square.and.pencil", "Open AirPad", "Then this widget can show an entry.")
        case .locked:       message("lock.fill", "AirPad is locked", "Open AirPad to read your entries.")
        case .emptyLibrary: message("square.and.pencil", "Nothing to pin yet", "Add an entry in AirPad.")
        case .notChosen:    message("pin", "Pin an entry", "Touch and hold, then choose Edit Widget.")
        case .missing:      message("questionmark.square.dashed", "Entry not found",
                                    "It was deleted or made private. Touch and hold to choose another.")
        }
    }

    /// Rows that fit: the title takes the top; small and medium are the same height.
    private var rowBudget: Int { 5 }

    private func entryView(_ e: PinnedEntryMirror.Entry) -> some View {
        let total = e.lines.count + e.more
        let overflow = total > rowBudget
        let shown = overflow ? Array(e.lines.prefix(rowBudget - 1)) : e.lines
        return VStack(alignment: .leading, spacing: 5) {
            Text(e.title)
                .font(type.title(size: family == .systemSmall ? 15 : 16))
                .foregroundStyle(ink)
                .lineLimit(family == .systemSmall ? 2 : 1)
                .widgetAccentable()
                .padding(.bottom, 2)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                row(line)
            }
            if overflow {
                Text("+\(total - shown.count) more")
                    .font(type.body(size: 12))
                    .foregroundStyle(ink.opacity(0.55))
            }
        }
    }

    @ViewBuilder private func row(_ line: PinnedEntryMirror.Line) -> some View {
        switch line.kind {
        case .check:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: line.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(ink.opacity(line.done ? 0.5 : 0.85))
                    .widgetAccentable()
                Text(line.text)
                    .font(type.body(size: 13))
                    .foregroundStyle(ink.opacity(line.done ? 0.5 : 0.9))
                    .strikethrough(line.done, color: ink.opacity(0.4))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text((line.done ? "Done: " : "Not done: ") + line.text))
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(type.body(size: 13)).foregroundStyle(ink.opacity(0.6))
                Text(line.text).font(type.body(size: 13)).foregroundStyle(ink.opacity(0.9)).lineLimit(1)
            }
        case .heading:
            Text(line.text).font(type.title(size: 13)).foregroundStyle(ink).lineLimit(1)
        case .text:
            Text(line.text).font(type.body(size: 13)).foregroundStyle(ink.opacity(0.9)).lineLimit(1)
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(ink.opacity(0.7))
                .widgetAccentable()
            Spacer(minLength: 0)
            Text(title)
                .font(type.title(size: 15))
                .foregroundStyle(ink)
                .widgetAccentable()
            Text(detail)
                .font(type.body(size: 12))
                .foregroundStyle(ink.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// AirPad's surfaces (AppearancePalette: the raised note panel `bgElevated` + `ink`), in hex.
enum WidgetPalette {
    static let surfaceLight = Color(red: 0xFB / 255, green: 0xF9 / 255, blue: 0xF5 / 255)   // #FBF9F5 (L2 elevated)
    static let surfaceDark  = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0D / 255)   // #0D0D0D (bgElevated dark)
    static let inkLight     = Color(red: 0x23 / 255, green: 0x2A / 255, blue: 0x2E / 255)   // #232A2E
    static let inkDark      = Color.white                                                    // #FFFFFF
}

/// The app's chosen content face (Settings → Font), as the widget can draw it: Lato and Source Serif 4 are bundled
/// in the extension; SF Pro and New York are the system's.
struct PinnedEntryType {
    enum Face { case lato, sourceSerif4, sfPro, newYork }
    let face: Face

    init(raw: String) {
        switch raw {
        case "sourceSerif4": face = .sourceSerif4
        case "sfPro":        face = .sfPro
        case "newYork":      face = .newYork
        default:             face = .lato
        }
    }

    func title(size: CGFloat) -> Font {
        switch face {
        case .lato:         return .custom("Lato-Bold", size: size)
        case .sourceSerif4: return .custom("SourceSerif4-Bold", size: size)
        case .sfPro:        return .system(size: size, weight: .semibold)
        case .newYork:      return .system(size: size, weight: .semibold, design: .serif)
        }
    }

    func body(size: CGFloat) -> Font {
        switch face {
        case .lato:         return .custom("Lato-Regular", size: size)
        case .sourceSerif4: return .custom("SourceSerif4-Semibold", size: size)   // the note body's weight
        case .sfPro:        return .system(size: size)
        case .newYork:      return .system(size: size, design: .serif)
        }
    }
}
