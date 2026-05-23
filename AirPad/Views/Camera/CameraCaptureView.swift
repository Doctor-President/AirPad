import SwiftUI
import PhotosUI
import UIKit
import AVFoundation
import Vision
import UniformTypeIdentifiers

/// Camera/photo-library capture sheet.
/// Presents the system camera or photo picker, then saves the result as an image node (or appends to an existing node).
struct CameraCaptureView: View {

    /// If set, the captured image is appended to this node instead of creating a new one.
    var targetNodeID: String? = nil

    /// Dashboard Stage 4 — if set (and `targetNodeID` is nil), the newly
    /// created node is stamped with this collection ID and the collection is
    /// marked as recently used. Ignored when appending to an existing node.
    var targetCollectionID: String? = nil

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var cameraPermissionDenied = false
    @State private var showingPicker = false
    @State private var showingCamera = false
    @State private var sourceChoice: SourceChoice? = nil
    @State private var isSaving = false

    enum SourceChoice: Identifiable {
        case camera, library
        var id: Int { hashValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if isSaving {
                    ProgressView("Saving…")
                        .tint(.white)
                } else {
                    Text("Capture")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 20) {
                        SourceButton(icon: "camera.fill", label: "Camera") {
                            requestCameraAndOpen()
                        }
                        SourceButton(icon: "photo.on.rectangle", label: "Library") {
                            showingPicker = true
                        }
                    }

                    if cameraPermissionDenied {
                        PermissionBanner(message: "Camera access denied.") {
                            openSettings()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        // PHPickerViewController for photo library
        .sheet(isPresented: $showingPicker) {
            MediaPickerWrapper { results in
                Task { await handlePickerResults(results) }
            }
        }
        // UIImagePickerController for live camera
        .sheet(isPresented: $showingCamera) {
            ImagePickerWrapper(sourceType: .camera) { image in
                Task { await handleCapturedImage(image) }
            }
        }
        .presentationBackground(.black)
        .presentationDetents([.medium])
    }

    // MARK: - Camera permission

    private func requestCameraAndOpen() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    if granted { showingCamera = true }
                    else { cameraPermissionDenied = true }
                }
            }
        default:
            cameraPermissionDenied = true
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Handling results

    /// Stage 4.2 commit 2 — picker now returns `[PHPickerResult]` (multi-select
    /// is enabled with `selectionLimit = 0`) and may contain a mix of images
    /// and videos. Each result is normalized at this view layer into a
    /// `CorpusStore.PendingMediaItem` (image data encoded as jpg + written to
    /// temp, or movie file copied off the iOS-managed temp URL before it gets
    /// reclaimed) and then handed to `addMediaItems` as one atomic batch — so
    /// the resulting entry is a single `.imageVideo` with N gallery items, not
    /// N separate entries.
    ///
    /// The single-image branch preserves the prior UX: AI description seeds
    /// the node title and the OCR pass appends recognized text as a sibling
    /// text item. Multi-select picks and the single-video case skip both —
    /// per-item AI/OCR for galleries is out of scope for commit 2.
    private func handlePickerResults(_ results: [PHPickerResult]) async {
        guard !results.isEmpty else { dismiss(); return }
        isSaving = true

        var pending: [CorpusStore.PendingMediaItem] = []
        var firstImage: (data: Data, uiImage: UIImage)? = nil

        for result in results {
            if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                guard let image = await MediaPickerWrapper.loadImage(from: result.itemProvider),
                      let data = image.jpegData(compressionQuality: 0.85) else { continue }
                let itemID = UUID().uuidString
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(itemID).jpg")
                do {
                    try data.write(to: tmpURL)
                } catch {
                    print("[CameraCapture] Image temp write error: \(error)")
                    continue
                }
                pending.append(.init(itemID: itemID, mediaType: .image, sourceURL: tmpURL, fileExtension: "jpg"))
                if firstImage == nil { firstImage = (data, image) }
            } else if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                guard let (tmpURL, ext) = await MediaPickerWrapper.loadVideo(from: result.itemProvider) else { continue }
                pending.append(.init(itemID: UUID().uuidString, mediaType: .video, sourceURL: tmpURL, fileExtension: ext))
            }
        }

