import SwiftUI

/// Presented after AI processing when new tag names are suggested that don't exist in vocabulary.
/// The user accepts or dismisses each suggestion, picks colors for new tags, then confirms.
struct TagCreationSheet: View {

    let context: TagSuggestionContext

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pendingTags: [PendingTag]  // new tags awaiting color assignment
    @State private var acceptedNames: Set<String> // from newTagNames
    @State private var selectedPendingID: UUID?   // which tag is getting a color right now
    @State private var colorPickerPresented = false

    init(context: TagSuggestionContext) {
        self.context = context
        let initialPending = context.newTagNames.map {
            PendingTag(name: $0, colorHex: Tag.neutralColorHex)
        }
        _pendingTags = State(initialValue: initialPending)
        _acceptedNames = State(initialValue: Set(context.newTagNames))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    headerSection
                    if !context.existingTagNames.isEmpty { existingTagsSection }
                    if !context.newTagNames.isEmpty { newTagsSection }
                }
                .padding(24)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Add Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                        .foregroundStyle(.white.opacity(0.5))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { confirm() }
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
            }
        }
        .presentationBackground(.black)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI suggested these tags")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("New tags need a color. Tap to change.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var existingTagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Applied automatically")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .kerning(0.5)

            FlowLayout(spacing: 8) {
                ForEach(context.existingTagNames, id: \.self) { name in
                    ExistingTagPill(name: name, store: store)
                }
            }
        }
    }

    @ViewBuilder
    private var newTagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New tags")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .kerning(0.5)

            FlowLayout(spacing: 8) {
                ForEach($pendingTags) { $tag in
                    NewTagPill(
                        tag: $tag,
                        isAccepted: acceptedNames.contains(tag.name),
                        onToggle: {
                            if acceptedNames.contains(tag.name) {
                                acceptedNames.remove(tag.name)
                            } else {
                                acceptedNames.insert(tag.name)
                            }
                        },
                        colorPresets: colorPresets
                    )
                }
            }
        }
    }

    // MARK: - Confirm

    private func confirm() {
        Task {
            // Create Tag objects for accepted new tags and save to vocabulary
            var newTagNames: [String] = []
            for pending in pendingTags where acceptedNames.contains(pending.name) {
                let tag = Tag(
                    id: UUID(),
                    name: pending.name,
                    colorHex: pending.colorHex,
                    createdAt: Date(),
                    useCount: 1
                )
                await store.addTag(tag)
                newTagNames.append(pending.name)
            }
            // Apply all accepted tags (new + existing) to the node
            let all = newTagNames + context.existingTagNames
            if !all.isEmpty {
                await store.applyTags(all, toNodeID: context.nodeID)
            }
            dismiss()
        }
    }

    // MARK: - Color presets

    private let colorPresets: [String] = [
        "#FF6B35", "#FF3B30", "#FF9500", "#FFCC00",
        "#34C759", "#00C7BE", "#32ADE6", "#007AFF",
        "#5856D6", "#AF52DE", "#FF2D55", "#A2845E",
        "#636366", "#8E8E93", "#FFFFFF", "#000000"
    ]
}

// MARK: - Supporting types

private struct PendingTag: Identifiable {
    let id = UUID()
    var name: String
    var colorHex: String
}

// MARK: - Existing tag pill (already has a color)

private struct ExistingTagPill: View {
    let name: String
    let store: CorpusStore

    private var color: Color {
        if let tag = store.tags.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return Color(hex: tag.colorHex) ?? .gray
        }
        return .gray
    }

    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.35))
            .overlay(Capsule().stroke(color, lineWidth: 1))
            .clipShape(Capsule())
    }
}

// MARK: - New tag pill (needs color assignment)

private struct NewTagPill: View {
    @Binding var tag: PendingTag
    let isAccepted: Bool
    let onToggle: () -> Void
    let colorPresets: [String]

    @State private var showColorPicker = false

    private var pillColor: Color {
        Color(hex: tag.colorHex) ?? .gray
    }

    var body: some View {
        HStack(spacing: 6) {
            // Color swatch — tap to change color
            Button {
                showColorPicker = true
            } label: {
                Circle()
                    .fill(pillColor)
                    .frame(width: 12, height: 12)
            }

            // Tag name — tap to accept/reject
            Button(action: onToggle) {
                Text(tag.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isAccepted ? .white : .white.opacity(0.35))
                    .strikethrough(!isAccepted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isAccepted ? pillColor.opacity(0.25) : Color.white.opacity(0.06))
        .overlay(Capsule().stroke(isAccepted ? pillColor.opacity(0.6) : Color.white.opacity(0.15), lineWidth: 1))
        .clipShape(Capsule())
        .sheet(isPresented: $showColorPicker) {
            ColorPickerSheet(selectedHex: $tag.colorHex, presets: colorPresets)
        }
    }
}

// MARK: - Color picker sheet

private struct ColorPickerSheet: View {
    @Binding var selectedHex: String
    let presets: [String]
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible()), count: 8)

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(presets, id: \.self) { hex in
                        let color = Color(hex: hex) ?? .gray
                        Circle()
                            .fill(color)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Circle().stroke(
                                    selectedHex == hex ? Color.white : Color.clear,
                                    lineWidth: 2.5
                                )
                            )
                            .onTapGesture {
                                selectedHex = hex
                                dismiss()
                            }
                    }
                }
                .padding(24)
                Spacer()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Pick a Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
    }
}

// MARK: - Flow layout (wrapping HStack)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width + (rowWidth > 0 ? spacing : 0) > maxWidth {
                height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
                rowHeight = max(rowHeight, size.height)
            }
        }
        height += rowHeight
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Color hex extension

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double(value         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8)  & 0xFF) / 255
        let b = CGFloat(value         & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
