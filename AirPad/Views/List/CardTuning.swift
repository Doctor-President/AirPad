// CardTuning.swift
// DEBUG tuning for the two full-card presentations that share NodeCardView:
// the Cover Flow carousel and the vertical-scroll stack. ONE panel, with a
// Carousel / Vertical toggle so each dial carries a per-presentation value
// (they differ for height + spacing; hero-zone / font / opacity default the
// same but can diverge). Mirrors the CoverFlow tuning-panel pattern
// (draggable widget, param chip, single slider, copy-values).
//
// CRITICAL: every default here reproduces the value currently baked into the
// live code, and the surfaces read these dials via @AppStorage in ALL builds
// (only the PANEL is #if DEBUG). So Release renders pixel-identical to before
// this file existed — the dials just expose those constants for tuning. Copy
// Values dumps all ten numbers so a good pass can be baked back as defaults.

import SwiftUI

// MARK: - Model

enum CardPresentation: String, CaseIterable {
    case carousel
    case vertical
    var label: String { self == .carousel ? "Carousel" : "Vertical" }
}

enum CardDial: String, CaseIterable {
    case height        // per-view height multiplier (carousel: ×cardWidth; vertical: ×screenWidth)
    case heroZone      // hero-band fraction of card height (NodeCardView)
    case fontScale     // multiplier on NodeCardView's editorial font sizes
    case textOpacity   // multiplier on NodeCardView's editorial text
    case spacing       // inter-card spacing (carousel: negative overlap; vertical: gap)

    var label: String {
        switch self {
        case .height:      return "Card height"
        case .heroZone:    return "Hero-zone height"
        case .fontScale:   return "Font size"
        case .textOpacity: return "Text opacity"
        case .spacing:     return "Inter-card spacing"
        }
    }
    var exportLabel: String { "card_\(rawValue)" }

    var range: ClosedRange<Double> {
        switch self {
        case .height:      return 0.6...3.0
        case .heroZone:    return 0.0...0.9
        case .fontScale:   return 0.6...2.0
        case .textOpacity: return 0.2...1.0
        case .spacing:     return -140...80
        }
    }
    var step: Double {
        switch self {
        case .height, .fontScale: return 0.01
        case .heroZone, .textOpacity: return 0.01
        case .spacing: return 2
        }
    }
    var format: String {
        switch self {
        case .spacing: return "%.0f"
        default:       return "%.2f"
        }
    }
}

/// Key resolution. Carousel spacing REUSES the existing `CoverFlowKey.cardSpacing`
/// so the carousel geometry tuner and this panel stay in lockstep on that one
/// value; everything else lives under a `card.<presentation>.<dial>` namespace.
enum CardTuningKey {
    static func key(_ p: CardPresentation, _ d: CardDial) -> String {
        if p == .carousel, d == .spacing { return CoverFlowKey.cardSpacing }
        return "card.\(p.rawValue).\(d.rawValue)"
    }
}

enum CardTuningDefaults {
    // Baked from T's on-device tuning pass. Carousel opacity + spacing and
    // vertical font + opacity landed at their originals; the rest moved.
    // 2026-07-17: carousel height 1.48→1.49 and heroZone 0.31→0.40 baked from
    // T's device (his last two device-verified moves).
    static func value(_ p: CardPresentation, _ d: CardDial) -> Double {
        switch (p, d) {
        case (.carousel, .height):      return 1.49
        case (.vertical, .height):      return 1.22
        case (.carousel, .heroZone):    return 0.40
        case (.vertical, .heroZone):    return 0.39
        case (.carousel, .fontScale):   return 0.90
        case (.vertical, .fontScale):   return 1.00
        case (_, .textOpacity):         return 1.00
        case (.carousel, .spacing):     return -60     // also CoverFlowDefaults.cardSpacing
        case (.vertical, .spacing):     return -46
        }
    }
}

/// UserDefaults-backed binding that honors the dial's default when the key has
/// never been written. Writing propagates to every `@AppStorage` reader (they
/// observe `UserDefaults.didChangeNotification`), so the live surface updates
/// as the slider moves.
enum CardTuningStore {
    static func read(_ p: CardPresentation, _ d: CardDial) -> Double {
        let key = CardTuningKey.key(p, d)
        return UserDefaults.standard.object(forKey: key) as? Double
            ?? CardTuningDefaults.value(p, d)
    }
    static func write(_ v: Double, _ p: CardPresentation, _ d: CardDial) {
        UserDefaults.standard.set(v, forKey: CardTuningKey.key(p, d))
    }
}

// MARK: - Panel (DEBUG)

#if DEBUG
struct CardTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize

    @State private var presentation: CardPresentation = .carousel
    @State private var dial: CardDial = .height
    @GestureState private var dragTranslation: CGSize = .zero
    @State private var justCopied = false
    /// Bumped on every write so the slider re-reads the UserDefaults-backed
    /// value when the presentation / dial selection changes.
    @State private var revision = 0

    private static let widgetWidth: CGFloat = 280

    private var valueBinding: Binding<Double> {
        Binding(
            get: { _ = revision; return CardTuningStore.read(presentation, dial) },
            set: { CardTuningStore.write($0, presentation, dial); revision += 1 }
        )
    }

    private var valueString: String {
        String(format: dial.format, CardTuningStore.read(presentation, dial))
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            presentationToggle
            paramChip
            sliderRow
        }
        .padding(12)
        .frame(width: Self.widgetWidth)
        .modifier(CardTuningWidgetSurface())
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
        .offset(x: position.width + dragTranslation.width,
                y: position.height + dragTranslation.height)
    }

    private var header: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
            HStack(spacing: 4) {
                Spacer()
                Button { copyValues() } label: {
                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(justCopied ? Color.green : .secondary)
                        .contentShape(Rectangle())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy values")
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragTranslation) { value, state, _ in state = value.translation }
                .onEnded { value in
                    position.width += value.translation.width
                    position.height += value.translation.height
                }
        )
    }

    private var presentationToggle: some View {
        Picker("Presentation", selection: $presentation) {
            ForEach(CardPresentation.allCases, id: \.self) { p in
                Text(p.label).tag(p)
            }
        }
        .pickerStyle(.segmented)
    }

    private var paramChip: some View {
        Menu {
            ForEach(CardDial.allCases, id: \.self) { d in
                Button { dial = d } label: { Text(d.label) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(dial.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(valueString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private var sliderRow: some View {
        Slider(value: valueBinding, in: dial.range, step: dial.step)
            .frame(height: 32)
    }

    private func copyValues() {
        var lines: [String] = []
        for p in CardPresentation.allCases {
            for d in CardDial.allCases {
                let v = CardTuningStore.read(p, d)
                lines.append("\(d.exportLabel)_\(p.rawValue): \(String(format: d.format, v))")
            }
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            justCopied = false
        }
    }
}

private struct CardTuningWidgetSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}
#endif
