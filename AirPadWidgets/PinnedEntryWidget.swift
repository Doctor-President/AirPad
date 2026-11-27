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

// MARK: - Configuration: pick one entry, and whether it shows while AirPad is locked

// `PinnedEntryIntent`, `PinnedEntryEntity` and `PinnedEntryQuery` live in `AirPad/Widget/PinnedEntryIntent.swift`,
// compiled into the app too, so the app can read each widget's choices (widget fix-up 2).

// MARK: - Timeline

struct PinnedEntryTimelineEntry: TimelineEntry {
    let date: Date
    let state: PinnedEntryMirror.Display
    var font: String = "lato"
    /// widget fix-up 1 — how AirPad unlocks on this phone (the locked tile's glyph); nil = a plain lock.
    var unlock: String? = nil
    /// widget fix-up 2 — the id this widget is configured with (from its own configuration, never from the copy), so a
    /// locked tile can still open its entry once Face ID passes. An id only: no title, no text.
    var chosenID: String? = nil
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
        return Self.resolve(configuration, mirror: mirror)
    }

    func timeline(for configuration: PinnedEntryIntent, in context: Context) async -> Timeline<PinnedEntryTimelineEntry> {
        // No schedule: the app reloads this widget whenever the saved copy changes.
        Timeline(entries: [Self.resolve(configuration, mirror: await Self.readPruned())], policy: .never)
    }

    /// widget fix-up 2 — the locked copy, cut down to the entries of widgets still set to show (a widget switched back to
    /// hidden on the Home Screen, with AirPad not running). Removal only: it never adds an entry. If the system doesn't
    /// answer, the copy is left as it is and AirPad makes the same cut the next time it runs; either way a hidden
    /// widget never reads its entry (`PinnedEntryMirror.display` decides from the widget's own switch).
    static func readPruned() async -> PinnedEntryMirror? {
        guard let m = PinnedEntryMirrorFile.read() else { return nil }
        guard m.locked, !m.entries.isEmpty,
              let show = await PinnedEntryConfigurations.read()?.show else { return m }
        // Re-read: AirPad may have written meanwhile; cut what is there now.
        guard let now = PinnedEntryMirrorFile.read(), now.locked else { return PinnedEntryMirrorFile.read() }
        let cut = now.pruned(keeping: show)
        if cut != now, let data = PinnedEntryMirrorFile.encode(cut) { PinnedEntryMirrorFile.write(data) }
        PinnedEntryConfigurations.debugLog("extension cut: \(now.entries.count) → \(cut.entries.count)")
        return cut
    }

    static func resolve(_ configuration: PinnedEntryIntent, mirror: PinnedEntryMirror?) -> PinnedEntryTimelineEntry {
        let id = configuration.entry?.id
        return .init(date: .now,
                     state: PinnedEntryMirror.display(chosenID: id, showWhenLocked: configuration.showWhenLocked,
                                                      mirror: mirror),
                     font: mirror?.font ?? "lato", unlock: mirror?.unlock, chosenID: id)
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

    /// The tap. An entry opens itself; a locked tile opens the widget's configured entry once Face ID passes (widget
    /// fix-up 2, T 11-27: "it just takes me to the dashboard"): the URL carries the id only.
    private var entryURL: URL? {
        switch timeline.state {
        case .entry(let e), .shownWhileLocked(let e):
            return PinnedEntryMirrorFile.entryURL(for: e.id)
        case .locked, .lockedNotYetShown:
            return timeline.chosenID.flatMap(PinnedEntryMirrorFile.entryURL(for:))
        case .notSetUp, .emptyLibrary, .notChosen, .missing:
            return nil
        }
    }

    @ViewBuilder private var content: some View {
        switch timeline.state {
        case .entry(let e): entryView(e)
        // widget fix-up 2 — shown while AirPad is locked (this widget's switch): privacy-sensitive, so the system can
        // hide it while the phone itself is locked. Only here: with AirPad's lock off the entry is never marked.
        case .shownWhileLocked(let e): entryView(e).privacySensitive()
        case .lockedNotYetShown:       notYetShownView
        case .notSetUp:     message("square.and.pencil", "Open AirPad", "Then this widget can show an entry.")
        case .locked:       lockedView
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

    /// widget fix-up 1 (T, ruling 1) — "AirPad is locked", with the system glyph for how it unlocks (Face ID, Touch ID,
    /// Optic ID; a plain lock when not known) above the words, so the tile says how to get in. Read as one sentence.
    private var lockedView: some View {
        message(PinnedEntryMirror.unlockSymbol(timeline.unlock), "AirPad is locked", "Open AirPad to read your entries.",
                symbolSize: 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(PinnedEntryMirror.lockedAccessibilityLabel(timeline.unlock)))
    }

    /// widget fix-up 2 — set to show, but its entry isn't in the locked copy yet: the locked tile, saying what to do.
    private var notYetShownView: some View {
        message(PinnedEntryMirror.unlockSymbol(timeline.unlock), "AirPad is locked", "Open AirPad to show this entry.",
                symbolSize: 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(PinnedEntryMirror.notYetShownAccessibilityLabel(timeline.unlock)))
    }

    private func message(_ symbol: String, _ title: String, _ detail: String, symbolSize: CGFloat = 18) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .regular))
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
