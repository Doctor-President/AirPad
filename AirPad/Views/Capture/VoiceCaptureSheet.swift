import SwiftUI
import AVFoundation
import Speech

/// Full-screen voice recording sheet.
/// Records via AVAudioRecorder → transcribes via SFSpeechRecognizer → saves Node.
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

    // Recording state
    @State private var phase: RecordPhase = .requestingPermission
    @State private var levels: [Float] = Array(repeating: 0, count: 40)
    @State private var transcript: String = ""
    @State private var elapsedSeconds: Int = 0

    // Internals (class types, so we box them)
    @State private var box = RecorderBox()

    enum RecordPhase {
        case requestingPermission
        case permissionDenied
        case recording
        case transcribing
        case done               // brief flash before dismiss
    }

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

            case .recording:
                recordingBody

            case .transcribing:
                transcribingBody

            case .done:
                AppearancePalette.bgBase.ignoresSafeArea()
            }
        }
        .task {
            await requestPermissionsAndStart()
        }
        // BUG 8 — every teardown path frees the mic. `.onDisappear` catches the
        // swipe-to-dismiss (and any programmatic dismiss) that the Cancel button
        // handler alone would miss; `teardownAudio()` is idempotent so a save
        // that already tore down is a harmless no-op here.
        .onDisappear {
            teardownAudio()
        }
        // Backgrounding mid-record must not leave the mic live. Gate on
        // `.background` only (not `.inactive`) so a transient control-center
        // pull doesn't kill an in-progress take; the partial recording stays
        // saveable (recordingURL is preserved) via Done on return.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background && phase == .recording {
                teardownAudio()
            }
        }
    }

    // MARK: - Recording UI

    private var recordingBody: some View {
        VStack(spacing: 40) {
            Spacer()

            // Elapsed time
            Text(timeString(elapsedSeconds))
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .foregroundStyle(AppearancePalette.ink.opacity(0.85))

            // Waveform
            WaveformView(levels: levels)
                .frame(height: 80)
                .padding(.horizontal, 32)

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
            .disabled(elapsedSeconds < 1)
            .opacity(elapsedSeconds < 1 ? 0.4 : 1)

            Button("Cancel") {
                // Free the mic the instant Cancel is tapped (BUG 8) — don't wait
                // for the dismiss animation. `.onDisappear` re-runs it as a belt.
                teardownAudio()
                dismiss()
            }
                .font(.body)
                .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                .padding(.bottom, 40)
        }
    }

    // MARK: - Transcribing UI

    private var transcribingBody: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .tint(AppearancePalette.ink)
                .scaleEffect(1.2)

            Text("Transcribing…")
                .font(.subheadline)
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))

            if !transcript.isEmpty {
                Text(transcript)
                    .font(.body)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .lineLimit(6)
            }

            Spacer()
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
        // Arc A — `-StubVoiceTranscript <text>`: the Simulator has no speech model, so the transcript is
        // canned (recording, the save, and everything after it are the real path). Skips the speech prompt.
        if Self.stubTranscript != nil { startRecording(); return }
        // live-10 (4) — `-StubSpeechUnavailable`: no on-device recognizer (the unavailable path), so no speech prompt.
        if CommandLine.arguments.contains("-StubSpeechUnavailable") { startRecording(); return }
        #endif

        // Speech recognition
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { phase = .permissionDenied; return }

        startRecording()
    }

    // MARK: - Recording

    private func startRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[VoiceCapture] Audio session error: \(error)")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            box.recorder = recorder
            box.recordingURL = url
        } catch {
            print("[VoiceCapture] Recorder init error: \(error)")
            return
        }

        phase = .recording

        // Metering timer
        box.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard let rec = box.recorder, rec.isRecording else { return }
            rec.updateMeters()
            let raw = rec.averagePower(forChannel: 0)  // dB: ~-60 to 0
            let normalized = Float(max(0, min(1, (raw + 50) / 50)))
            DispatchQueue.main.async {
                levels.append(normalized)
                if levels.count > 40 { levels.removeFirst() }
                elapsedSeconds = Int(rec.currentTime)
            }
        }
    }

    private func stopRecording() {
        // Capture duration before teardown nils the recorder.
        let duration = box.recorder?.currentTime ?? 0
        teardownAudio()

        guard let url = box.recordingURL else { dismiss(); return }
        transcribe(url: url, duration: duration)
    }

    /// BUG 8 — idempotent audio teardown. Stops the metering timer and recorder
    /// and deactivates the shared session with `.notifyOthersOnDeactivation` so
    /// the mic is released and other audio apps can resume. Every exit path —
    /// Done/save, Cancel, swipe-dismiss, background mid-record — routes through
    /// here, so no path can leave the microphone live. Deliberately does NOT
    /// touch the recognition task (it's a file-based request that never opens the
    /// mic) or `recordingURL` (so a backgrounded take stays saveable). Safe to
    /// call repeatedly.
    private func teardownAudio() {
        box.meterTimer?.invalidate()
        box.meterTimer = nil
        box.recorder?.stop()
        box.recorder = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[VoiceCapture] Session deactivate error: \(error)")
        }
    }

    // MARK: - Transcription

    #if DEBUG
    static var stubTranscript: String? {
        UserDefaults.standard.string(forKey: "StubVoiceTranscript").flatMap { $0.isEmpty ? nil : $0 }
    }
    #endif

    private func transcribe(url: URL, duration: TimeInterval) {
        phase = .transcribing
        #if DEBUG
        if let stub = Self.stubTranscript {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                transcript = stub
                saveNode(transcript: stub, audioURL: url, duration: duration)
            }
            return
        }
        #endif

        // live-10 (4) — on-device only. No on-device recognizer for this language/device: keep the audio, and the
        // Voice item's transcript area says why (never a silent fallback to Apple's server).
        guard let recognizer = OnDeviceSpeech.recognizer() else {
            print("[Speech] on-device recognition unavailable — voice saved without a transcript")
            saveNode(transcript: "", audioURL: url, duration: duration, transcriptUnavailable: true)
            return
        }

        let request = OnDeviceSpeech.fileRequest(url: url, partialResults: true)

        box.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let result {
                    transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        saveNode(transcript: transcript, audioURL: url, duration: duration)
                    }
                } else if let error {
                    // Transcription failed — save what was heard. No words and not just silence ⇒ unavailable on-device.
                    let ns = error as NSError
                    let unavailable = transcript.isEmpty && OnDeviceSpeech.meansUnavailable(error)
                    print("[Speech] voice capture recognition error domain=\(ns.domain) code=\(ns.code) words=\(!transcript.isEmpty) unavailable=\(unavailable)")
                    saveNode(transcript: transcript, audioURL: url, duration: duration, transcriptUnavailable: unavailable)
                }
            }
        }
        box.recognitionRequest = request
    }

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

// MARK: - Reference box (holds class types for AVFoundation objects)

private final class RecorderBox {
    var recorder: AVAudioRecorder?
    var recordingURL: URL?
    var meterTimer: Timer?
    var recognitionTask: SFSpeechRecognitionTask?
    var recognitionRequest: SFSpeechURLRecognitionRequest?
}
