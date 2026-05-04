import SwiftUI
import AppIntents

@main
struct AirPadApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var store = CorpusStore()
    @State private var quarantineStore = QuarantineStore()
    @State private var showVoiceCapture = false
    private let router: AppRouter

    init() {
        let appRouter = AppRouter()
        self.router = appRouter
        AppDependencyManager.shared.add(dependency: appRouter)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(quarantineStore)
                .environment(router)
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
                .onOpenURL { url in
                    guard url.scheme == "airpad", url.host == "quikcapture" else { return }
                    router.entryMode = .quikCapture
                }
        }
    }
}
