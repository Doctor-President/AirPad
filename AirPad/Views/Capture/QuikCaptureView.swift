import SwiftUI
import UIKit

struct QuikCaptureView: View {

    /// Dashboard Stage 4 — if set, every capture surface launched from this
    /// view (voice, camera, text, clipboard text, link) stamps the new node
    /// with this collection ID and marks the collection as recently used.
    /// Default nil preserves the pre-Stage-4 URL-scheme entry behavior.
    /// c4.3 will wire `EntryMode.quikCapture(forcedCollectionID:)` and the
    /// pill row to this field.
    var targetCollectionID: String? = nil

    @Environment(CorpusStore.self) private var store

    @State private var showVoiceCapture: Bool = false
    @State private var showCameraCapture: Bool = false
    @State private var showTextCapture: Bool = false
    @State private var prefilledText: String = ""
    @State private var emptyClipboardMessageVisible: Bool = false
    @State private var linkReceipt: LinkReceiptIDs? = nil

    /// Identity pair for the QuikCapture link-receipt overlay. Tracking
    /// both node + item IDs (vs just nodeID) keeps `QuikCaptureLinkReceipt`
    /// resilient to future link entries that aren't `items[0]`.
    private struct LinkReceiptIDs: Equatable {
        let nodeID: String
        let itemID: String
    }

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
        .overlay {
            if let receipt = linkReceipt {
                QuikCaptureLinkReceipt(
                    nodeID: receipt.nodeID,
                    itemID: receipt.itemID,
                    onDismiss: { linkReceipt = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: linkReceipt)
        .sheet(isPresented: $showVoiceCapture) {
            VoiceCaptureSheet(targetCollectionID: targetCollectionID)
        }
        .sheet(isPresented: $showCameraCapture) {
            CameraCaptureView(targetCollectionID: targetCollectionID)
        }
        .sheet(isPresented: $showTextCapture) {
            TextCaptureSheet(targetCollectionID: targetCollectionID, initialText: prefilledText)
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
            needsAIProcessing: true,
            collectionIDs: [targetCollectionID].compactMap { $0 }
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
            if let cid = targetCollectionID {
                store.markCollectionUsed(cid)
            }
            // AT19.3c commit 6 — receipt overlay. Present immediately after
            // the node lands in the store so the receipt can resolve the
            // item; if OG hasn't returned yet the overlay shows State B
            // (bare URL) and upgrades to State C in-place when applyOGFetch
            // mutates the store within the 1.0s window.
            linkReceipt = LinkReceiptIDs(nodeID: nodeID, itemID: itemID)
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

/// AT19.3c commit 6 — receipt modal shown after a clipboard URL is captured
/// via QuikCapture. Renders `OGPreviewView` (non-interactive) so the user
/// sees the same visual treatment they'll get on the canvas, with a
/// "Web clipping captured" caption above it. Auto-dismisses after 2.0s;
/// tap anywhere to dismiss early. Because the underlying `NodeItem` is
/// read from the store on every render, applyOGFetch landing inside the
/// 2.0s window animates the preview from bare-URL to rich card in place.
private struct QuikCaptureLinkReceipt: View {

    let nodeID: String
    let itemID: String
    let onDismiss: () -> Void

    @Environment(CorpusStore.self) private var store
    @State private var visible: Bool = false

    private var currentItem: NodeItem? {
        store.nodes.first(where: { $0.id == nodeID })?
            .items.first(where: { $0.id == itemID })
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Web clipping captured")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))

                if let item = currentItem {
                    OGPreviewView(
                        item: item,
                        nodeID: nodeID,
                        onCommitURL: { _ in },
                        interactive: false
                    )
                    .padding(14)
                    .background(Color(hex: "#1A1A20"))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 32)
        }
        .opacity(visible ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { visible = true }
            Task {
                try? await Task.sleep(for: .seconds(2.0))
                dismiss()
            }
        }
    }

    private func dismiss() {
        // Idempotent: both the tap path and the auto-dismiss timer call
        // this; whichever fires second is a no-op so `onDismiss` runs once.
        guard visible else { return }
        withAnimation(.easeIn(duration: 0.18)) { visible = false }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            onDismiss()
        }
    }
}
