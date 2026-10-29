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
    @State private var strength = MapLookStrength.picked(MapLookChoice.picked)
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
            if store.isPro && MapLookStrength.has(picked) {   // 1.1-B — T's Subtle / Medium / Strong for the picked look
                HStack(spacing: 12) {
                    Text("Strength").font(appFont.font(size: 15, relativeTo: .subheadline)).foregroundStyle(AppearancePalette.ink)
                    Picker("Strength", selection: Binding(get: { strength }, set: { s in
                        MapLookStrength.set(s, for: picked); strength = s })) {
                        ForEach(LookStrength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearance.lookStrength")
                }
                .padding(.top, 2)
            }
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
            strength = MapLookStrength.picked(p)
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

/// 1.1-A fix-up (1) — "Gravity" (1.1-B: was "Gravity wells"; Settings → Appearance and the Appearance panel share it). On by default; off by
/// itself in Low Power Mode or while the phone is hot, back when that ends (`MapWells`).
struct GravityWellsToggle: View {
    var detailed: Bool
    @Environment(\.appBodyFont) private var appFont
    @State private var on = MapWells.userOn
    @State private var stressed = MapHeatGuard.shared.stressed
    @State private var lowPower = MapHeatGuard.shared.lowPower

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { on = $0; MapWells.userOn = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Gravity").font(appFont.font(size: 15, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppearancePalette.ink)
                if let detail {
                    Text(detail).font(appFont.font(size: 12, relativeTo: .caption1))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(.purple)
        .accessibilityIdentifier("appearance.gravityWells")
        .onReceive(NotificationCenter.default.publisher(for: .mapHeatGuardChanged)) { _ in
            stressed = MapHeatGuard.shared.stressed
            lowPower = MapHeatGuard.shared.lowPower
        }
    }

    private var detail: String? {
        if on && stressed { return lowPower ? "Paused in Low Power Mode" : "Paused while your iPhone cools down" }
        return detailed ? "The Map's dots dip toward the ideas you're reading. Off uses less battery." : nil
    }
}

/// 1.1-B — "Sheen" (TestFlight only): T judges the ground study's sheen on the 1.1-B TestFlight. Shown only on TestFlight
/// installs (`InstallChannel`), on by default there; App Store installs never show it and draw no sheen.
struct SheenToggle: View {
    var detailed: Bool
    @Environment(\.appBodyFont) private var appFont
    @State private var on = MapSheen.userOn
    @State private var testFlight = InstallChannel.isTestFlight

    var body: some View {
        Group {
            if testFlight {
                Toggle(isOn: Binding(get: { on }, set: { on = $0; MapSheen.userOn = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sheen").font(appFont.font(size: 15, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(AppearancePalette.ink)
                        Text(MapWells.userOn ? "TestFlight only: a soft light across the wells. Off uses less battery."
                                             : "TestFlight only. Needs Gravity on.")
                            .font(appFont.font(size: 12, relativeTo: .caption1))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(.purple)
                .accessibilityIdentifier("appearance.sheen")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .installChannelResolved)) { _ in
            testFlight = InstallChannel.isTestFlight
        }
    }
}

/// 1.1-B — "Background", beside Map look (Pro): the background colour, an optional two-colour gradient across the screen,
/// and the Map's dots, for the appearance showing now. It applies to the Map, cards, lists and the Dashboard (T, amended
/// 2026-10-29); text on it picks its ink by contrast (`MapGround.inkPick`). Without Pro the row carries a lock and opens
/// the Pro sheet, as the Map looks do. "Reset to default" returns every view to today's ground.
struct MapGroundSection: View {
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.colorScheme) private var scheme
    @State private var showPro = false
    @State private var side = MapGround.edited(light: false)
    @State private var adjusted = false   // the last pick was moved out of the unreadable band (`ReadableGround`)
    private var store: ProStore { ProStore.shared }
    private var light: Bool { scheme == .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background").font(appFont.font(size: 15, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(AppearancePalette.ink)
            Group {
                if store.isPro { editor } else { lockedRow }
            }
            .background(AppearancePalette.ink.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(store.isPro ? "For the Map, cards, lists and the Dashboard in \(light ? "Light" : "Dark"). Switch to \(light ? "Dark" : "Light") to edit the other."
                             : "Change the background and the Map's dots with AirPad Pro.")
                .font(appFont.font(size: 12, relativeTo: .caption1)).foregroundStyle(AppearancePalette.ink.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showPro) { ProSheet() }
        .onAppear { side = MapGround.edited(light: light) }
        .onChange(of: scheme) { _, _ in side = MapGround.edited(light: light) }
    }

    private var lockedRow: some View {
        Button { showPro = true } label: {
            HStack(spacing: 14) {
                GroundSwatch(side: light ? .lightDefault : .darkDefault)
                Text("Background and dots").font(appFont.font(size: 16, relativeTo: .body)).foregroundStyle(AppearancePalette.ink)
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(AppearancePalette.ink.opacity(0.35))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Background, locked. Opens AirPad Pro.")
        .accessibilityIdentifier("mapGround.locked")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorPicker("Colour", selection: hexBinding(\.color), supportsOpacity: false)
            Toggle("Gradient", isOn: binding(\.gradient)).tint(.purple)
            if side.gradient {
                ColorPicker("Second colour", selection: hexBinding(\.color2), supportsOpacity: false)
                slider("Angle", value: binding(\.angle), range: 0...360, text: "\(Int(side.angle.rounded()))°")
            }
            ColorPicker("Map dots", selection: hexBinding(\.dot), supportsOpacity: false)
            slider("Map dot opacity", value: binding(\.dotOpacity), range: 0...1, text: "\(Int((side.dotOpacity * 100).rounded()))%")
            if adjusted {
                Text("Adjusted so text stays readable.")
                    .font(appFont.font(size: 12, relativeTo: .caption1)).foregroundStyle(AppearancePalette.ink.opacity(0.6))
                    .accessibilityIdentifier("mapGround.adjusted")
            }
            Button("Reset to default") {
                side = light ? .lightDefault : .darkDefault; adjusted = false; MapGround.setEdited(side, light: light)
            }
                .font(appFont.font(size: 15, relativeTo: .subheadline))
                .disabled(!side.custom)
                .accessibilityIdentifier("mapGround.reset")
        }
        .font(appFont.font(size: 16, relativeTo: .body))
        .foregroundStyle(AppearancePalette.ink)
        .padding(12)
        .accessibilityIdentifier("mapGround.editor")
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(text).monospacedDigit().foregroundStyle(AppearancePalette.ink.opacity(0.6)) }
            Slider(value: value, in: range).tint(.purple).accessibilityLabel(label)
        }
    }

    /// Any edit makes the appearance custom (every view then draws it).
    private func commit(_ s0: MapGroundSide) {
        var s = s0; s.custom = true
        let stored = MapGround.setEdited(s, light: light)   // the setter keeps text readable (ReadableGround)
        adjusted = stored.color != s.color || (s.gradient && stored.color2 != s.color2)
        side = stored
    }
    private func binding<T>(_ k: WritableKeyPath<MapGroundSide, T>) -> Binding<T> {
        Binding(get: { side[keyPath: k] }, set: { var s = side; s[keyPath: k] = $0; commit(s) })
    }
    private func hexBinding(_ k: WritableKeyPath<MapGroundSide, String>) -> Binding<Color> {
        Binding(get: {
            let c = MapGroundSide.rgb(side[keyPath: k])
            return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            func ch(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
            var s = side; s[keyPath: k] = String(format: "%02X%02X%02X", ch(r), ch(g), ch(b)); commit(s)
        })
    }
}

/// The ground drawn small: its colour (or gradient) with three dots.
private struct GroundSwatch: View {
    let side: MapGroundSide
    var size: CGFloat = 34
    private func color(_ h: String) -> Color { let c = MapGroundSide.rgb(h); return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }
    var body: some View {
        ZStack {
            LinearGradient(colors: [color(side.color), color(side.gradient ? side.color2 : side.color)],
                           startPoint: .bottom, endPoint: .top)
            HStack(spacing: size * 0.18) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(color(side.dot).opacity(side.dotOpacity)).frame(width: 3, height: 3) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(AppearancePalette.ink.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// 1.1-A fix-up (2) — "Dashboard surface", beside Map look: what the Dashboard's panes are made of. Glass is free (and
/// what everyone gets); without Pro the others carry a lock and open the Pro sheet, as the Map looks do.
struct DashboardSurfaceSection: View {
    @Environment(\.appBodyFont) private var appFont
    @Environment(\.colorScheme) private var scheme
    @AppStorage(DashboardSurfaceChoice.storageKey) private var pickedRaw = DashboardSurfaceChoice.free.rawValue
    @State private var showPro = false
    private var store: ProStore { ProStore.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dashboard surface").font(appFont.font(size: 15, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(AppearancePalette.ink)
            VStack(spacing: 0) {
                let lineup = DashboardSurfaceChoice.lineup
                ForEach(Array(lineup.enumerated()), id: \.element) { i, c in
                    row(c)
                    if i < lineup.count - 1 { Divider().overlay(AppearancePalette.ink.opacity(0.08)).padding(.leading, 60) }
                }
            }
            .background(AppearancePalette.ink.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(store.isPro ? "The panes on the Dashboard, over its color."
                             : "Glass is free. The other surfaces come with AirPad Pro.")
                .font(appFont.font(size: 12, relativeTo: .caption1)).foregroundStyle(AppearancePalette.ink.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showPro) { ProSheet() }
    }

    private func row(_ c: DashboardSurfaceChoice) -> some View {
        let locked = !c.isFree && !store.isPro
        let selected = DashboardSurfaceChoice.effective(pickedRaw: pickedRaw, isPro: store.isPro) == c
        return Button {
            if locked { showPro = true; return }
            pickedRaw = c.rawValue
        } label: {
            HStack(spacing: 14) {
                SurfaceSwatch(choice: c)
                Text(c.label).font(appFont.font(size: 16, relativeTo: .body)).foregroundStyle(AppearancePalette.ink)
                Spacer()
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(AppearancePalette.ink.opacity(0.35))
                } else if selected {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locked ? "\(c.label), locked. Opens AirPad Pro." : c.label)
        .accessibilityAddTraits(selected && !locked ? .isSelected : [])
        .accessibilityIdentifier("dashSurface-\(c.rawValue)")
    }
}

/// The surface drawn small over a two-colour wash, the way it sits over the Dashboard's colour.
private struct SurfaceSwatch: View {
    let choice: DashboardSurfaceChoice
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.45, green: 0.35, blue: 0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Color.clear
                .modifier(DashboardSurface(cornerRadius: size * 0.16, forced: choice))
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// pro-build — the Pro sheet. Copy = Companion's draft; rc step 1: T's line ("New looks", not "Seven new looks").
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
                Text("Make your Map yours. New looks for every idea you keep, light and dark.")
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
