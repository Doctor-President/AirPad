import SwiftUI
import UIKit

struct QuikCaptureView: View {

    @Environment(CorpusStore.self) private var store

    @State private var showVoiceCapture: Bool = false
    @State private var showCameraCapture: Bool = false
    @State private var showTextCapture: Bool = false
    @State private var prefilledText: String = ""
    @State private var emptyClipboardMessageVisible: Bool = false

    var body: some View {
        ZStack {
            Color(hex: "#07070A").ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    exitPill
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                if emptyClipboardMessageVisible {
                    Text("Nothing in clipboard yet.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }

                HStack(spacing: 0) {
                    Spacer()
                    captureButton(symbol: "mic.fill", label: "Voice") {
                        showVoiceCapture = true
                    }
                    Spacer()
                    captureButton(symbol: "camera.fill", label: "Camera") {
                        showCameraCapture = true
                    }
                    Spacer()
                    captureButton(symbol: "pencil", label: "Text") {
                        prefilledText = ""
                        showTextCapture = true
                    }
                    Spacer()
                    captureButton(symbol: "doc.on.clipboard.fill", label: "Clipboard") {
                        handleClipboardTap()
                    }
                    Spacer()
                }
                .padding(.bottom, 48)
            }
        }
        .sheet(isPresented: $showVoiceCapture) {
            VoiceCaptureSheet()
        }
        .sheet(isPresented: $showCameraCapture) {
            CameraCaptureView()
        }
        .sheet(isPresented: $showTextCapture) {
            TextCaptureSheet(initialText: prefilledText)
        }
    }

    private var exitPill: some View {
        Button {
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        } label: {
            Text("Exit QuikCapture ↩")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: "#1B59C2"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func captureButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 64, height: 64)
                    .background(Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Clipboard routing

    private func handleClipboardTap() {
        Task.detached(priority: .userInitiated) {
            let url = UIPasteboard.general.url
            let text = UIPasteboard.general.string
            await MainActor.run {
                if let url, url.scheme == "http" || url.scheme == "https" {
                    createLinkNode(url: url)
                } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    prefilledText = text
                    showTextCapture = true
                } else {
                    showEmptyClipboardMessage()
                }
            }
        }
    }

    private func showEmptyClipboardMessage() {
        withAnimation(.easeInOut(duration: 0.2)) {
            emptyClipboardMessageVisible = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.2)) {
                emptyClipboardMessageVisible = false
            }
        }
    }

    // MARK: - Link node creation

    private func createLinkNode(url: URL) {
        let nodeID = UUID().uuidString
        let itemID = UUID().uuidString
        let now = Date()
        let initialTitle = url.host ?? url.absoluteString

        let item = NodeItem(
            id: itemID,
            type: .link,
            createdAt: now,
            content: nil,
            file: nil,
            description: nil,
            transcript: nil,
            durationSeconds: nil,
            url: url.absoluteString,
            title: initialTitle,
            preview: nil
        )
        let node = Node(
            id: nodeID,
            createdAt: now,
            updatedAt: now,
            title: initialTitle,
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: [item],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: true
        )
        let position = CGPoint(
            x: Double.random(in: -80...80),
            y: Double.random(in: -80...80)
        )

        Task {
            // AT19.3c — eager OG fetch. Kick the fetch off in parallel with
            // `addNode` so the request is already in flight by the time the
            // node has landed in the store; under typical network conditions
            // the metadata is back within the same task lifetime and lands
            // on the entry before the user ever sees the bare-URL state.
            async let fetchTask = OGMetadataService().fetch(url: url)
            await store.addNode(node, position: position)
            let metadata = await fetchTask
            await store.applyOGFetch(nodeID: nodeID, itemID: itemID, metadata: metadata)

            // Propagate `ogTitle` to the node's display title and the entry's
            // legacy `title` field so canvas + AI processing pick up the
            // richer name instead of the bare host. `applyOGFetch` only
            // touches the OG fields; these are 3.1a-shape mutations.
            if let ogTitle = metadata?.title, !ogTitle.isEmpty,
               var current = store.nodes.first(where: { $0.id == nodeID }) {
                current.title = ogTitle
                if !current.items.isEmpty {
                    current.items[0].title = ogTitle
                }
                current.updatedAt = Date()
                await store.updateNode(current)
            }

            await store.processNodeWithAI(nodeID: nodeID)
        }
    }
}
