import SwiftUI
import AVFoundation
import Speech

/// Full-screen voice recording sheet.
/// live-11 (4) — records through `LiveVoiceRecorder` (one AVAudioEngine tap → the file, the waveform and the live
/// on-device recogniser); the words appear as they're spoken and Done saves them at once → saves Node.
struct VoiceCaptureSheet: View {

    /// If set, the captured audio is appended to this node instead of creating a new one.
    var targetNodeID: String? = nil

    /// Arc A2 (T, TF 202610122311) — true when the target is an open CAPTURE screen (Quick Capture, the "+"
    /// capture), whose own Done is the commit. Then this sheet only PROPOSES: the title + summary show as ghosts
    /// while capturing and the capture's Done writes them. False (a standalone voice capture, or an entry
    /// reopened for editing): this sheet's Done is the Done, as before.
    var captureOwnsDone = false

    /// Dashboard Stage 4 — if set (and `targetNodeID` is nil), the newly
    /// created node is stamped with this collection ID and the collection is
    /// marked as recently used. Ignored when appending to an existing node.
    var targetCollectionID: String? = nil

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Recorder redesign (T, 2026-10-13) — the timer is set in the app's one content family (Lato by default).
    @Environment(\.appBodyFont) private var appBodyFont

    // Recording state
    @State private var phase: RecordPhase = .requestingPermission
    /// live-11 (4) — the take: microphone, file, waveform levels, and the words as they're recognised
    /// (`settled` won't change again; `volatile` is the recogniser's guess for what's still being spoken).
    @State private var recorder = LiveVoiceRecorder()

    enum RecordPhase {
        case requestingPermission
        case permissionDenied
        case recording
        case finishing          // Done tapped: the last words land (the recording screen stays as it was)
        case done               // brief flash before dismiss
    }

    private var elapsedSeconds: Int { Int(recorder.elapsed) }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppearancePalette.bgBase.ignoresSafeArea()

