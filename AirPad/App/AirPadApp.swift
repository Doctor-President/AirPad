import SwiftUI

@main
struct AirPadApp: App {

    @State private var store = CorpusStore()
    @State private var quarantineStore = QuarantineStore()
    @State private var showVoiceCapture = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(quarantineStore)
                .task {
                    store.quarantineStore = quarantineStore
                    await store.setup()
                }
                .sheet(isPresented: $showVoiceCapture) {
                    VoiceCaptureSheet()
                        .environment(store)
                        .environment(quarantineStore)
                }
                .onReceive(NotificationCenter.default.publisher(for: .airPadActionButtonPressed)) { _ in
                    showVoiceCapture = true
                }
        }
    }
}
