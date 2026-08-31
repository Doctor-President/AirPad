import SwiftUI
import UIKit

// The shared model-picker: a footer pill row (Private · Model · Thinking) used by BOTH the Chat
// View and the Librarian (built ONCE so the two can't diverge), and the bottom sheet it opens.
// Real components mirroring the T-approved v2 prototype, wired to HostCatalog + the per-chat
// thinking toggle. GREEN check hex #2E9E4F is a placeholder for T to dial.

// MARK: - shared composer chrome (one source of truth, so Chat View + Librarian can't drift)

/// The composer's dimensional contract — the SINGLE definition of the spacing between the pill row
/// and the field, and the field's own metrics. The pill row was already extracted (ModelPillRow);
/// these are the "box around it" that had drifted (Chat View's field was skinnier + its pill row
/// crammed against it). The Librarian's Ask field is the reference: T approved its dimensions.
/// Its DECORATION (feather, morphing corner, glow, bounce, mic/send overlay) is legitimately
/// per-surface and stays in the Librarian — only the dimensions + layout are shared here.
enum ComposerMetrics {
    /// Single-line field height — the "parity height" (== the Librarian's askSingleLineHeight).
    static let fieldSingleLineHeight: CGFloat = 52
    /// Field text size (== the Librarian's Ask font).
    static let fieldFontSize: CGFloat = 16
    /// Capsule at one line: half the single-line height (matches the Librarian's pinned radius).
    static let fieldCornerRadius: CGFloat = fieldSingleLineHeight / 2
    /// Vertical text padding so ONE line naturally equals the parity height — the same derivation
    /// the Librarian uses (askTextVPad), so a change to the font/height keeps both correct.
    static var fieldTextVerticalPadding: CGFloat {
        max(0, (fieldSingleLineHeight - UIFont.systemFont(ofSize: fieldFontSize, weight: .regular).lineHeight) / 2)
    }
    /// The text line-box height — drives the inline send/mic overlay's frame + bottom inset so the
    /// control centres on the last text line (same derivation as the Librarian's askLineHeight).
    static var fieldLineHeight: CGFloat { UIFont.systemFont(ofSize: fieldFontSize, weight: .regular).lineHeight }
    /// Trailing text inset that reserves room for the inline send/mic control (== the Librarian's 56).
    static let sendControlReserve: CGFloat = 56
    /// Separation between the pill row and the field (the Librarian's generous gap; Chat View had ~0).
    static let rowSpacing: CGFloat = 8
    /// Outer composer margins.
    static let outerHorizontal: CGFloat = 14
    static let outerTop: CGFloat = 14
    static let outerBottom: CGFloat = 10
}

/// The composer LAYOUT both surfaces mount: the pill row above the field, at the shared spacing +
/// outer margins. `content` is a slot — each surface supplies its own pill row and its own field
/// (the Librarian's decorated Ask field; Chat View's plain field + send button). This is the
/// "extract the composer" sibling of ModelPillRow: the surrounding box now has one definition too.
struct ComposerScaffold<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: ComposerMetrics.rowSpacing) {
            content()
        }
        .padding(.horizontal, ComposerMetrics.outerHorizontal)
        .padding(.top, ComposerMetrics.outerTop)
        .padding(.bottom, ComposerMetrics.outerBottom)
    }
}

/// The inline trailing control — clear + send when there's text, mic/stop (dictation) when empty —
/// mounted at the field's bottom-trailing edge on BOTH surfaces. This is the SHARED send idiom (T's
/// correction: the send control is shared, not Librarian identity). The Librarian-only identity
/// pieces (feather, Klein glow, morphing corner, bounce) stay parameterised in LibrarianSurface.
/// Per-surface parameters: the text binding, whether send is enabled, the send action, and the
/// dictation token (so each field dictates into its own text). The icons/sizes/gradient/dictation
/// logic are shared — the Librarian's `askTrailingControls` is the reference this replicates.
struct ComposerSendControls: View {
    @Binding var text: String
    let sendEnabled: Bool
    let onSend: () -> Void
    let dictationToken: String
    @State private var dictation = LiveDictationService.shared

    /// The send/mic tint — identical on both surfaces (cyan→klein), so it's shared, not identity.
    private static let accent = LinearGradient(
        colors: [Color(hexString: "00BFFF"), Color(hexString: "1B59C2")], startPoint: .top, endPoint: .bottom)

