import SwiftUI

/// Mac batch E6 — choose a collection's (or the Journal's) colour: Automatic (the default), a named swatch, or any
/// colour from the system picker. Applied as it's picked; it drives the sidebar dot, the List's collection column and
/// the collection's Map region. Opened from the collection's menu: right-click › Colour… (Mac), long-press › Colour…
/// (iPhone / iPad).
struct CollectionColorSheet: View {
    let collectionID: String
    let name: String
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appBodyFont) private var appFont

    private var chosen: String? { store.collectionColorHex(collectionID) }
    private var automatic: Color { CollectionDot.automatic(collectionID, light: scheme == .light) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    option(label: "Automatic", detail: "From the Map's palette", fill: automatic, selected: chosen == nil,
                           id: "collectionColor.automatic") { set(nil) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 14) {
                        ForEach(CollectionColors.swatches) { s in
                            swatch(s)
                        }
                    }
                    ColorPicker(selection: Binding(
                        get: { chosen.flatMap(CollectionColors.uiColor).map(Color.init(uiColor:)) ?? automatic },
                        set: { set(CollectionColors.hex(UIColor($0))) }
                    ), supportsOpacity: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom colour").font(appFont.font(size: 15, weight: .semibold))
                            Text(customDetail)
                                .font(appFont.font(size: 12))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                        }
                    }
                    .accessibilityIdentifier("collectionColor.custom")
                }
                .padding(20)
            }
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .navigationTitle("Colour for \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Changes apply as they're picked, so Esc (Mac) and Done both just close.
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("collectionColorSheet")
    }

    /// A custom colour names its hex; a swatch or Automatic leaves the line generic.
    private var customDetail: String {
        guard let chosen, !CollectionColors.swatches.contains(where: { $0.hex == chosen }) else { return "Any colour" }
        return chosen
    }

    private func set(_ hex: String?) { Task { await store.setCollectionColor(collectionID, hex: hex) } }

    private func swatch(_ s: CollectionColors.Swatch) -> some View {
        let on = chosen == s.hex
        return Button { set(s.hex) } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(uiColor: CollectionColors.uiColor(s.hex) ?? .gray))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(AppearancePalette.ink.opacity(0.15), lineWidth: 1))
                    .overlay {
                        if on {
                            Circle().strokeBorder(AppearancePalette.ink, lineWidth: 2.5).padding(-5)
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 1)
                        }
                    }
                Text(s.name)
                    .font(appFont.font(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(AppearancePalette.ink.opacity(on ? 0.95 : 0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.name)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("collectionColor.\(s.name)")
    }

    private func option(label: String, detail: String, fill: Color, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(fill).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(AppearancePalette.ink.opacity(0.15), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(appFont.font(size: 15, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
                    Text(detail).font(appFont.font(size: 12)).foregroundStyle(AppearancePalette.ink.opacity(0.55))
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppearancePalette.ink) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppearancePalette.ink.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// What the colour sheet is open for.
struct CollectionColorTarget: Identifiable, Hashable {
    let id: String
    let name: String
}
