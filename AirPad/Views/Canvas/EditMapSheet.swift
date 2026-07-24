// EditMapSheet.swift
// Tag-anchored Map v1 — anchor designation ("Edit Map…" in the Map flyout).
// Corpus tags sorted by node coverage; tap the star to promote/demote a tag
// to/from a canvas territory (≤12). Coverage badge + FM consolidation hint are
// ADVISORY — the user is in control; the system never designates anchors.

import SwiftUI

struct EditMapSheet: View {
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // Gravity signal weights — tunable dials (calibrate on device, bake later).
    @AppStorage("map.weight.collection") private var wCollection: Double = 1.0
    @AppStorage("map.weight.anchor") private var wAnchor: Double = 0.6
    @AppStorage("map.weight.language") private var wLanguage: Double = 0.3
    @AppStorage("map.weight.backlink") private var wBacklink: Double = 0.4
    @AppStorage("map.tintByRecency") private var tintByRecency: Bool = true

    // Graze — engagement tuning dials (baked defaults mirror CorpusPhysicsScene).
    // T dials on device; we bake the winners back into the scene constants.
    @AppStorage("graze.hysteresis") private var grazeHysteresis: Double = 20.0
    @AppStorage("graze.sigmoidSteepness") private var grazeSteepness: Double = 3.0
    @AppStorage("graze.sigmoidMidpoint") private var grazeMidpoint: Double = 0.7
    @AppStorage("graze.compression") private var grazeCompression: Double = 0.55
    @AppStorage("graze.switchLerpDuration") private var grazeSwitchLerp: Double = 0.15

    private var sortedTags: [Tag] {
        store.tags.sorted { store.nodeCount(forTag: $0.name) > store.nodeCount(forTag: $1.name) }
    }
    private var anchorCount: Int { store.tags.reduce(0) { $0 + ($1.isCanvasAnchor ? 1 : 0) } }
    private var atCap: Bool { anchorCount >= CorpusStore.maxCanvasAnchors }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    weightRow("Collection", $wCollection)
                    weightRow("Anchor tag", $wAnchor)
                    weightRow("Language", $wLanguage)
                    weightRow("Backlink", $wBacklink)
                    Toggle(isOn: $tintByRecency) {
                        Text("Vary tint by recency")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppearancePalette.ink)
                    }
                    .listRowBackground(AppearancePalette.ink.opacity(0.04))
                } header: {
                    Text("Gravity — signal weights")
                } footer: {
                    Text("Collection / Anchor / Language decide a node's territory (argmax) and border lean. Backlink then pulls it toward its linked nodes — capped, so territory law still wins. Each node's tint is a shade of its territory family — brighter = more recent when varied by recency, a stable per-node shade otherwise.")
                        .font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }

                Section {
                    grazeRow("Hysteresis", $grazeHysteresis, 0...60, "%.0f")
                    grazeRow("Sigmoid steepness", $grazeSteepness, 0.5...8, "%.2f")
                    grazeRow("Sigmoid midpoint", $grazeMidpoint, 0.2...1.5, "%.2f")
                    grazeRow("Compression", $grazeCompression, 0...1, "%.2f")
                    grazeRow("Switch-lerp (s)", $grazeSwitchLerp, 0...0.5, "%.2f")
                } header: {
                    Text("Graze — engagement tuning")
                } footer: {
                    Text("Focus decision + parting-crowd feel. Hysteresis resists focal flicker; steepness/midpoint shape the growth lens; compression is how far neighbors part; switch-lerp is the settle time after a focal switch. Live on device; baked later.")
                        .font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }

                Section {
                    Text("\(anchorCount) of \(CorpusStore.maxCanvasAnchors) anchors")
                        .font(.footnote)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                } footer: {
                    Text("Promote tags to spatial territories on the Map. Nodes gather in their territory; a node with no anchor tag lands near the nearest one.")
                        .font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }

                Section {
                    ForEach(sortedTags) { tag in
                        row(tag)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .navigationTitle("Edit Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Partial so the map is visible behind while you dial the weights.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func weightRow(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            }
            Slider(value: value, in: 0...2)
        }
        .listRowBackground(AppearancePalette.ink.opacity(0.04))
    }

    /// Slider row with an explicit range + value format (Graze dials span
    /// different scales than the 0…2 gravity weights).
    private func grazeRow(_ label: String, _ value: Binding<Double>,
                          _ range: ClosedRange<Double>, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            }
            Slider(value: value, in: range)
        }
        .listRowBackground(AppearancePalette.ink.opacity(0.04))
    }

    private func row(_ tag: Tag) -> some View {
        let coverage = store.nodeCount(forTag: tag.name)
        let similar = similarTagName(for: tag)
        let promotable = tag.isCanvasAnchor || !atCap
        return HStack(spacing: 12) {
            Circle()
                .fill(Color(hexString: tag.colorHex))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)
                if let similar {
                    Text("Similar to: \(similar)")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(coverage)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            Button {
                Task {
                    if tag.isCanvasAnchor {
                        await store.demoteCanvasAnchor(tagID: tag.id)
                    } else {
                        await store.promoteToCanvasAnchor(tagID: tag.id)
                    }
                }
            } label: {
                Image(systemName: tag.isCanvasAnchor ? "star.fill" : "star")
                    .font(.system(size: 18))
                    .foregroundStyle(tag.isCanvasAnchor ? Color.yellow : AppearancePalette.ink.opacity(promotable ? 0.4 : 0.15))
            }
            .buttonStyle(.plain)
            .disabled(!promotable)
        }
        .listRowBackground(AppearancePalette.ink.opacity(0.04))
    }

    /// Best-effort consolidation hint — the top lift-similar tag, resolved to a
    /// display name (`topSimilarTags` carries tag IDs, which may be a UUID
    /// string or a name depending on when the index was built). Nil when absent.
    private func similarTagName(for tag: Tag) -> String? {
        guard let entry = store.corpusIndex.tags[tag.name],
              let top = entry.topSimilarTags.first else { return nil }
        if let byID = store.tags.first(where: { $0.id.uuidString == top.tagID }) { return byID.name }
        return store.tags.first(where: { $0.name == top.tagID })?.name ?? top.tagID
    }
}
