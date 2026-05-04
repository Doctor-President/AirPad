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
            await store.addNode(node, position: position)
            if let ogTitle = await Self.fetchOGTitle(from: url),
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

    private static func fetchOGTitle(from url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Mozilla/5.0 (compatible; AirPad/1.0)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let title = match(html, pattern: #"<meta\s+[^>]*property=["']og:title["'][^>]*content=["']([^"']+)["']"#) {
            return decodeHTMLEntities(title)
        }
        if let title = match(html, pattern: #"<meta\s+[^>]*content=["']([^"']+)["'][^>]*property=["']og:title["']"#) {
            return decodeHTMLEntities(title)
        }
        if let title = match(html, pattern: #"<title[^>]*>([^<]+)</title>"#) {
            return decodeHTMLEntities(title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func match(_ string: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: string) else {
            return nil
        }
        let result = String(string[captureRange])
        return result.isEmpty ? nil : result
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&apos;", with: "'")
    }
}
