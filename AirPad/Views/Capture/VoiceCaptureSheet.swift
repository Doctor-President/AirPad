import SwiftUI
import AVFoundation
import Speech

/// Full-screen voice recording sheet.
/// Records via AVAudioRecorder → transcribes via SFSpeechRecognizer → saves Node.
struct VoiceCaptureSheet: View {

    /// If set, the captured audio is appended to this node instead of creating a new one.
    var targetNodeID: String? = nil

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

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
            Color.black.ignoresSafeArea()

            switch phase {
            case .requestingPermission:
                ProgressView()
                    .tint(.white)

            case .permissionDenied:
                PermissionDeniedView { dismiss() }

            case .recording:
                recordingBody

            case .transcribing:
                transcribingBody

            case .done:
                Color.black.ignoresSafeArea()
            }
        }
        .task {
            await requestPermissionsAndStart()
        }
    }

    // MARK: - Recording UI

    private var recordingBody: some View {
        VStack(spacing: 40) {
            Spacer()

            // Elapsed time
            Text(timeString(elapsedSeconds))
                .font(.system(size: 48, weight: .thin, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))

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

            Button("Cancel") { dismiss() }
                .font(.body)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 40)
        }
    }

    // MARK: - Transcribing UI

    private var transcribingBody: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .tint(.white)
                .scaleEffect(1.2)

            Text("Transcribing…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))

            if !transcript.isEmpty {
                Text(transcript)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
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
        box.meterTimer?.invalidate()
        box.meterTimer = nil
        box.recorder?.stop()
        let duration = box.recorder?.currentTime ?? 0
        box.recorder = nil

        do { try AVAudioSession.sharedInstance().setActive(false) } catch { }

        guard let url = box.recordingURL else { dismiss(); return }
        transcribe(url: url, duration: duration)
    }

    // MARK: - Transcription

    private func transcribe(url: URL, duration: TimeInterval) {
        phase = .transcribing

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable else {
            // No speech recognition available — create node with empty transcript
            saveNode(transcript: "", audioURL: url, duration: duration)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true

        box.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let result {
                    transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        saveNode(transcript: transcript, audioURL: url, duration: duration)
                    }
                } else if error != nil {
                    // Transcription failed — save with empty transcript
                    saveNode(transcript: transcript, audioURL: url, duration: duration)
                }
            }
        }
        box.recognitionRequest = request
    }

    // MARK: - Node creation

    private func saveNode(transcript: String, audioURL: URL, duration: TimeInterval) {
        phase = .done

        let nodeID = UUID().uuidString
        let audioItemID = UUID().uuidString
        let audioFile = "items/\(audioItemID).m4a"

        let title = transcript.isEmpty
            ? "Voice note"
            : String(transcript.prefix(40))

        let now = Date()
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
            items: [
                .audio(itemID: audioItemID,
                       file: audioFile,
                       transcript: transcript,
                       duration: duration),
                transcript.isEmpty ? nil : .text(content: transcript)
            ].compactMap { $0 },
            domain: nil,
            domainConfirmed: false
        )

        let position = CGPoint(
            x: Double.random(in: -80...80),
            y: Double.random(in: -80...80)
        )

        let audioItem = NodeItem.audio(itemID: audioItemID, file: audioFile, transcript: transcript, duration: duration)

        Task {
            if let targetID = targetNodeID {
                // Append audio (+ transcript text) to existing node
                await store.appendItemToNodeWithAudio(nodeID: targetID, item: audioItem, audioURL: audioURL, audioItemID: audioItemID)
                if !transcript.isEmpty {
                    await store.appendItemToNode(nodeID: targetID, item: .text(content: transcript))
                }
                await store.processNodeWithAI(nodeID: targetID)
            } else {
                // Create new node
                await store.addNodeWithAudio(node, audioURL: audioURL, audioItemID: audioItemID, position: position)
                await store.processNodeWithAI(nodeID: node.id)
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
                        .fill(Color.white)
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
                .foregroundStyle(.white.opacity(0.4))

            Text("Microphone or speech recognition access is required for voice notes.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)

            Button("Cancel") { onDismiss() }
                .font(.body)
                .foregroundStyle(.white.opacity(0.45))
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
