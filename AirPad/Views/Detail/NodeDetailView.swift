import SwiftUI
import AVKit
import AVFoundation
import UIKit

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

    // "Add entry" floating "+" state. Stage 3.1a commit (c) replaced the
    // inline bottom composer triad with a single floating Menu button that
    // routes to one of six entry types.
    @State private var captureMode: CaptureMode? = nil
    @State private var showPromoteConfirmation = false
    @State private var showingNewTagSheet = false
    @State private var showDeleteConfirmation = false
    @State private var keyboardVisible = false
    @State private var showLinkAddAlert = false
    @State private var linkDraft = ""
    @State private var showDocumentPicker = false

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

    /// In-node capture surfaces. `.text` is intentionally absent: the "+"
    /// menu's Text action now appends an empty entry card inline (see
    /// `store.appendEmptyTextItem`) rather than presenting a sheet. Voice
    /// and Camera stay sheet-based because their capture flows are
    /// genuinely modal (recording session / camera viewfinder), not
    /// append-and-type.
    enum CaptureMode: String, Identifiable {
        case voice, camera
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
            // Stage 3.1a — first-open lazy migration to the entry-primitive
            // schema. No-op once the node's entrySchemaVersion is current.
            Task { await store.ensureEntrySchema(forNodeID: nodeID) }
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
        .confirmationDialog(
            "Delete this node?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.deleteNode(id: nodeID)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the node and all its items. Can't be undone.")
        }
        .sheet(item: $captureMode) { mode in
            switch mode {
            case .voice:  VoiceCaptureSheet(targetNodeID: nodeID)
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
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView { url in
                Task { await store.appendDocumentItem(nodeID: nodeID, sourceURL: url) }
            }
        }
        .alert("Add link", isPresented: $showLinkAddAlert) {
            TextField("https://example.com", text: $linkDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") { saveLink() }
        } message: {
            Text("Paste or type a URL to add it as a link entry.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { keyboardVisible = false }
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

                // Items — Stage 3.1a commit (b): every entry is rendered as
                // an `EntryCard` regardless of type. Per-type rendering lives
                // in `Views/Detail/Entry/*EntryBody.swift`.
                ForEach(node.items) { item in
                    EntryCard(item: item, nodeID: nodeID)
                }

                // Domain suggestion card
                if let domain = node.domain, !node.domainConfirmed {
                    DomainSuggestionCard(domain: domain, nodeID: nodeID)
                }

                // Meta-node provenance + promotion
                if node.isMeta {
                    MetaNodeBanner(nodeID: nodeID, showPromoteConfirmation: $showPromoteConfirmation)
                }

                // Trailing spacer so the last entry isn't tucked under the
                // floating "+" button. 80pt clears the 56pt button + 24pt
                // bottom inset with a small breathing margin.
                Spacer(minLength: 80)
            }
            .padding(20)
            .dismissKeyboardOnTapOutside()
        }
        .overlay(alignment: .bottomTrailing) {
            // Stage 3.1a commit (c) — floating "+" replaces the inline
            // composer triad. Hidden whenever the keyboard is visible so
            // it doesn't crowd active text input (title, summary, or any
            // RichTextEditor body via accessory toolbar).
            if !keyboardVisible {
                floatingAddButton
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.white.opacity(0.85))
                }
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
                    TagPickerMenuContent(
                        tags: store.tags,
                        excludeNames: Set(editedTags),
                        onPickExisting: { name in
                            if !editedTags.contains(name) {
                                editedTags.append(name)
                            }
                        },
                        onAddNew: { showingNewTagSheet = true }
                    )
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

    // MARK: - Floating "+" button (Stage 3.1a commit (c))

    /// Single entry point for adding entries. Bottom-right 56×56 white
    /// circle matching the canvas/list `ActionButtonFan` styling, but
    /// wired to a native SwiftUI `Menu` rather than the fan animation —
    /// the dropdown is the right grammar inside a detail view, the fan
    /// is the right grammar on the empty canvas. Order locked by brief:
    /// Text, Camera, Voice, Link, Document, More... (More... is a
    /// no-op stub seat for 3.1a; the eventual sheet ships when there's
    /// something to put in it).
    private var floatingAddButton: some View {
        Menu {
            Button {
                // Inline append: create an empty text entry, expanded, and
                // mark it for autofocus so the body's editor raises the
                // keyboard on appearance. No sheet — the card itself is
                // the writing surface inside a node.
                Task { await store.appendEmptyTextItem(nodeID: nodeID) }
            } label: {
                Label("Text", systemImage: "pencil")
            }
            Button { captureMode = .camera } label: {
                Label("Camera", systemImage: "camera.fill")
            }
            Button { captureMode = .voice } label: {
                Label("Voice", systemImage: "mic.fill")
            }
            Button {
                linkDraft = ""
                showLinkAddAlert = true
            } label: {
                Label("Link", systemImage: "link")
            }
            Button {
                showDocumentPicker = true
            } label: {
                Label("Document", systemImage: "doc.fill")
            }
            Divider()
            // Stage 3.1a stub — closure is intentionally empty. The menu
            // seat is reserved for a future full-screen entry-type picker
            // that ships when there are types beyond the basic six.
            Button {} label: {
                Label("More…", systemImage: "ellipsis")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(.white)
                .clipShape(Circle())
                .shadow(color: .white.opacity(0.15), radius: 8, y: 2)
        }
    }

    // MARK: - Link add

    private func saveLink() {
        let trimmed = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await store.appendLinkItem(nodeID: nodeID, urlString: trimmed) }
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

// MARK: - Voice waveform player

/// Stage 3.1a commit (b) Phase 2 — `private` dropped so `VoiceEntryBody`
/// (in `Views/Detail/Entry/`) can reference this player. Nested helpers
/// (`WaveformBars`, `AudioPlaybackController`, `CachedPeaks`) remain private
/// since they're only used inside this file.
struct VoiceWaveformPlayer: View {
    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @State private var controller = AudioPlaybackController()
    @State private var peaks: [Float] = []
    @State private var isDragging = false

    private static let barCount = 56
    private static let dragActivationThreshold: CGFloat = 5

    var body: some View {
        HStack(spacing: 12) {
            scrubbableWaveform

            if let duration = item.durationSeconds {
                Text(formatDuration(duration))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await load()
        }
        .onDisappear {
            controller.stop()
        }
    }

    private var scrubbableWaveform: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                waveformVisual
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geo.size.width))
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    @ViewBuilder
    private var waveformVisual: some View {
        if peaks.isEmpty {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.white.opacity(0.18))
                .frame(height: 2)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !controller.isPlaying && !isDragging)) { _ in
                WaveformBars(peaks: peaks, progress: controller.progress)
            }
            .frame(height: 32)
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved = abs(value.translation.width) > Self.dragActivationThreshold
                    || abs(value.translation.height) > Self.dragActivationThreshold
                if moved { isDragging = true }
                if isDragging, width > 0 {
                    let p = max(0, min(1, Double(value.location.x / width)))
                    controller.seek(toProgress: p)
                }
            }
            .onEnded { _ in
                if !isDragging {
                    controller.toggle()
                }
                isDragging = false
            }
    }

    private func load() async {
        guard let url = await store.itemFileURL(for: item, nodeID: nodeID) else { return }
        controller.prepare(url: url)
        let computed = await Self.loadOrComputePeaks(audioURL: url, barCount: Self.barCount)
        await MainActor.run { peaks = computed }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Peaks pipeline

    private struct CachedPeaks: Codable {
        let version: Int
        let barCount: Int
        let peaks: [Float]
    }

    private static let peaksFormatVersion = 1

    private static func loadOrComputePeaks(audioURL: URL, barCount: Int) async -> [Float] {
        let peaksURL = audioURL.deletingPathExtension().appendingPathExtension("peaks")

        if let data = try? Data(contentsOf: peaksURL),
           let cached = try? JSONDecoder().decode(CachedPeaks.self, from: data),
           cached.version == peaksFormatVersion,
           cached.barCount == barCount,
           cached.peaks.count == barCount {
            return cached.peaks
        }

        let computed = await computePeaks(audioURL: audioURL, barCount: barCount)
        if computed.count == barCount {
            let cached = CachedPeaks(version: peaksFormatVersion, barCount: barCount, peaks: computed)
            if let data = try? JSONEncoder().encode(cached) {
                try? data.write(to: peaksURL, options: .atomic)
            }
        }
        return computed
    }

    private static func computePeaks(audioURL: URL, barCount: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: audioURL)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                return [Float]()
            }

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]

            guard let reader = try? AVAssetReader(asset: asset) else { return [Float]() }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(output)
            guard reader.startReading() else { return [Float]() }

            let durationCMTime = (try? await asset.load(.duration)) ?? .zero
            let durationSeconds = durationCMTime.seconds
            var sampleRate: Double = 44100
            if let formats = try? await track.load(.formatDescriptions), let desc = formats.first {
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    sampleRate = basic.pointee.mSampleRate
                }
            }
            let totalSamples = max(barCount, Int(durationSeconds * sampleRate))
            let samplesPerBar = max(1, totalSamples / barCount)

            var bars = [Float](repeating: 0, count: barCount)
            var barIndex = 0
            var sampleInBar = 0
            var maxInBar: Float = 0

            while reader.status == .reading, barIndex < barCount {
                guard let buffer = output.copyNextSampleBuffer(),
                      let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { break }

                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: base
                    )
                }
                CMSampleBufferInvalidate(buffer)

                data.withUnsafeBytes { raw in
                    let pcm = raw.bindMemory(to: Int16.self)
                    for s in pcm {
                        let v = Float(abs(Int(s))) / Float(Int16.max)
                        if v > maxInBar { maxInBar = v }
                        sampleInBar += 1
                        if sampleInBar >= samplesPerBar && barIndex < barCount {
                            bars[barIndex] = maxInBar
                            barIndex += 1
                            sampleInBar = 0
                            maxInBar = 0
                        }
                    }
                }
            }
            while barIndex < barCount {
                bars[barIndex] = 0
                barIndex += 1
            }

            let peak = bars.max() ?? 0
            if peak > 0 {
                bars = bars.map { $0 / peak }
            }
            // Floor so quiet segments still show a visible tick.
            return bars.map { max(0.08, $0) }
        }.value
    }
}

