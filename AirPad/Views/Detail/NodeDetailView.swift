import SwiftUI
import AVKit
import AVFoundation

/// Full node detail view. Entered via NavigationStack zoom transition from the canvas.
/// All edits auto-save on disappear.
struct NodeDetailView: View {

    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // Editable fields (mirrored from node, written back on disappear)
    @State private var editedTitle = ""
    @State private var editedSummary = ""
    @State private var editedTags: [String] = []

    @FocusState private var focusedField: Bool

    // "Add item" mini-fan state
    @State private var captureMode: CaptureMode? = nil
    @State private var showPromoteConfirmation = false
    @State private var showingNewTagSheet = false

    @State private var bgPhase: Double = 0

    private let circleColors: [(String, String, String)] = [
        ("9B6FE8", "F5C5A3", "E36B4E"),
        ("5B8FFF", "A78BFA", "F472B6"),
        ("34D399", "60A5FA", "A78BFA"),
        ("FB923C", "FBBF24", "E36B4E"),
        ("F472B6", "FB7185", "C084FC"),
        ("22D3EE", "34D399", "60A5FA"),
        ("A78BFA", "818CF8", "E36B4E"),
    ]

    private var paletteIndex: Int {
        guard let tagName = node?.primaryTag else { return 0 }
        return abs(tagName.hashValue) % 7
    }

    @ViewBuilder
    private var animatedBackground: some View {
        let colors = circleColors[paletteIndex % circleColors.count]
        TimelineView(.animation) { timeline in
            ZStack {
                Color(red: 0.027, green: 0.027, blue: 0.039)
                let time = timeline.date.timeIntervalSinceReferenceDate
                Circle()
                    .fill(Color(hexString: colors.0))
                    .frame(width: 320, height: 320)
                    .blur(radius: 80)
                    .offset(x: -80 + sin(time * 0.2 + bgPhase * 1.3) * 40,
                            y: -200 + cos(time * 0.15 + bgPhase * 0.9) * 40)
                Circle()
                    .fill(Color(hexString: colors.1))
                    .frame(width: 280, height: 280)
                    .blur(radius: 80)
                    .offset(x: 60 + sin(time * 0.25 + bgPhase * 1.7) * 40,
                            y: 100 + cos(time * 0.2 + bgPhase * 1.1) * 40)
                Circle()
                    .fill(Color(hexString: colors.2))
                    .frame(width: 240, height: 240)
                    .blur(radius: 80)
                    .offset(x: sin(time * 0.3 + bgPhase * 2.1) * 40,
                            y: 350 + cos(time * 0.25 + bgPhase * 0.7) * 40)
            }
        }
        .ignoresSafeArea()
    }

    enum CaptureMode: String, Identifiable {
        case voice, text, camera
        var id: String { rawValue }
    }

    private var node: Node? {
        store.nodes.first { $0.id == nodeID }
    }

