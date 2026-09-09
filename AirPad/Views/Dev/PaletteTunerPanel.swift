#if DEBUG
import SwiftUI

// The tuner PANEL — a bottom overlay OVER the live app, so T judges the real UI (not a swatch) as he
// drags. Mounted via `.paletteTunerHost()` on the app root; DEBUG only + gated on
// InternalBuild.showsDevTuners, and the whole file is #if DEBUG so Release carries none of it.

extension View {
    func paletteTunerHost() -> some View { modifier(PaletteTunerHost()) }
}

struct PaletteTunerHost: ViewModifier {
    @State private var tuner = PaletteTuner.shared
    func body(content: Content) -> some View {
        content
            // Force the appearance being edited so T sees + dials it; nil follows the system.
            .preferredColorScheme(tuner.previewDark.map { $0 ? .dark : .light })
            .overlay(alignment: .topTrailing) {
                if InternalBuild.showsDevTuners && !tuner.isPresented {
                    Button { tuner.isPresented = true } label: {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(9).background(.black.opacity(0.55)).clipShape(Circle())
                    }
                    .padding(.top, 8).padding(.trailing, 10)
                }
            }
            .overlay(alignment: .bottom) {
                if tuner.isPresented { PaletteTunerPanel(tuner: tuner) }
            }
    }
}

struct PaletteTunerPanel: View {
    @Bindable var tuner: PaletteTuner
    @State private var selectedID: String? = nil
    @State private var editingDark = false
    @State private var groupMode = false
    @State private var couplingGroup: [String] = []
    @State private var exported: String? = nil