            switch phase {
            case .requestingPermission:
                ProgressView()
                    .tint(AppearancePalette.ink)

            case .permissionDenied:
                PermissionDeniedView { dismiss() }

            case .recording, .finishing:
                recordingBody

            case .done:
                AppearancePalette.bgBase.ignoresSafeArea()
            }
        }
        .task {
            await requestPermissionsAndStart()
        }
        // BUG 8 — every teardown path frees the mic. `.onDisappear` catches the
        // swipe-to-dismiss (and any programmatic dismiss) that the Cancel button
        // handler alone would miss; `recorder.teardown()` is idempotent so a save
        // that already tore down is a harmless no-op here.
        .onDisappear {
            recorder.teardown()
        }
        // Backgrounding mid-record must not leave the mic live. Gate on
        // `.background` only (not `.inactive`) so a transient control-center
        // pull doesn't kill an in-progress take; the partial recording stays
        // saveable via Done on return (`stop()` keeps the take; a second call returns it).
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background && phase == .recording {
                Task { _ = await recorder.stop() }
            }
        }
    }

    // MARK: - Recording UI

    private var recordingBody: some View {
        VStack(spacing: 40) {
            Spacer()

            // Elapsed time — the app's family, tabular digits so the numbers never jitter as they tick.
            Text(timeString(elapsedSeconds))
                .font(appBodyFont.font(size: 56, weight: .light))
                .monospacedDigit()
                .foregroundStyle(AppearancePalette.ink.opacity(0.85))
                .accessibilityIdentifier("recorderTimer")

            VStack(spacing: 18) {
                // Waveform
                WaveformView(levels: recorder.levels)
                    .frame(height: 80)
                    .padding(.horizontal, 32)

                // The words as they're spoken, right under the waveform; older lines rise and fade.
                LiveTranscriptView(settled: recorder.settled, volatile: recorder.volatile,
                                   font: appBodyFont.font(size: 20, relativeTo: .body))
                    .padding(.horizontal, 32)
            }

            Spacer()

            // Done button
            Button {
                stopRecording()
            } label: {
                Text("Done")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(width: 120, height: 48)
                    .background(.white)
                    .clipShape(Capsule())
            }
            .disabled(elapsedSeconds < 1 || phase != .recording)
            .opacity(elapsedSeconds < 1 ? 0.4 : 1)

            Button("Cancel") {
                // Free the mic the instant Cancel is tapped (BUG 8) — don't wait
                // for the dismiss animation. `.onDisappear` re-runs it as a belt.
                recorder.teardown()
                dismiss()
            }
                .font(.body)
                .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                .padding(.bottom, 40)
        }
    }

    // MARK: - Permissions + start

    private func requestPermissionsAndStart() async {
        // Microphone
        let micGranted = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else { phase = .permissionDenied; return }

        #if DEBUG
        // `-StubVoiceTranscript` / `-StubLiveTranscript <text>`: the Simulator has no speech model, so the words are
        // canned and arrive as if spoken (the microphone, the file, the save and everything after are the real path).
        // `-StubSpeechUnavailable`: no on-device recognition (the unavailable path). Neither needs the speech prompt.
        if Self.stubTranscript != nil || Self.stubLiveTranscript != nil
            || CommandLine.arguments.contains("-StubSpeechUnavailable") { await startRecording(); return }
        #endif

        // Speech recognition
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { phase = .permissionDenied; return }

        await startRecording()
    }

    // MARK: - Recording

    private func startRecording() async {
        guard await recorder.start() else { dismiss(); return }
        phase = .recording
    }

    /// Done: the live words ARE the transcript — saved as soon as the last ones land, no "Transcribing…" replay.
    private func stopRecording() {
        guard phase == .recording else { return }
        phase = .finishing
        Task {
            guard let take = await recorder.stop() else { dismiss(); return }
            saveNode(transcript: take.transcript, audioURL: take.url, duration: take.duration,
                     transcriptUnavailable: take.transcriptUnavailable)
        }
    }

    #if DEBUG
    static var stubTranscript: String? {
        UserDefaults.standard.string(forKey: "StubVoiceTranscript").flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Recorder render — words stream in as if spoken and the waveform follows a speech-shaped envelope.
    static var stubLiveTranscript: String? {
        UserDefaults.standard.string(forKey: "StubLiveTranscript").flatMap { $0.isEmpty ? nil : $0 }
    }
    #endif

    // MARK: - Node creation

    private func saveNode(transcript: String, audioURL: URL, duration: TimeInterval, transcriptUnavailable: Bool = false) {
        guard phase != .done else { return }   // a final result and an error can both arrive; save once
        phase = .done

        let nodeID = UUID().uuidString
        let audioItemID = UUID().uuidString
        let audioFile = "items/\(audioItemID).m4a"

        var audioItem = NodeItem.audio(itemID: audioItemID, file: audioFile, transcript: transcript, duration: duration)
        if transcriptUnavailable { audioItem.transcriptUnavailable = true }

        let title = transcript.isEmpty
            ? "Voice note"
            : String(transcript.prefix(40))

        let now = Date()
        let stamp = NodeCollection.captureStamp(forCollectionID: targetCollectionID)
        let node = Node(
            id: nodeID,
            createdAt: now,
            updatedAt: now,
            title: title,
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            // Arc B (T, 2026-10-12) — ONE transcript, inside the Voice item (editable in place there). New
            // captures no longer add a duplicate text item; entries that already have one keep it.
            items: [audioItem],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: false,
            journalDate: stamp.journalDate,
            collectionIDs: stamp.collectionIDs
        )

        let position = CGPoint(
            x: Double.random(in: -80...80),
            y: Double.random(in: -80...80)
        )

        Task {
            if let targetID = targetNodeID {
                // Append audio to the existing node (Arc B: the transcript lives in the Voice item only)
                await store.appendItemToNodeWithAudio(nodeID: targetID, item: audioItem, audioURL: audioURL, audioItemID: audioItemID)
                await store.processNodeWithAI(nodeID: targetID, posture: captureOwnsDone ? .propose : .captureDone)   // Brief BI / A2
            } else {
                // Create new node
                await store.addNodeWithAudio(node, audioURL: audioURL, audioItemID: audioItemID, position: position)
                if let cid = targetCollectionID {
                    store.markCollectionUsed(cid)
                }
                await store.processNodeWithAI(nodeID: node.id, posture: .captureDone)   // Brief BI — voice capture is a Done
            }
        }

        // Brief visual hold then dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dismiss()
        }
    }

    // MARK: - Helpers

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Live transcript

/// Recorder redesign (T, 2026-10-13) — the words as they're spoken, in a fixed-height block under the waveform.
/// The newest line sits at the bottom; older lines are pushed up and fade out toward the top edge. Settled words
/// read in ink, the recogniser's still-changing guess a little lighter.
private struct LiveTranscriptView: View {
    let settled: String
    let volatile: String
    let font: Font
    static let height: CGFloat = 150

    var body: some View {
        let joiner = (settled.isEmpty || volatile.isEmpty) ? "" : " "
        (Text(settled).foregroundStyle(AppearancePalette.ink.opacity(0.9))
         + Text(joiner + volatile).foregroundStyle(AppearancePalette.ink.opacity(0.5)))
            .font(font)
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: Self.height, alignment: .bottom)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.55)],
                                 startPoint: .top, endPoint: .bottom))
            .animation(.easeOut(duration: 0.22), value: settled.count + volatile.count)
            .accessibilityIdentifier("liveTranscript")
    }
}

// MARK: - Waveform

private struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppearancePalette.ink)
                        .frame(width: max(2, (geo.size.width - CGFloat(levels.count - 1) * 3) / CGFloat(levels.count)),
                               height: max(4, CGFloat(level) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Permission denied

private struct PermissionDeniedView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.slash")
                .font(.system(size: 48))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))

            Text("Microphone or speech recognition access is required for voice memos.")
                .font(.body)
                .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(AppearancePalette.ink)

            Button("Cancel") { onDismiss() }
                .font(.body)
                .foregroundStyle(AppearancePalette.ink.opacity(0.45))
        }
    }
}
