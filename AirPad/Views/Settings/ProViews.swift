import SwiftUI

/// pro-build — the swatch for a look on a Map: a rendered image of that look's shader at the shipped values
/// (`Assets.xcassets/LookSwatches`, made by `scripts/renders/look_swatches.sh`).
struct LookSwatch: View {
    let look: MapOrbLook
    let light: Bool
    var size: CGFloat = 34
    var body: some View {
        Image("swatch-\(light ? "light" : "dark")-\(light && look.drawsWashOnLight ? "wash" : look.rawValue)")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// pro-build — Settings → Appearance → "Map look": the lineup of the Map shown (dark / light), each with its swatch.
/// Flat is free; without Pro the other looks carry a lock and open the Pro sheet.
struct MapLookSection: View {
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.colorScheme) private var scheme
    @State private var lightTab: Bool?
    @State private var picked = MapLookChoice.picked
    @State private var showPro = false
    private var store: ProStore { ProStore.shared }

    private var light: Bool { lightTab ?? (scheme == .light) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Map look").font(appFont.font(size: 15, weight: .semibold, relativeTo: .subheadline)).foregroundStyle(AppearancePalette.ink)
            Picker("Map", selection: Binding(get: { light }, set: { lightTab = $0 })) {
                Text("Dark Map").tag(false)
                Text("Light Map").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Which Map's looks to show")
            VStack(spacing: 0) {
                let lineup = light ? MapLookChoice.lightLineup : MapLookChoice.darkLineup
                ForEach(Array(lineup.enumerated()), id: \.element) { i, look in
                    row(look)
                    if i < lineup.count - 1 { Divider().overlay(AppearancePalette.ink.opacity(0.08)).padding(.leading, 60) }
                }
            }
            .background(AppearancePalette.ink.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(store.isPro ? "Your pick applies to both Maps: Aura and Eclipse show as Wash on the light Map."
                             : "Flat is free. The other looks come with AirPad Pro.")
                .font(appFont.font(size: 12, relativeTo: .caption1)).foregroundStyle(AppearancePalette.ink.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showPro) { ProSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .proEntitlementChanged)) { _ in picked = MapLookChoice.picked }
    }

    private func row(_ look: MapOrbLook) -> some View {
        let locked = look != .flat && !store.isPro
        let selected = MapLookChoice.isSelected(look, light: light, picked: picked)
        let name = MapLookChoice.name(look, light: light)
        return Button {
            if locked { showPro = true; return }
            let p = MapLookChoice.pick(for: look, light: light, current: picked)
            MapLookChoice.picked = p
            picked = p
        } label: {
            HStack(spacing: 14) {
                LookSwatch(look: look, light: light)
                Text(name).font(appFont.font(size: 16, relativeTo: .body)).foregroundStyle(AppearancePalette.ink)
                Spacer()
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(AppearancePalette.ink.opacity(0.35))
                } else if selected && (look == .flat || store.isPro) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locked ? "\(name), locked. Opens AirPad Pro." : name)
        .accessibilityAddTraits(selected && !locked ? .isSelected : [])
        .accessibilityIdentifier("mapLook-\(light ? "light" : "dark")-\(look.rawValue)")
    }
}

/// pro-build — the Pro sheet. Copy = Companion's draft (T approves on device).
struct ProSheet: View {
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var message: String?
    @State private var thanks = false
    @State private var showTips = false
    private var store: ProStore { ProStore.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("AirPad Pro").font(appFont.font(size: 28, weight: .bold, relativeTo: .largeTitle)).foregroundStyle(AppearancePalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Make your Map yours. Seven new looks for every idea you keep, light and dark.")
                    .font(appFont.font(size: 17, relativeTo: .body)).foregroundStyle(AppearancePalette.ink.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(Self.list.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 14) {
                            LookSwatch(look: item.look, light: item.light, size: 38)
                            Text(item.name).font(appFont.font(size: 16, relativeTo: .body)).foregroundStyle(AppearancePalette.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
                        if i < Self.list.count - 1 { Divider().overlay(AppearancePalette.ink.opacity(0.08)).padding(.leading, 64) }
                    }
                }
                .background(AppearancePalette.ink.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("One-time purchase. Includes every look we add later. Everything else in AirPad stays free.")
                    .font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                actions
                Divider().overlay(AppearancePalette.ink.opacity(0.1))
                Button { showTips = true } label: {
                    Label("Support AirPad with a tip", systemImage: "heart")
                        .font(appFont.font(size: 15, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("proTipLink")
            }
            .padding(24)
        }
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        .presentationBackground(AppearancePalette.bgBase)
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showTips) {
            ScrollView { TipJarView().padding(24) }
                .background(AppearancePalette.bgBase.ignoresSafeArea())
                .presentationBackground(AppearancePalette.bgBase)
                .presentationDetents([.medium, .large])
        }
        .task { if store.loadState != .loaded { await store.loadProducts() } }
    }

    /// The seven Pro looks, each with its swatch (Wash on the light Map).
    private static let list: [(name: String, look: MapOrbLook, light: Bool)] = [
        ("Glass", .glass, false), ("Aura", .aura, false), ("Eclipse", .eclipse, false), ("Wash", .aura, true),
        ("Riso", .riso, false), ("Gradient", .gradient, false), ("Outline", .outline, false)]

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if thanks || store.isPro {
                Text("Thank you. Pick a look.").font(appFont.font(size: 17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(AppearancePalette.ink).accessibilityIdentifier("proThanks")
            } else {
                switch store.loadState {
                case .loaded:
                    primaryButton("Unlock Pro · \(store.price(ProStore.proID) ?? "")", id: "proUnlock",
                                  busy: store.busyID == ProStore.proID) { await unlock() }
                case .failed:
                    Text("Couldn't reach the App Store. Try again.")
                        .font(appFont.font(size: 15, relativeTo: .subheadline)).foregroundStyle(AppearancePalette.ink.opacity(0.75))
                    primaryButton("Try Again", id: "proRetry", busy: false) { await store.loadProducts() }
                case .idle, .loading:
                    primaryButton("Unlock Pro", id: "proUnlock", busy: true) {}
                }
                if store.proPending {
                    Text("Waiting for approval. Pro unlocks as soon as it's approved.")
                        .font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(AppearancePalette.ink.opacity(0.6))
                }
                if let message {
                    Text(message).font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(AppearancePalette.ink.opacity(0.6))
                }
                Button {
                    Task {
                        message = nil
                        let ok = await store.restore()
                        if !store.isPro { message = ok ? "No AirPad Pro purchase found for this Apple Account." : "Couldn't reach the App Store. Try again." }
                    }
                } label: {
                    Text(store.busyID == "restore" ? "Restoring…" : "Restore Purchases")
                        .font(appFont.font(size: 15, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(store.busyID != nil)
                .accessibilityIdentifier("proRestore")
            }
        }
        .onChange(of: store.isPro) { _, pro in if pro { celebrate() } }
    }

    private func primaryButton(_ title: String, id: String, busy: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(AppearancePalette.bgBase) }
                Text(title).font(appFont.font(size: 17, weight: .semibold, relativeTo: .headline))
            }
            .foregroundStyle(AppearancePalette.bgBase)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(AppearancePalette.ink).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy || store.busyID != nil)
        .accessibilityIdentifier(id)
    }

    private func unlock() async {
        message = nil
        switch await store.buy(ProStore.proID) {
        case .purchased: celebrate()
        case .pending, .cancelled: break
        case .failed(let m): message = m
        }
    }

    private func celebrate() {
        guard !thanks else { return }
        thanks = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { dismiss() }
    }
}

/// pro-build — the tip jar (Settings → Support AirPad, and the Pro sheet's link). Tips unlock nothing.
struct TipJarView: View {
    @Environment(\.appBodyFont) private var appFont
    @State private var thanks = false
    @State private var message: String?
    private var store: ProStore { ProStore.shared }
    private static let tips: [(String, String)] = [("Small Tip", ProStore.tipIDs[0]), ("Medium Tip", ProStore.tipIDs[1]),
                                                   ("Large Tip", ProStore.tipIDs[2])]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AirPad is made by one person. If it's useful to you, a tip helps keep it going.")
                .font(appFont.font(size: 16, relativeTo: .body)).foregroundStyle(AppearancePalette.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            if store.loadState == .failed {
                Text("Couldn't reach the App Store. Try again.")
                    .font(appFont.font(size: 15, relativeTo: .subheadline)).foregroundStyle(AppearancePalette.ink.opacity(0.75))
                Button("Try Again") { Task { await store.loadProducts() } }
                    .font(appFont.font(size: 15, weight: .semibold, relativeTo: .subheadline)).tint(AppearancePalette.ink)
                    .accessibilityIdentifier("tipRetry")
            } else {
                ForEach(Self.tips, id: \.1) { name, id in
                    Button { Task { await tip(id) } } label: {
                        HStack {
                            Text(name).font(appFont.font(size: 16, weight: .medium, relativeTo: .body))
                            Spacer()
                            if store.busyID == id { ProgressView() }
                            else { Text(store.price(id) ?? "").font(appFont.font(size: 16, relativeTo: .body)).monospacedDigit() }
                        }
                        .foregroundStyle(AppearancePalette.ink)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .background(AppearancePalette.ink.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.loadState != .loaded || store.busyID != nil)
                    .accessibilityLabel("\(name)\(store.price(id).map { ", \($0)" } ?? "")")
                    .accessibilityIdentifier("tip-\(id.split(separator: ".").last ?? "")")
                }
            }
            if thanks {
                Text("Thank you!").font(appFont.font(size: 17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(AppearancePalette.ink).accessibilityIdentifier("tipThanks")
            }
            if let message {
                Text(message).font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(AppearancePalette.ink.opacity(0.6))
            }
        }
        .task { if store.loadState != .loaded { await store.loadProducts() } }
    }

    private func tip(_ id: String) async {
        message = nil
        switch await store.buy(id) {
        case .purchased: thanks = true
        case .pending: message = "Waiting for approval."
        case .cancelled: break
        case .failed(let m): message = m
        }
    }
}