    private var selected: PaletteTokenDef? { PaletteTuner.registry.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            if let def = selected { editor(def).transition(.opacity) }
            else { list }
        }
        .frame(maxWidth: .infinity)
        .frame(height: UIScreen.main.bounds.height * 0.5)
        .background(.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .padding(8)
        .preferredColorScheme(.dark) // the panel chrome itself is always dark, regardless of preview
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if selected != nil {
                Button { withAnimation { selectedID = nil } } label: { Image(systemName: "chevron.left") }
            }
            Text(selected?.name ?? "Palette").font(.system(size: 16, weight: .semibold))
            Spacer()
            Picker("", selection: Binding(get: { editingDark }, set: { editingDark = $0; tuner.previewDark = $0 })) {
                Text("Light").tag(false); Text("Dark").tag(true)
            }.pickerStyle(.segmented).frame(width: 130)
            Menu {
                Button("Reset all", role: .destructive) { tuner.resetAll() }
                Button("Export palette") { exported = tuner.exportSwift(); UIPasteboard.general.string = exported }
                Button("Follow system appearance") { tuner.previewDark = nil }
            } label: { Image(systemName: "ellipsis.circle") }
            Button { tuner.isPresented = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6)) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let e = exported {
                    Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(.green)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.bottom, 6)
                        .textSelection(.enabled)
                    Text("↑ copied to clipboard").font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 8)
                }
                ForEach([PaletteKind.primary, .recipe, .derived], id: \.self) { kind in
                    Text(kind.rawValue).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .padding(.top, 8).padding(.bottom, 2)
                    ForEach(PaletteTuner.registry.filter { $0.kind == kind }) { def in row(def) }
                }
            }.padding(.horizontal, 12).padding(.bottom, 20)
        }
    }

    private func row(_ def: PaletteTokenDef) -> some View {
        let dark = editingDark && def.hasDark
        let val = tuner.currentValue(def.id, dark: dark) ?? (dark ? def.bakedDark : def.bakedLight)
        let overridden = tuner.hex(def.id, dark: dark) != nil
        let coupled = def.type == .color ? tuner.coupledTokens(def.id, dark: dark).count : 0
        return Button { withAnimation { select(def) } } label: {
            HStack(spacing: 10) {
                if def.type == .color {
                    RoundedRectangle(cornerRadius: 5).fill(PaletteColor.color(val)).frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2)))
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(def.name).font(.system(size: 14, weight: .medium))
                        if overridden { Circle().fill(.orange).frame(width: 6, height: 6) }
                    }
                    if let n = def.note { Text(n).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if coupled > 0 { Text("↔\(coupled)").font(.system(size: 11)).foregroundStyle(.blue) }
                Text(def.type == .color ? "#\(val)" : val).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func select(_ def: PaletteTokenDef) {
        selectedID = def.id
        if !def.hasDark { editingDark = false; tuner.previewDark = false }
        couplingGroup = tuner.coupledTokens(def.id, dark: editingDark && def.hasDark).map(\.id)
        groupMode = false
        exported = nil
    }

    @ViewBuilder private func editor(_ def: PaletteTokenDef) -> some View {
        let dark = editingDark && def.hasDark
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !def.hasDark { Text("Light-only token").font(.system(size: 11)).foregroundStyle(.secondary) }

                if def.type == .color {
                    HSLColorPicker(hex: Binding(
                        get: { tuner.currentValue(def.id, dark: dark) ?? (dark ? def.bakedDark : def.bakedLight) },
                        set: { applyColor(def, dark: dark, hex: $0) }
                    ))
                    if let baseAlpha = (dark ? def.alphaDark : def.alphaLight) {
                        alphaSlider(def, dark: dark, baked: baseAlpha)
                    }
                    couplingBlock(def, dark: dark)
                } else {
                    floatSlider(def)
                }

                HStack {
                    Button(role: .destructive) { tuner.resetOne(def.id); refreshCoupling(def) } label: {
                        Label("Reset this token", systemImage: "arrow.uturn.backward")
                    }
                    Spacer()
                }.padding(.top, 4)
            }.padding(16)
        }
    }

    private func couplingBlock(_ def: PaletteTokenDef, dark: Bool) -> some View {
        let coupled = tuner.coupledTokens(def.id, dark: dark)
        return Group {
            if !coupled.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shares this value with \(coupled.count): \(coupled.map(\.name).joined(separator: ", "))")
                        .font(.system(size: 12)).foregroundStyle(.blue)
                    Picker("", selection: $groupMode) {
                        Text("Move only this").tag(false); Text("Move the group").tag(true)
                    }.pickerStyle(.segmented)
                    Text("Coincidental equality — not a shared token. Your choice decides whether the card background gets its own value.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(12).background(.blue.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func alphaSlider(_ def: PaletteTokenDef, dark: Bool, baked: Float) -> some View {
        let current = tuner.alpha(def.id, dark: dark) ?? baked
        return VStack(alignment: .leading, spacing: 4) {
            Text("Alpha  \(String(format: "%.2f", current))").font(.system(size: 12, design: .monospaced))
            Slider(value: Binding(get: { Double(current) }, set: { tuner.setAlpha(def.id, dark: dark, $0) }), in: 0...1)
        }
    }

    private func floatSlider(_ def: PaletteTokenDef) -> some View {
        let dark = editingDark && def.hasDark
        let current = Float(tuner.currentValue(def.id, dark: dark) ?? (dark ? def.bakedDark : def.bakedLight)) ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(def.name)  =  \(String(format: "%.3f", current))").font(.system(size: 14, design: .monospaced))
            Slider(value: Binding(get: { Double(current) }, set: { tuner.set(def.id, dark: dark, value: String(format: "%.3f", $0)) }),
                   in: Double(def.range.lowerBound)...Double(def.range.upperBound))
            Text("baked \(dark ? def.bakedDark : def.bakedLight)").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // Write the colour override for this token, and — if group-mode — every token it was coupled to.
    private func applyColor(_ def: PaletteTokenDef, dark: Bool, hex: String) {
        tuner.set(def.id, dark: dark, value: hex)
        if groupMode {
            for id in couplingGroup where id != def.id {
                if let other = PaletteTuner.registry.first(where: { $0.id == id }) {
                    tuner.set(other.id, dark: dark && other.hasDark, value: hex)
                }
            }
        }
    }
    private func refreshCoupling(_ def: PaletteTokenDef) {
        couplingGroup = tuner.coupledTokens(def.id, dark: editingDark && def.hasDark).map(\.id)
    }
}
#endif
