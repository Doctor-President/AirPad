import SwiftUI

struct ContentView: View {

    @Environment(CorpusStore.self) private var store

    var body: some View {
        CanvasView()
            .overlay(alignment: .top) {
                if store.iCloudUnavailable {
                    iCloudUnavailableBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.spring(response: 0.35), value: store.iCloudUnavailable)
    }
}

private struct iCloudUnavailableBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.caption)
            Text("iCloud unavailable — saving locally")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}
