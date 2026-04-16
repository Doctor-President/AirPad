import SwiftUI

@main
struct AirPadApp: App {

    @State private var store = CorpusStore()
    @State private var showVoiceCapture = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task { await store.setup() }
                .sheet(isPresented: $showVoiceCapture) {
                    VoiceCaptureSheet()
                        .environment(store)
                }
                .onReceive(NotificationCenter.default.publisher(for: .airPadActionButtonPressed)) { _ in
                    showVoiceCapture = true
                }
        }
    }
}
