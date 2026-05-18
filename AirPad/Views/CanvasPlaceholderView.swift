import SwiftUI

struct CanvasPlaceholderView: View {

    @Environment(CorpusStore.self) private var store
    @State private var showingCapture = false
    @State private var selectedNodeID: String?

    private let nodeRadius: CGFloat = 36

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if store.nodes.isEmpty {
                    EmptyCorpusView()
                }

                // Nodes as positioned circles
                ForEach(store.nodes) { node in
                    let pos = store.canvasLayout.positions[node.id]
                    let x = geometry.size.width / 2 + CGFloat(pos?.x ?? 0)
                    let y = geometry.size.height / 2 + CGFloat(pos?.y ?? 0)

                    NodeBubble(
                        node: node,
                        isSelected: selectedNodeID == node.id,
                        radius: nodeRadius
                    )
                    .position(x: x, y: y)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25)) {
                            selectedNodeID = selectedNodeID == node.id ? nil : node.id
                        }
                    }
                }

                // Title overlay for selected node
                if let id = selectedNodeID,
                   let node = store.nodes.first(where: { $0.id == id }) {
                    NodeTitleOverlay(node: node) {
                        withAnimation(.spring(response: 0.25)) {
                            selectedNodeID = nil
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            AddButton { showingCapture = true }
                .padding(24)
        }
        .sheet(isPresented: $showingCapture) {
            TextCaptureSheet()
        }
    }
}

// MARK: - Empty state

private struct EmptyCorpusView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("I haven't any idea(s).")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.4))
            Text("Add one!")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.3))
        }
    }
}

// MARK: - Node bubble

private struct NodeBubble: View {
    let node: Node
    let isSelected: Bool
    let radius: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(isSelected ? Color.white : Color.white.opacity(0.75))
                .frame(width: radius * 2, height: radius * 2)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.blue, lineWidth: 2)
                    }
                }
                .shadow(color: .white.opacity(0.15), radius: 8)

            Text(node.title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .frame(maxWidth: radius * 2 + 24)
        }
    }
}

// MARK: - Title overlay

private struct NodeTitleOverlay: View {
    let node: Node
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(node.title)
                .font(.headline)
                .foregroundStyle(.white)

            if !node.summary.isEmpty {
                Text(node.summary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                itemCountLabel(for: node)
                Spacer()
                Text(node.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    + Text(" ago")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
        .onTapGesture { onDismiss() }
    }

    @ViewBuilder
    private func itemCountLabel(for node: Node) -> some View {
        let counts = ItemCounts(node.items)
        HStack(spacing: 6) {
            if counts.text > 0 { Label("\(counts.text)", systemImage: "text.alignleft").font(.caption) }
            if counts.image > 0 { Label("\(counts.image)", systemImage: "photo").font(.caption) }
            if counts.audio > 0 { Label("\(counts.audio)", systemImage: "mic").font(.caption) }
            if counts.video > 0 { Label("\(counts.video)", systemImage: "video").font(.caption) }
            if counts.link     > 0 { Label("\(counts.link)",     systemImage: "link").font(.caption) }
            if counts.document > 0 { Label("\(counts.document)", systemImage: "doc").font(.caption) }
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}

private struct ItemCounts {
    var text = 0; var image = 0; var audio = 0; var video = 0; var link = 0; var document = 0
    init(_ items: [NodeItem]) {
        for item in items {
            switch item.type {
            case .text:     text += 1
            case .image:    image += 1
            case .audio:    audio += 1
            case .video:    video += 1
            case .link:     link += 1
            case .document: document += 1
            case .imageVideo: image += 1
            }
        }
    }
}

// MARK: - Add button

private struct AddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(.white)
                .clipShape(Circle())
                .shadow(color: .white.opacity(0.2), radius: 8, y: 2)
        }
    }
}

#Preview {
    CanvasPlaceholderView()
        .environment(CorpusStore())
}
