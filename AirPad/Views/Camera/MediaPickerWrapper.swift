import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Stage 4.2 commit 2/3 — shared PHPicker wrapper used by both
/// `CameraCaptureView` (creates a new node from picked media) and
/// `SingleMediaBody` / `GalleryBody` chrome (appends to an existing
/// `.imageVideo` entry). Multi-select unlocked (`selectionLimit = 0`) and the
/// filter expanded to accept images + videos. Each caller is responsible for
/// extracting the returned `[PHPickerResult]` into
/// `CorpusStore.PendingMediaItem`s via `loadImage` / `loadVideo` and then
/// routing to the appropriate store method (`addMediaItems` for new entries,
/// `appendMediaItems` for adding to an existing entry).
struct MediaPickerWrapper: UIViewControllerRepresentable {
    let onPick: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void
        init(onPick: @escaping ([PHPickerResult]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results)
        }
    }

    // MARK: - Async bridges to NSItemProvider

    /// Bridges `loadObject(ofClass:)` into async. Returns nil if the provider
    /// doesn't actually deliver a `UIImage` — caller already gated on
    /// `canLoadObject(ofClass: UIImage.self)` so this is the failure tail.
    static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { reading, _ in
                continuation.resume(returning: reading as? UIImage)
            }
        }
    }

    /// Bridges `loadFileRepresentation(forTypeIdentifier:)` into async. The
    /// URL handed to the completion is reclaimed by iOS the moment the
    /// completion returns, so the file is copied SYNCHRONOUSLY inside the
    /// callback to a fresh temp path before the continuation resumes — the
    /// destination URL the caller gets back is the one that owns the bytes.
    /// Returns nil on copy failure or if the provider had no movie payload.
    static func loadVideo(from provider: NSItemProvider) async -> (URL, String)? {
        let movieType = UTType.movie.identifier
        guard provider.hasItemConformingToTypeIdentifier(movieType) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: movieType) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let destURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: destURL)
                    continuation.resume(returning: (destURL, ext))
                } catch {
                    print("[MediaPicker] Video temp copy error: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
