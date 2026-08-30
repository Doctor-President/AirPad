import SwiftUI

// The shared model-picker: a footer pill row (Private · Model · Thinking) used by BOTH the Chat
// View and the Librarian (built ONCE so the two can't diverge), and the bottom sheet it opens.
// Real components mirroring the T-approved v2 prototype, wired to HostCatalog + the per-chat
// thinking toggle. GREEN check hex #2E9E4F is a placeholder for T to dial.

// MARK: - shared pills (the corpusModeToggle capsule idiom)

private struct PickerPill<Content: View>: View {
    var filled: Bool = false
    var stroked: Bool = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(AppearancePalette.ink.opacity(filled ? 0.12 : 0.05)))
            .overlay(Capsule().strokeBorder(AppearancePalette.ink.opacity(stroked ? 0.28 : 0), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Private · Model · Thinking. Thinking sits at the FAR TRAILING EDGE (mis-tap separation). The
/// Model pill narrates the residency lifecycle and opens the sheet; the Thinking pill is ABSENT
/// (not greyed) when the resident model can't think.
struct ModelPillRow: View {
    var catalog: HostCatalog
    @Binding var thinkEnabled: Bool
    var onTapModel: () -> Void
    /// Chat View shows its own Private pill; the Librarian already has the Private/Corpus toggle,
    /// so it passes false and provides that pill itself (no double "Private").
    var includePrivate: Bool = true

    private var canThink: Bool { catalog.resident?.supportsThinking == true }

    var body: some View {
        HStack(spacing: 8) {
            if includePrivate { privatePill }
            modelPill
            Spacer(minLength: 12)
            if canThink { thinkingPill }
        }
        .padding(.leading, 6)
        .onChange(of: canThink) { _, ok in if !ok { thinkEnabled = false } } // model can't think → force off
    }

    private var privatePill: some View {
        PickerPill {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                Text("Private").font(.system(size: 12, weight: .semibold))
            }.foregroundStyle(AppearancePalette.ink.opacity(0.55))
        }
    }

    private var dividerBar: some View {
        Text("|").font(.system(size: 12)).foregroundStyle(AppearancePalette.ink.opacity(0.25))
    }

    @ViewBuilder private var modelPill: some View {
        Button(action: onTapModel) {
            PickerPill {
                HStack(spacing: 5) {
                    if let busy = catalog.busyTag, let m = catalog.models.first(where: { $0.tag == busy }) {
                        Text("loading").font(.system(size: 12, weight: .medium)).foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        dividerBar
                        name(m.display)
                    } else if let r = catalog.resident {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hexString: "2E9E4F"))
                        name(r.display)
                    } else {
                        Text("No model").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(catalog.resident.map { "Model \($0.display), loaded" } ?? "No model loaded")
    }

    // NO pill is ever taller than one text row (T): tail-truncate the name, bounded width.
    private func name(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppearancePalette.ink.opacity(0.9))
            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 190, alignment: .leading)
    }

    private var thinkingPill: some View {
        Button { thinkEnabled.toggle() } label: {
            PickerPill(filled: thinkEnabled, stroked: !thinkEnabled) {
                Text(thinkEnabled ? "Thinking on" : "Thinking off")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(thinkEnabled ? 0.9 : 0.55))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(thinkEnabled ? "Thinking on" : "Thinking off")
    }
}

// MARK: - the sheet

struct ModelPickerSheet: View {
    var catalog: HostCatalog
    @Binding var thinkEnabled: Bool
    @Environment(\.dismiss) private var dismiss

    private var canThink: Bool { catalog.resident?.supportsThinking == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Capsule().fill(AppearancePalette.ink.opacity(0.2)).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity)

                if canThink {
                    section("THINKING") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Thinking").font(.system(size: 16, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
                                Text("Slower, more careful answers. Off by default.")
                                    .font(.system(size: 12)).foregroundStyle(AppearancePalette.ink.opacity(0.5))
                            }
                            Spacer()
                            Button { thinkEnabled.toggle() } label: {
                                PickerPill(filled: thinkEnabled, stroked: !thinkEnabled) {
                                    Text(thinkEnabled ? "Thinking on" : "Thinking off").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AppearancePalette.ink.opacity(thinkEnabled ? 0.9 : 0.55))
                                }
                            }.buttonStyle(.plain)
                        }.padding(.vertical, 12)
                    }
                }

                if !catalog.installed.isEmpty {
                    section("INSTALLED") { rows(catalog.installed) }
                }
                if !catalog.available.isEmpty {
                    section("AVAILABLE TO DOWNLOAD") {
                        rows(catalog.available)
                        divider
                        moreModelsStub
                    }
                }
                if catalog.models.isEmpty {
                    Text(catalog.reachable ? "No models available for this Mac." : "Can't reach your Mac right now.")
                        .font(.system(size: 14)).foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(20)
        }
        .background(AppearancePalette.bgElevated.ignoresSafeArea())
        .task { await catalog.refresh() } // fetch on sheet-open, off the render path
    }

    private var divider: some View { Divider().overlay(AppearancePalette.ink.opacity(0.08)) }

    @ViewBuilder private func rows(_ models: [CatalogModel]) -> some View {
        ForEach(Array(models.enumerated()), id: \.element.id) { i, m in
            if i > 0 { divider }
            ModelSheetRow(model: m, catalog: catalog)
        }
    }

    private func section<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.4)).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 18).fill(AppearancePalette.ink.opacity(0.05)))
        }
    }

    // STUB — ws-host-library-browse, post-V1. Renders only.
    private var moreModelsStub: some View {
        HStack {
            Text("More models").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.8))
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.4))
            Spacer()
            Text("the full library · soon").font(.system(size: 11)).foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }.padding(.vertical, 14)
    }
}