    var body: some View {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isHot = dictation.isListening && dictation.activeToken == dictationToken
        HStack(spacing: 8) {
            if hasText {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }.buttonStyle(.plain).accessibilityLabel("Clear input")
                Button {
                    if isHot { dictation.stop() }
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                        .foregroundStyle(sendEnabled ? AnyShapeStyle(Self.accent)
                                                     : AnyShapeStyle(AppearancePalette.ink.opacity(0.2)))
                }.buttonStyle(.plain).disabled(!sendEnabled).accessibilityLabel("Send")
            } else if isHot {
                Button { dictation.toggle(token: dictationToken, baseline: text, onUpdate: { text = $0 }) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 22)).foregroundStyle(Self.accent)
                }.buttonStyle(.plain).accessibilityLabel("Stop dictation")
            } else {
                Button { dictation.toggle(token: dictationToken, baseline: text, onUpdate: { text = $0 }) } label: {
                    Image(systemName: "mic.fill").font(.system(size: 22)).foregroundStyle(Self.accent).opacity(0.8)
                }.buttonStyle(.plain).accessibilityLabel("Dictate")
            }
        }
    }
}

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

/// A pulsing opacity SHIMMER — the treatment T approved for the Thought-process block, reused for
/// LOAD (which emits no progress events, so an honest "in progress" beats an invented percentage).
/// INSTALL is different — it has real percentages from the sanitized stream — so it does NOT shimmer.
private struct ComposerShimmer: ViewModifier {
    let active: Bool
    @State private var pulse = false
    func body(content: Content) -> some View {
        content
            .opacity(active ? (pulse ? 1.0 : 0.4) : 1.0)
            .onChange(of: active) { _, on in setPulse(on) }
            .onAppear { setPulse(active) }
    }
    private func setPulse(_ on: Bool) {
        if on {
            pulse = false
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
        }
    }
}
extension View {
    /// Shimmer while `active` (a LOAD in flight). Resolves the moment it clears (model resident).
    func composerShimmer(_ active: Bool) -> some View { modifier(ComposerShimmer(active: active)) }
}

/// Private · Model · Thinking. Thinking sits at the FAR TRAILING EDGE (mis-tap separation). The
/// Model pill narrates the residency lifecycle and opens the sheet; the Thinking pill is ABSENT
/// (not greyed) when the resident model can't be told NOT to think (think:false ignored — the
/// toggle would do nothing). Gated on the MEASURED `thinkingToggleable`, not "can think".
struct ModelPillRow: View {
    var catalog: HostCatalog
    @Binding var thinkEnabled: Bool
    var onTapModel: () -> Void
    /// Chat View shows its own Private pill; the Librarian already has the Private/Corpus toggle,
    /// so it passes false and provides that pill itself (no double "Private").
    var includePrivate: Bool = true

    private var canToggleThinking: Bool { catalog.resident?.thinkingToggleable == true }