    var body: some View {
        Group {
            if let node {
                content(node: node)
            } else {
                Text("Node not found")
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .onAppear {
            store.isInDetailView = true
            if let node {
                editedTitle   = node.title
                editedSummary = node.summary
                editedTags    = node.tags
            }
            bgPhase = Double.random(in: 0...100)
        }
        .onDisappear {
            store.isInDetailView = false
            saveIfChanged()
        }
        .confirmationDialog(
            "Make it permanent?",
            isPresented: $showPromoteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Promote to true node", role: .destructive) {
                Task { await store.promoteMetaNode(nodeID: nodeID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This makes it a permanent part of your corpus. Can't be undone.")
        }
        .sheet(item: $captureMode) { mode in
            switch mode {
            case .voice:  VoiceCaptureSheet(targetNodeID: nodeID)
            case .text:   TextCaptureSheet(targetNodeID: nodeID)
            case .camera: CameraCaptureView(targetNodeID: nodeID)
            }
        }
        .sheet(isPresented: $showingNewTagSheet) {
            TagEditorSheet(existing: nil) { createdName in
                if !editedTags.contains(createdName) {
                    editedTags.append(createdName)
                }
            }
        }
    }

    // MARK: - Main content

    private func content(node: Node) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title
                TextField("Title", text: $editedTitle, axis: .vertical)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused($focusedField)

                // Summary
                if !editedSummary.isEmpty || node.summary.isEmpty {
                    TextField("Summary", text: $editedSummary, axis: .vertical)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.75))
                        .tint(.white)
                        .focused($focusedField)
                }

                // Tags
                tagsRow

                Divider().background(Color.white.opacity(0.12))

                // Items
                ForEach(node.items) { item in
                    ItemRow(item: item, nodeID: nodeID)
                }

                // Domain suggestion card
                if let domain = node.domain, !node.domainConfirmed {
                    DomainSuggestionCard(domain: domain, nodeID: nodeID)
                }

                // Meta-node provenance + promotion
                if node.isMeta {
                    MetaNodeBanner(nodeID: nodeID, showPromoteConfirmation: $showPromoteConfirmation)
                }

                // Add item
                addItemButton
            }
            .padding(20)
        }
        .background { animatedBackground }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Tags row

    private var tagsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(editedTags, id: \.self) { name in
                    TagChip(name: name, store: store) {
                        editedTags.removeAll { $0 == name }
                    }
                }
                // Add from vocabulary
                Menu {
                    let available = store.tags.filter { !editedTags.contains($0.name) }
                    if !available.isEmpty {
                        ForEach(available) { tag in
                            Button(tag.name) {
                                if !editedTags.contains(tag.name) {
                                    editedTags.append(tag.name)
                                }
                            }
                        }
                        Divider()
                    }
                    Button {
                        showingNewTagSheet = true
                    } label: {
                        Label("New tag…", systemImage: "plus")
                    }
                } label: {
                    Label("Add tag", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Add item button

    private var addItemButton: some View {
        HStack(spacing: 12) {
            Text("Add item")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Button { captureMode = .voice } label: {
                Image(systemName: "mic.fill")
                    .miniCapture()
            }
            Button { captureMode = .camera } label: {
                Image(systemName: "camera.fill")
                    .miniCapture()
            }
            Button { captureMode = .text } label: {
                Image(systemName: "pencil")
                    .miniCapture()
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Auto-save

    private func saveIfChanged() {
        guard let node else { return }
        var updated = node
        var changed = false
        if updated.title != editedTitle { updated.title = editedTitle; changed = true }
        if updated.summary != editedSummary { updated.summary = editedSummary; changed = true }
        if updated.tags != editedTags {
            updated.tags = editedTags
            // User-edited tags carry .user provenance; drop sources for removed tags.
            let editedSet = Set(editedTags)
            for name in editedTags { updated.tagSources[name] = TagOrigin(source: .user) }
            for name in updated.tagSources.keys where !editedSet.contains(name) {
                updated.tagSources.removeValue(forKey: name)
            }
            changed = true
        }
        guard changed else { return }
        updated.updatedAt = Date()
        Task { await store.updateNode(updated) }
    }
}

// MARK: - Tag chip

private struct TagChip: View {
    let name: String
    let store: CorpusStore
    let onRemove: () -> Void

    private var color: Color {
        if let tag = store.tags.first(where: { $0.name == name }) {
            return Color(hex: tag.colorHex) ?? .gray
        }
        return .gray
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.3))
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .clipShape(Capsule())
    }
}

// MARK: - Item row

private struct ItemRow: View {
    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var imageURL: URL? = nil
    @State private var editingText = ""
    @State private var isEditingText = false
    @FocusState private var textEditorFocused: Bool

    var body: some View {
        switch item.type {
        case .text:
            textRow
        case .audio:
            audioRow
        case .image:
            imageRow
        case .video:
            videoRow
        case .link:
            linkRow
        case .document:
            documentRow
        }
    }

    // MARK: Text

    private var textRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingText {
                TextEditor(text: $editingText)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.white)
                    .font(.body)
                    .frame(minHeight: 80)
                    .padding(12)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($textEditorFocused)
            } else {
                Text(item.content ?? "")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture {
                        editingText = item.content ?? ""
                        isEditingText = true
                    }
            }
            itemMeta
        }
    }

