import SwiftUI

/// Stage 4.4 — temporary in-app dev panel for tuning the four `EntryCard`
/// visual values (body treatment, typography, corner radius, inter-card
/// spacing) on device. Mounted globally at `ContentView` root so the
/// summon button is reachable from canvas, list, detail, and QuikCapture.
///
/// **Self-deleting infrastructure.** Once T locks a combination, commit 2
/// migrates the locked values to `EntryCardMetrics` production constants
/// and commit 3 deletes this file outright along with
/// `EntryVisualSettings`. See `Ops/briefs/stage-4-4-entry-visual-refinement.md`
/// for the full three-commit shape.
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
                    typographySection(settings: settings)
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

    // MARK: - Sections

    @ViewBuilder
    private func bodyTreatmentSection(settings: EntryVisualSettings) -> some View {
        sectionHeader("Card body treatment")
        Picker("Body treatment", selection: Binding(
            get: { settings.bodyTreatment },
            set: { settings.bodyTreatment = $0 }
        )) {
            ForEach(EntryVisualSettings.BodyTreatment.allCases) { choice in
                Text(choice.rawValue).tag(choice)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func typographySection(settings: EntryVisualSettings) -> some View {
        // Stage 4.4 — typography expanded to 5 families (SF Pro / New York
        // / Lato / Fraunces / Lora). Menu style trades the segmented row's
        // visible-all-options affordance for a single compact button that
        // shows the current pick and pops a list. Sized vs. the sliders
        // below: keeps the sheet's medium detent comfortable.
        sectionRowHeader("Typography", value: settings.typography.rawValue)
        Picker("Typography", selection: Binding(
            get: { settings.typography },
            set: { settings.typography = $0 }
        )) {
            ForEach(EntryVisualSettings.TypographyChoice.allCases) { choice in
                Text(choice.rawValue).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .tint(.white.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .labelsHidden()
    }

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