/// One model row: name + (blue "in memory" badge on the resident) + Eject/Load/Download, and the
/// FULL curated copy always-visible (T's ruling). The metadata line names thinking support from
/// the same `supportsThinking` field the pill gates on.
private struct ModelSheetRow: View {
    let model: CatalogModel
    var catalog: HostCatalog

    private var meta: String {
        var parts = ["\(gb(model.sizeBytes))"]
        if !model.capabilities.isEmpty { parts.append(model.capabilities.joined(separator: ", ")) }
        parts.append(model.thinkingCopy)
        parts.append(model.verified ? "✓ tested" : "candidate")
        return parts.joined(separator: " · ")
    }
    private func gb(_ b: Int64) -> String { b > 0 ? "\(Int((Double(b) / 1e9).rounded())) GB" : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.display).font(.system(size: 16, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1).truncationMode(.tail)
                if model.isResident {
                    Text("in memory").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color(hexString: "1B59C2")))
                }
                Spacer(minLength: 8)
                action
            }
            Text(meta).font(.system(size: 12)).foregroundStyle(AppearancePalette.ink.opacity(0.55))
            if !model.capability.isEmpty {
                Text(model.capability).font(.system(size: 13)).foregroundStyle(AppearancePalette.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.posture.isEmpty {
                Text(model.posture).font(.system(size: 12)).foregroundStyle(AppearancePalette.ink.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var action: some View {
        let busy = catalog.busyTag == model.tag
        if model.isResident {
            actionPill("Eject", ghost: true, busy: busy) { await catalog.eject(model.tag) }
        } else if model.isInstalled {
            actionPill("Load", ghost: false, busy: busy) { await catalog.load(model.tag) }
        } else {
            actionPill("Download", ghost: false, busy: busy) { await catalog.install(model.tag) }
        }
    }

    private func actionPill(_ title: String, ghost: Bool, busy: Bool, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            Text(busy ? "Working…" : title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ghost ? AppearancePalette.ink.opacity(0.9) : .white)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(ghost ? AppearancePalette.ink.opacity(0.10) : Color(hexString: "1B59C2")))
                .opacity(busy ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy || catalog.busyTag != nil)
    }
}

// MARK: - thought-process block (increment 7)

/// The reasoning-model thought process of the LATEST turn — NAMED "Thought process" (the ARTIFACT),
/// deliberately NOT "Thinking" (the SETTING/pill; T: two different things must not share a word).
/// Collapsed by default, expandable; SHIMMERS while it streams and resolves to a static row once the
/// answer begins. Ephemeral: it reads session.streamingThinking, which is never persisted and resets
/// each turn — send another message and the previous thought process is gone.
struct ThoughtProcessBlock: View {
    var session: ChatSession
    @State private var expanded = false
    @State private var pulse = false

    /// Still thinking = streaming AND the answer hasn't started.
    private var thinking: Bool { session.isStreaming && session.streamingText.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Thought process")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppearancePalette.ink.opacity(thinking ? (pulse ? 0.75 : 0.32) : 0.45))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.3))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(session.streamingThinking)
                    .font(.system(size: 13))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppearancePalette.ink.opacity(0.04)))
        .onChange(of: thinking) { _, t in setPulse(t) }
        .onAppear { setPulse(thinking) }
    }

    private func setPulse(_ on: Bool) {
        if on {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            pulse = false
        }
    }
}