    // MARK: Audio

    private var audioRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            AudioPlayerRow(item: item, nodeID: nodeID)
            if let transcript = item.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 12)
            }
            itemMeta
        }
    }

    // MARK: Image

    private var imageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = imageURL {
                AsyncImageFromURL(url: url)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 200)
                    .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)))
                    .onAppear { loadImageURL() }
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
            }
            itemMeta
        }
    }

    // MARK: Video

    private var videoRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = imageURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 200)
                    .overlay(Image(systemName: "video").foregroundStyle(.white.opacity(0.3)))
                    .onAppear { loadImageURL() }
            }
            if let transcript = item.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)
            }
            itemMeta
        }
    }

    // MARK: Link

    private var linkRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = item.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let preview = item.preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            if let urlString = item.url, let url = URL(string: urlString) {
                Link(urlString, destination: url)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .lineLimit(1)
            }
            itemMeta
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Document

    private var documentRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file?.components(separatedBy: "/").last ?? "Document")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                if let description = item.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
            }
            Spacer()
            itemMeta
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Helpers

    private var itemMeta: some View {
        Text(item.createdAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
        + Text(" ago")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
    }

    private func loadImageURL() {
        Task {
            imageURL = await store.itemFileURL(for: item, nodeID: nodeID)
        }
    }
}

// MARK: - Audio player row

private struct AudioPlayerRow: View {
    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var player: AVAudioPlayer? = nil
    @State private var isPlaying = false
    @State private var url: URL? = nil

    var body: some View {
        HStack(spacing: 14) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let duration = item.durationSeconds {
                    Text(formatDuration(duration))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { loadURL() }
    }

    private func loadURL() {
        Task {
            url = await store.itemFileURL(for: item, nodeID: nodeID)
        }
    }

    private func togglePlayback() {
        guard let url else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if player == nil {
                player = try? AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
            }
            player?.play()
            isPlaying = true
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Async image from URL

private struct AsyncImageFromURL: View {
    let url: URL
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 200)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .onAppear {
            Task {
                if let data = try? Data(contentsOf: url) {
                    image = UIImage(data: data)
                }
            }
        }
    }
}

// MARK: - Domain suggestion card

private struct DomainSuggestionCard: View {
    let domain: String
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This looks like \(domain) content — want me to optimise how it's stored?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                VStack(spacing: 6) {
                    Button("Yes") {
                        Task {
                            guard var node = store.nodes.first(where: { $0.id == nodeID }) else { return }
                            node.domainConfirmed = true
                            await store.updateNode(node)
                        }
                        dismissed = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)

                    Button("No") { dismissed = true }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(14)
            .background(Color.yellow.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Meta-node banner

private struct MetaNodeBanner: View {
    let nodeID: String
    @Binding var showPromoteConfirmation: Bool
    @Environment(CorpusStore.self) private var store

    private var provenanceNodes: [Node] {
        guard let node = store.nodes.first(where: { $0.id == nodeID }),
              let provenance = node.provenance else { return [] }
        return provenance.compactMap { id in store.nodes.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("✦")
                    .foregroundStyle(.purple.opacity(0.8))
                Text("Thread node")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            let sources = provenanceNodes
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected from")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                    ForEach(sources) { source in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.white.opacity(0.2))
                                .frame(width: 5, height: 5)
                            Text(source.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
            }

            Button {
                showPromoteConfirmation = true
            } label: {
                Text("Promote to true node")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.purple.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.purple.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .foregroundStyle(Color.purple.opacity(0.4))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Mini capture button style

private extension View {
    func miniCapture() -> some View {
        self
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.1))
            .clipShape(Circle())
    }
}
