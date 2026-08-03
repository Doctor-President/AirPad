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
    /// Defaulted so existing callers (`CameraCaptureView`, `GalleryBody`,
    /// `SingleMediaBody`) keep their multi-select images-or-videos
    /// behavior unchanged. Hero picker passes `selectionLimit: 1`.
    var selectionLimit: Int = 0
    /// Defaulted to images-or-videos to preserve existing call sites.
    /// Hero picker passes `filter: .images` since the hero is image-only
    /// (mirrors the gallery viewer's Set-as-Hero video gate).
    var filter: PHPickerFilter = .any(of: [.images, .videos])

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = selectionLimit
        config.filter = filter
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

    /// True when the provider carries an image representation (HEIC / JPEG / PNG
    /// / RAW-DNG / Live-Photo still). Checked against `registeredTypeIdentifiers`
    /// conforming to `public.image` rather than `canLoadObject(UIImage.self)` so
    /// RAW/ProRAW — which we copy as bytes, never decode — is still classified as
    /// an image and not dropped to the video branch.
    static func isImageProvider(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
    }

    /// Copies the ORIGINAL image file bytes to a fresh temp URL — no decode, no
    /// `UIImage`, no re-encode — so an imported photo keeps its source format and
    /// full quality (HEIC stays HEIC, RAW stays RAW). The shared picker-image
    /// import path for `GalleryBody` and `SingleMediaBody`.
    ///
    /// Requests the provider's NATIVE image type (the first registered identifier
    /// conforming to `public.image`), which returns the original representation
    /// instead of transcoding; falls back to the abstract `public.image`. The
    /// extension is derived from the returned URL (or the type's preferred
    /// extension) — never hardcoded — and flows straight to
    /// `PendingMediaItem.fileExtension`; `GalleryItem.file` already persists the
    /// full `items/<id>.<ext>`, so there is no schema/read-path change.
    ///
    /// Mirrors `loadVideo`'s reclaim discipline: the provider's URL is invalidated
    /// the moment the completion returns, so the bytes are copied SYNCHRONOUSLY
    /// inside the callback before the continuation resumes. Returns nil on
    /// failure (e.g. an iCloud-hosted original that couldn't be downloaded); the
    /// caller COUNTS the failure and surfaces it — it must not be swallowed.
    static func loadOriginalImageFile(from provider: NSItemProvider) async -> (URL, String)? {
        let typeID = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                guard let url else {
                    if let error {
                        print("[MediaPicker] Image original load failed (\(typeID)): \(error.localizedDescription)")
                    }
                    continuation.resume(returning: nil)
                    return
                }
                let derived = url.pathExtension.isEmpty
                    ? (UTType(typeID)?.preferredFilenameExtension ?? "img")
                    : url.pathExtension
                let ext = derived.lowercased()
                let destURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: destURL)
                    continuation.resume(returning: (destURL, ext))
                } catch {
                    print("[MediaPicker] Image original copy failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
