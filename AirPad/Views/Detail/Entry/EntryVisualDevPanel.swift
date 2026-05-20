import SwiftUI

/// Stage 4.4 — temporary in-app dev panel for tuning `EntryCard` +
/// `NodeDetailView` visuals on device. Addendum 1a-i expands the typography
/// section from a single family picker to a 4-role type scale (Node Title /
/// Node Summary / Section Title / Section Timestamp), each with independent
/// family / size / weight controls. Mounted globally at `ContentView` root
/// so the summon button is reachable from canvas, list, detail, and
/// QuikCapture.
///
/// **Self-deleting infrastructure.** Once T locks a combination, commit 2
/// migrates the locked values to permanent `AirPadTypeScale` +
/// `EntryCardMetrics` structs and commit 3 deletes this file outright
/// along with `EntryVisualSettings`. Body-role typography is deferred to
/// Stage 2.3.
struct EntryVisualDevPanelHost: View {

    @State private var settings = EntryVisualSettings.shared
    @State private var sheetVisible = false

    var body: some View {
        Group {
            if settings.buttonVisible {
                summonButton
                    .padding(.trailing, 20)
                    .padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $sheetVisible) {
            EntryVisualDevPanelSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    private var summonButton: some View {
        Button {
            sheetVisible = true
        } label: {
            Image(systemName: "paintbrush.pointed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(0.7)
        .accessibilityLabel("Entry visual dev panel")
    }
}

// MARK: - Sheet contents

private struct EntryVisualDevPanelSheet: View {

    @State private var settings = EntryVisualSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    bodyTreatmentSection(settings: settings)
                    Divider().background(Color.white.opacity(0.12))
                    typeScaleSections(settings: settings)
                    Divider().background(Color.white.opacity(0.12))
                    cornerRadiusSection(settings: settings)
                    Divider().background(Color.white.opacity(0.12))
                    interCardSpacingSection(settings: settings)
                    Divider().background(Color.white.opacity(0.12))
                    hideEyeRow
                }
                .padding(20)
            }
            .navigationTitle("Entry Visual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Body treatment

    /// 7 options after the 1a-i glass-variant expansion — too many for a
    /// segmented control on the sheet width. `.menu` matches the picker
    /// style each type-role section uses for the family selector below, so
    /// the panel reads as consistent rows of "label · pop-up of choices."
    @ViewBuilder
    private func bodyTreatmentSection(settings: EntryVisualSettings) -> some View {
        sectionRowHeader("Card body treatment", value: settings.bodyTreatment.rawValue)
        Picker("Body treatment", selection: Binding(
            get: { settings.bodyTreatment },
            set: { settings.bodyTreatment = $0 }
        )) {
            ForEach(EntryVisualSettings.BodyTreatment.allCases) { choice in
                Text(choice.rawValue).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .tint(.white.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .labelsHidden()
    }

    // MARK: - Type scale (4 roles)

    /// Stage 4.4 addendum 1a-i — replaces the single typography menu from
    /// commit 1 with a per-role scale. Each role independently selects
    /// family / size / weight. The caveat row at the foot reminds T that
    /// custom-font weights collapse to a Regular/Bold binary file choice.
    @ViewBuilder
    private func typeScaleSections(settings: EntryVisualSettings) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Type scale")
            ForEach(EntryVisualSettings.Role.allCases) { role in
                typeRoleRow(role: role, settings: settings)
            }
            weightClampingNote
        }
    }

    @ViewBuilder
    private func typeRoleRow(
        role: EntryVisualSettings.Role,
        settings: EntryVisualSettings
    ) -> some View {
        let current = settings.settings(for: role)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(role.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%.1fpt", current.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            // Family — menu picker (5 options); matches the body-treatment
            // picker style above for visual consistency.
            Picker("Family", selection: roleFamilyBinding(role: role, settings: settings)) {
                ForEach(EntryVisualSettings.TypographyChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .tint(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .labelsHidden()

            // Size — slider, 0.5pt step, per-role bounds.
            Slider(
                value: roleSizeBinding(role: role, settings: settings),
                in: Double(role.sizeRange.lowerBound) ... Double(role.sizeRange.upperBound),
                step: 0.5
            )
            .tint(.white.opacity(0.6))

            // Weight — segmented (4 options fits within sheet width).
            Picker("Weight", selection: roleWeightBinding(role: role, settings: settings)) {
                ForEach(EntryVisualSettings.FontWeightChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    /// Inline reminder under the type-scale block. Custom fonts ship
    /// Regular + Bold only (slim 6-file bundle locked with T on
    /// 2026-05-19); the 4-option weight picker compresses to the nearer
    /// .ttf. Stated up front so an off-looking medium/semibold isn't
    /// blamed on the renderer during iteration.
    private var weightClampingNote: some View {
        Text("Custom fonts (Lato / Fraunces / Lora) ship Regular and Bold only; medium clamps to Regular, semibold to Bold. SF Pro and New York honour all four weights.")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Per-role bindings

    /// Bindings are written long-form (not key-paths) because
    /// `EntryVisualSettings` is an `@Observable` class with `didSet`-driven
    /// persistence, and SwiftUI's KeyPath-based bindings would bypass the
    /// observation tracking that fires the `persistRole(...)` call.

    private func roleFamilyBinding(
        role: EntryVisualSettings.Role,
        settings: EntryVisualSettings
    ) -> Binding<EntryVisualSettings.TypographyChoice> {
        Binding(
            get: { settings.settings(for: role).family },
            set: { newValue in updateRole(role, settings: settings) { $0.family = newValue } }
        )
    }

    private func roleSizeBinding(
        role: EntryVisualSettings.Role,
        settings: EntryVisualSettings
    ) -> Binding<Double> {
        Binding(
            get: { Double(settings.settings(for: role).size) },
            set: { newValue in
                let rounded = (newValue * 2).rounded() / 2  // snap to 0.5pt
                updateRole(role, settings: settings) { $0.size = CGFloat(rounded) }
            }
        )
    }

    private func roleWeightBinding(
        role: EntryVisualSettings.Role,
        settings: EntryVisualSettings
    ) -> Binding<EntryVisualSettings.FontWeightChoice> {
        Binding(
            get: { settings.settings(for: role).weight },
            set: { newValue in updateRole(role, settings: settings) { $0.weight = newValue } }
        )
    }

    /// Mutate one role's settings struct atomically. Reads current, applies
    /// the transform, writes back to the matching property — which fires
    /// that property's `didSet` and persists. Keeping this in one helper
    /// avoids having to re-derive the role → property mapping in three
    /// separate binding setters.
    private func updateRole(
        _ role: EntryVisualSettings.Role,
        settings: EntryVisualSettings,
        transform: (inout EntryVisualSettings.TypeRoleSettings) -> Void
    ) {
        var s = settings.settings(for: role)
        transform(&s)
        switch role {
        case .nodeTitle:        settings.nodeTitle = s
        case .nodeSummary:      settings.nodeSummary = s
        case .sectionTitle:     settings.sectionTitle = s
        case .sectionTimestamp: settings.sectionTimestamp = s
        }
    }

    // MARK: - Other live values

    @ViewBuilder
    private func cornerRadiusSection(settings: EntryVisualSettings) -> some View {
        sectionRowHeader(
            "Corner radius",
            value: String(format: "%.0fpt", settings.cornerRadius)
        )
        Slider(
            value: Binding(
                get: { Double(settings.cornerRadius) },
                set: { settings.cornerRadius = CGFloat($0.rounded()) }
            ),
            in: Double(EntryVisualSettings.cornerRadiusRange.lowerBound)
                ... Double(EntryVisualSettings.cornerRadiusRange.upperBound),
            step: 1
        )
        .tint(.white.opacity(0.6))
    }

    @ViewBuilder
    private func interCardSpacingSection(settings: EntryVisualSettings) -> some View {
        sectionRowHeader(
            "Inter-card spacing",
            value: String(format: "%.0fpt", settings.interCardSpacing)
        )
        Slider(
            value: Binding(
                get: { Double(settings.interCardSpacing) },
                set: { settings.interCardSpacing = CGFloat($0.rounded()) }
            ),
            in: Double(EntryVisualSettings.interCardSpacingRange.lowerBound)
                ... Double(EntryVisualSettings.interCardSpacingRange.upperBound),
            step: 1
        )
        .tint(.white.opacity(0.6))
    }

    private var hideEyeRow: some View {
        Button {
            settings.buttonVisible = false
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.body.weight(.medium))
                Text("Hide dev panel button")
                    .font(.body.weight(.medium))
                Spacer()
                Text("Reset via reinstall")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.6))
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func sectionRowHeader(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
