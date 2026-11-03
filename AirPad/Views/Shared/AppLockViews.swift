import SwiftUI

/// 1.1-A (A6) — what the lock window shows: the app-switcher cover (AirPad in the background with the lock on), the
/// lock screen (locked, in front), and Quick Capture over the lock screen (add-only). None of it reads the library.
struct AppLockOverlay: View {
    @Environment(\.appBodyFont) private var appFont
    private var lock: AppLock { AppLock.shared }

    var body: some View {
        ZStack {
            AppearancePalette.bgBase.ignoresSafeArea()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            if lock.isLocked && lock.lockedCaptureOpen {
                LockedCaptureView()
            } else {
                VStack(spacing: 18) {
                    Image("AirPadLogo")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(AppearancePalette.ink)
                        .frame(height: 64)
                        .accessibilityHidden(true)
                    if lock.isLocked && !lock.coverShown {
                        Text("AirPad is locked")
                            .font(appFont.font(size: 17, weight: .semibold, relativeTo: .headline))
                            .foregroundStyle(AppearancePalette.ink)
                        Button { Task { await lock.unlock() } } label: {
                            Label(lock.unlockLabel, systemImage: lock.method == .touchID ? "touchid" : lock.method == .passcode ? "lock.open" : "faceid")
                                .font(appFont.font(size: 16, weight: .semibold, relativeTo: .body))
                                .foregroundStyle(AppearancePalette.ink)
                                .padding(.horizontal, 20).padding(.vertical, 12)
                                .background(Capsule().fill(AppearancePalette.ink.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .disabled(lock.authenticating)
                        .accessibilityIdentifier("appLock.unlock")
                        Button { lock.lockedCaptureOpen = true } label: {
                            Label("Quick Capture", systemImage: "square.and.pencil")
                                .font(appFont.font(size: 15, weight: .medium, relativeTo: .subheadline))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                        .accessibilityIdentifier("appLock.quickCapture")
                    }
                }
                .padding(32)
            }
        }
        .accessibilityIdentifier(lock.isLocked ? "appLock.screen" : "appLock.cover")
    }
}

/// Quick Capture while locked: a blank note and Save. It adds a new entry (named at Done, like any capture) and shows
/// nothing already in the library — no tags, collections, suggestions or recents.
struct LockedCaptureView: View {
    @Environment(\.appBodyFont) private var appFont
    @Environment(CorpusStore.self) private var store
    @State private var text = ""
    @State private var saved = false
    @FocusState private var focused: Bool
    private var lock: AppLock { AppLock.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Cancel") { close() }
                    .font(appFont.font(size: 17, relativeTo: .body))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                Spacer()
                Text("Quick Capture")
                    .font(appFont.font(size: 17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(AppearancePalette.ink)
                Spacer()
                Button("Save") { save() }
                    .font(appFont.font(size: 17, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(AppearancePalette.ink)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saved)
                    .accessibilityIdentifier("lockedCapture.save")
            }
            if saved {
                Label("Saved. Unlock AirPad to see it.", systemImage: "checkmark.circle.fill")
                    .font(appFont.font(size: 15, relativeTo: .subheadline))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.8))
            } else {
                TextEditor(text: $text)
                    .font(appFont.font(size: 17, relativeTo: .body))
                    .foregroundStyle(AppearancePalette.ink)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(AppearancePalette.ink.opacity(0.06)))
                    .focused($focused)
                    .accessibilityIdentifier("lockedCapture.text")
                Text("AirPad stays locked. You can add, not look.")
                    .font(appFont.font(size: 12, relativeTo: .caption1))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.45))
            }
            Spacer()
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func save() {
        let body = text
        saved = true
        Task {
            guard let node = await store.createCaptureNode(),
                  let itemID = node.items.first(where: { $0.type == .text })?.id else { return }
            await store.updateTextItem(itemID: itemID, newContent: body, nodeID: node.id)
            store.endComposing(nodeID: node.id)
            await store.enrichIfNeeded(nodeID: node.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { close() }
    }

    private func close() {
        focused = false
        lock.lockedCaptureOpen = false
    }
}