        guard !pending.isEmpty else {
            isSaving = false
            dismiss()
            return
        }

        let isSingleImage = pending.count == 1 && pending[0].mediaType == .image
        var description = ""
        var ocrText = ""
        if isSingleImage, let firstImage {
            if #available(iOS 26.0, *) {
                description = await AIService().describeImage(firstImage.data) ?? ""
            }
            ocrText = await Task.detached(priority: .userInitiated) {
                Self.extractText(from: firstImage.uiImage)
            }.value
        }

        let position = CGPoint(x: Double.random(in: -80...80), y: Double.random(in: -80...80))
        await store.addMediaItems(
            toNodeID: targetNodeID,
            mediaItems: pending,
            description: description,
            position: position,
            targetCollectionID: targetCollectionID
        )

        if !ocrText.isEmpty {
            let affectedNodeID = targetNodeID ?? store.nodes.first?.id
            if let nodeID = affectedNodeID {
                await store.appendItemToNode(nodeID: nodeID, item: .text(content: ocrText))
            }
        }

        if let nodeID = targetNodeID {
            await store.processNodeWithAI(nodeID: nodeID)
        } else if let newest = store.nodes.first {
            await store.processNodeWithAI(nodeID: newest.id)
        }

        if targetNodeID == nil, let cid = targetCollectionID {
            store.markCollectionUsed(cid)
        }

        isSaving = false
        dismiss()
    }

    /// Camera capture is always a single image — funneled through the same
    /// `addMediaItems` path so it produces a `.imageVideo` entry with one
    /// gallery item, matching the picker N=1 image case exactly.
    private func handleCapturedImage(_ image: UIImage) async {
        isSaving = true
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            isSaving = false
            dismiss()
            return
        }

        let itemID = UUID().uuidString
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(itemID).jpg")
        do {
            try data.write(to: tmpURL)
        } catch {
            print("[CameraCapture] Image temp write error: \(error)")
            isSaving = false
            dismiss()
            return
        }

        let description: String
        if #available(iOS 26.0, *) {
            description = await AIService().describeImage(data) ?? ""
        } else {
            description = ""
        }

        let ocrText = await Task.detached(priority: .userInitiated) {
            Self.extractText(from: image)
        }.value

        let pending = CorpusStore.PendingMediaItem(
            itemID: itemID,
            mediaType: .image,
            sourceURL: tmpURL,
            fileExtension: "jpg"
        )
        let position = CGPoint(x: Double.random(in: -80...80), y: Double.random(in: -80...80))
        await store.addMediaItems(
            toNodeID: targetNodeID,
            mediaItems: [pending],
            description: description,
            position: position,
            targetCollectionID: targetCollectionID
        )

        if !ocrText.isEmpty {
            let affectedNodeID = targetNodeID ?? store.nodes.first?.id
            if let nodeID = affectedNodeID {
                await store.appendItemToNode(nodeID: nodeID, item: .text(content: ocrText))
            }
        }

        if let nodeID = targetNodeID {
            await store.processNodeWithAI(nodeID: nodeID)
        } else if let newest = store.nodes.first {
            await store.processNodeWithAI(nodeID: newest.id)
        }

        if targetNodeID == nil, let cid = targetCollectionID {
            store.markCollectionUsed(cid)
        }

        isSaving = false
        dismiss()
    }

    private static func extractText(from image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try? handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: " ")
    }
}

// MARK: - Source button

private struct SourceButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

// MARK: - Permission banner

private struct PermissionBanner: View {
    let message: String
    let onSettings: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button("Settings") { onSettings() }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(12)
        .background(.red.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
    }
}

// MARK: - UIImagePickerController wrapper (live camera)

private struct ImagePickerWrapper: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        init(onCapture: @escaping (UIImage) -> Void) { self.onCapture = onCapture }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