// MARK: - Waveform bars

private struct WaveformBars: View {
    let peaks: [Float]
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let barCount = peaks.count
            let spacing: CGFloat = 2
            let totalSpacing = CGFloat(max(0, barCount - 1)) * spacing
            let barWidth = max(1, (geo.size.width - totalSpacing) / CGFloat(max(1, barCount)))
            let height = geo.size.height
            let minBarHeight: CGFloat = 3
            let progressThreshold = progress * Double(barCount)
            let kleinBlue = Color(hexString: "1B59C2")
            let rest = Color.white.opacity(0.30)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let h = max(minBarHeight, CGFloat(peaks[i]) * height)
                    let played = Double(i) < progressThreshold
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(played ? kleinBlue : rest)
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(width: geo.size.width, height: height, alignment: .center)
        }
    }
}

// MARK: - Audio playback controller

@Observable
@MainActor
private final class AudioPlaybackController: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var url: URL?
    private var pollTimer: Timer?

    var progress: Double {
        duration > 0 ? min(1.0, currentTime / duration) : 0
    }

    func prepare(url: URL) {
        self.url = url
    }

    func toggle() {
        guard let url else { return }
        if isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopPolling()
        deactivateSession()
    }

    /// Seek to a fractional position in [0, 1]. Lazily creates the player if needed
    /// so scrubbing works before the user has ever pressed play. Does not start playback.
    func seek(toProgress progress: Double) {
        guard let url else { return }
        if player == nil {
            guard configureSessionForPlayback() else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                player = p
                duration = p.duration
            } catch {
                print("[VoicePlayback] Player init for seek failed: \(error)")
                return
            }
        }
        guard let player else { return }
        let clamped = max(0, min(1, progress))
        let target = clamped * player.duration
        player.currentTime = target
        currentTime = target
    }

    private func play(url: URL) {
        guard configureSessionForPlayback() else { return }

        if player == nil {
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                player = p
                duration = p.duration
            } catch {
                print("[VoicePlayback] Player init failed: \(error)")
                return
            }
        }

        guard let player else { return }
        player.play()
        isPlaying = true
        startPolling()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopPolling()
    }

    private func configureSessionForPlayback() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            return true
        } catch {
            print("[VoicePlayback] Audio session configure failed: \(error)")
            return false
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.player?.currentTime = 0
            self.currentTime = 0
            self.isPlaying = false
            self.stopPolling()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error { print("[VoicePlayback] Decode error: \(error)") }
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.stopPolling()
        }
    }
}

// MARK: - Async image from URL

/// Stage 3.1a commit (b) Phase 2 — `private` dropped so `ImageEntryBody`
/// (in `Views/Detail/Entry/`) can reference this helper. Same rationale as
/// `VoiceWaveformPlayer`: extraction moved the only consumer across a file
/// boundary.
struct AsyncImageFromURL: View {
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