    var body: some View {
        HStack(spacing: 8) {
            if includePrivate { privatePill }
            modelPill
            Spacer(minLength: 12)
            if canToggleThinking { thinkingPill }
        }
        .padding(.leading, 6)
        .onChange(of: canToggleThinking) { _, ok in if !ok { thinkEnabled = false } } // toggle can't work → force off
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
                        // Load emits no progress → SHIMMER "loading" (honest "in progress", not a fake %).
                        Text("loading").font(.system(size: 12, weight: .medium)).foregroundStyle(AppearancePalette.ink.opacity(0.5))
                            .composerShimmer(catalog.busyPercent == nil)
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
    /// EDIT MODE (T-ruled): the platform idiom for "destructive controls appear". In Edit, Load/Eject
    /// are suppressed and Delete shows on every installed row — so there's no third control in the
    /// normal row and the one-row-per-pill rule holds by construction.
    @State private var editing = false
    @State private var pendingDelete: PendingDelete?
    /// PRE-LOAD memory heads-up (the Mac's pattern): a big model previews the Host's §18 notice and
    /// confirms BEFORE the ~20s load — guaranteed-visible, not a post-load banner that scrolls away.
    @State private var pendingLoad: PendingLoad?

    private struct PendingLoad: Identifiable {
        let tag: String, display: String, notice: String
        var id: String { tag }
    }

    /// Row Load tapped. Preview the memory notice; if big → confirm first, else load directly.
    private func requestLoad(_ model: CatalogModel) {
        Task {
            if let notice = await catalog.previewLoad(model.tag) {
                pendingLoad = PendingLoad(tag: model.tag, display: model.display, notice: notice)
            } else {
                await catalog.load(model.tag)
            }
        }
    }
    /// "More models" (no walled garden): install any Ollama model by name. It arrives UNVERIFIED and
    /// is probed on first load, exactly like a curated pick. A full library browser is a later arc;
    /// there's no clean Ollama library-index API, so this is install-by-name.
    @State private var showInstallByName = false
    @State private var installName = ""

    /// One pending delete confirmation. `hostRefusal` nil = an EJECTED model (phone confirm copy);
    /// non-nil = a RESIDENT model, carrying the Host's own 409 `eject_first` message shown verbatim
    /// → confirming does eject-then-delete in ONE gate.
    private struct PendingDelete: Identifiable {
        let tag: String, display: String
        let sizeGB: Int
        let hostRefusal: String?
        var id: String { tag }
    }
    private func gbInt(_ b: Int64) -> Int { b > 0 ? Int((Double(b) / 1e9).rounded()) : 0 }

    /// Row Delete tapped. Resident → elicit the Host's 409 message (nothing deleted) and show it
    /// verbatim; ejected → a plain phone confirmation. Either way, ONE confirmation follows.
    private func requestDelete(_ model: CatalogModel) {
        if model.isResident {
            Task {
                if let msg = await catalog.attemptDelete(model.tag) {
                    pendingDelete = PendingDelete(tag: model.tag, display: model.display, sizeGB: gbInt(model.sizeBytes), hostRefusal: msg)
                }
            }
        } else {
            pendingDelete = PendingDelete(tag: model.tag, display: model.display, sizeGB: gbInt(model.sizeBytes), hostRefusal: nil)
        }
    }

    // Same gate as the pill: the THINKING toggle appears only when the resident model actually
    // honors think:false (measured). A model that reasons regardless never shows a toggle.
    private var canToggleThinking: Bool { catalog.resident?.thinkingToggleable == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let err = catalog.lastActionError {
                    actionErrorBanner(err)
                }
                if !catalog.installed.isEmpty {
                    HStack {
                        Spacer()
                        Button(editing ? "Done" : "Edit") { withAnimation(.easeInOut(duration: 0.2)) { editing.toggle() } }
                            .font(.system(size: 15, weight: editing ? .semibold : .regular))
                            .foregroundStyle(Color(hexString: "1B59C2"))
                    }
                }
                if canToggleThinking {
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
                    if catalog.installed.contains(where: { $0.isResident }) {
                        Button { Task { await catalog.ejectAll() } } label: {
                            Text("Eject all from memory").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.9))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(AppearancePalette.ink.opacity(0.10)))
                        }.buttonStyle(.plain).disabled(catalog.busyTag != nil).padding(.leading, 4).padding(.top, 2)
                    }
                }
                if !catalog.residencyCards.isEmpty {
                    section("MEMORY") {
                        ForEach(Array(catalog.residencyCards.enumerated()), id: \.element.id) { i, card in
                            if i > 0 { divider }
                            residencyRow(card)
                        }
                    }
                    if !catalog.residencyFine.isEmpty {
                        Text(catalog.residencyFine).font(.system(size: 11)).foregroundStyle(AppearancePalette.ink.opacity(0.4)).padding(.horizontal, 4)
                    }
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
        // Exactly ONE grabber — the system's. A hand-drawn Capsule on top of the sheet's own
        // .automatic indicator was stacking two (T's screenshot); keep the standard system one.
        .presentationDragIndicator(.visible)
        // ONE confirmation (T-ruled): Edit is gate 1, this is gate 2; for a resident model the copy
        // IS the Host's 409 eject_first message and confirming ejects-then-deletes (not a 3rd gate).
        .confirmationDialog(
            pendingDelete?.hostRefusal ?? "Delete \(pendingDelete?.display ?? "this model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { pd in
            Button(pd.hostRefusal != nil ? "Eject & Delete" : "Delete", role: .destructive) {
                Task {
                    if pd.hostRefusal != nil { await catalog.ejectThenDelete(pd.tag) }
                    else { await catalog.delete(pd.tag) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pd in
            Text(pd.hostRefusal ?? "This frees \(pd.sizeGB) GB. You'd re-download it to use it again.")
        }
        // §18 PRE-load memory notice — the Host composes the string, we render it before committing
        // the load. Guaranteed-visible (a modal), unlike a post-load banner at the top of a scrolled sheet.
        .confirmationDialog(
            "Load \(pendingLoad?.display ?? "this model")?",
            isPresented: Binding(get: { pendingLoad != nil }, set: { if !$0 { pendingLoad = nil } }),
            titleVisibility: .visible,
            presenting: pendingLoad
        ) { pl in
            Button("Load") { Task { await catalog.load(pl.tag) } }
            Button("Cancel", role: .cancel) {}
        } message: { pl in
            Text(pl.notice)
        }
        .alert("Install a model", isPresented: $showInstallByName) {
            TextField("e.g. mistral or llama3.1:8b", text: $installName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Install") {
                let tag = installName.trimmingCharacters(in: .whitespacesAndNewlines)
                installName = ""
                if !tag.isEmpty { Task { await catalog.install(tag) } }
            }
            Button("Cancel", role: .cancel) { installName = "" }
        } message: {
            Text("Enter any Ollama model name. Uncurated models install unverified and are tested on first load.")
        }
        .task { await catalog.refresh(); await catalog.fetchResidency() } // fetch on sheet-open, off the render path
    }

    private var divider: some View { Divider().overlay(AppearancePalette.ink.opacity(0.08)) }

    // The Host's refusal for a failed load/eject/download (e.g. 507 "Not enough disk space…"),
    // shown verbatim so the action doesn't just silently revert. Dismissable; also cleared when
    // the next action starts.
    private func actionErrorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(Color(hexString: "C2571B"))
            Text(text).font(.system(size: 13)).foregroundStyle(AppearancePalette.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { catalog.lastActionError = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            }.buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hexString: "C2571B").opacity(0.10)))
    }

    @ViewBuilder private func rows(_ models: [CatalogModel]) -> some View {
        ForEach(Array(models.enumerated()), id: \.element.id) { i, m in
            if i > 0 { divider }
            ModelSheetRow(model: m, catalog: catalog, editing: editing, onDelete: requestDelete, onLoad: requestLoad)
        }
    }

    /// One residency-mode card — name (+ recommended) · ruled description · active check. Copy is the
    /// Host's (from /v1/residency), never phone-authored.
    @ViewBuilder private func residencyRow(_ card: ResidencyModeCard) -> some View {
        Button { Task { await catalog.setResidencyMode(card.id) } } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(card.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
                        if card.recommended {
                            Text("recommended").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color(hexString: "1B59C2")))
                        }
                    }
                    Text(card.description).font(.system(size: 12)).foregroundStyle(AppearancePalette.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if catalog.residencyMode == card.id {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Color(hexString: "1B59C2"))
                }
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func section<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.4)).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 18).fill(AppearancePalette.ink.opacity(0.05)))
        }
    }

    // No walled garden: install any Ollama model by name (it arrives unverified, probed on load).
    private var moreModelsStub: some View {
        Button { showInstallByName = true } label: {
            HStack {
                Text("More models").font(.system(size: 15, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.8))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                Spacer()
                Text("install any model by name").font(.system(size: 11)).foregroundStyle(AppearancePalette.ink.opacity(0.4))
            }.padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// One model row: name + (blue "in memory" badge on the resident) + Eject/Load/Download, and the
/// FULL curated copy always-visible (T's ruling). The metadata line names thinking support via
/// `thinkingCopy` — the honest ladder over BOTH measured traits (can-think + can-be-told-not-to).
private struct ModelSheetRow: View {
    let model: CatalogModel
    var catalog: HostCatalog
    var editing: Bool = false
    var onDelete: (CatalogModel) -> Void = { _ in }
    var onLoad: (CatalogModel) -> Void = { _ in }

    private var meta: String {
        var parts = ["\(gb(model.sizeBytes))"]
        // "tools" is shown via the MEASURED toolsCopy, not the raw inherited capability, so the
        // claim can't read as verified when it isn't (it was false on the wire once — a receipt now).
        let caps = model.capabilities.filter { $0 != "tools" }
        if !caps.isEmpty { parts.append(caps.joined(separator: ", ")) }
        parts.append(model.thinkingCopy)
        if let toolsCopy = model.toolsCopy { parts.append(toolsCopy) }
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
            // Live download progress — the Host streams {phase, percent}; no more frozen "Working…".
            if catalog.busyTag == model.tag, let pct = catalog.busyPercent {
                ProgressView(value: Double(pct), total: 100)
                    .tint(Color(hexString: "1B59C2"))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var action: some View {
        let busy = catalog.busyTag == model.tag
        if editing {
            // Edit mode (T-ruled): Load/Eject SUPPRESSED; Delete on every installed row. This is the
            // only place a third control lives, and it replaces the others — the row never crowds.
            if model.isInstalled {
                Button { onDelete(model) } label: {
                    Text("Delete").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(busy ? AppearancePalette.ink.opacity(0.4) : Color(hexString: "C7362F"))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color(hexString: "C7362F").opacity(0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(busy || catalog.busyTag != nil)
            }
        } else if model.isResident {
            actionPill("Eject", ghost: true, busy: busy) { await catalog.eject(model.tag) }
        } else if model.isInstalled {
            // Route through onLoad → previews the §18 memory notice and confirms before a big load.
            actionPill("Load", ghost: false, busy: busy) { onLoad(model) }
        } else {
            actionPill("Download", ghost: false, busy: busy) { await catalog.install(model.tag) }
        }
    }

    private func actionPill(_ title: String, ghost: Bool, busy: Bool, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            // While downloading, the label counts up (busyPercent); a LOAD shimmers "Working…"
            // (no progress events → honest "in progress", not an invented percentage).
            Text(busy ? (catalog.busyPercent.map { "\($0)%" } ?? "Working…") : title).font(.system(size: 13, weight: .semibold))
                .composerShimmer(busy && catalog.busyPercent == nil)
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
