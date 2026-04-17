import SwiftUI
import PhotosUI
import UIKit
import AVFoundation
import Vision

/// Camera/photo-library capture sheet.
/// Presents the system camera or photo picker, then saves the result as an image node (or appends to an existing node).
struct CameraCaptureView: View {

    /// If set, the captured image is appended to this node instead of creating a new one.
    var targetNodeID: String? = nil

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
            PhotoPickerWrapper { result in
                Task { await handlePickerResult(result) }
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

    private func handlePickerResult(_ result: PHPickerResult?) async {
        guard let result else { return }
        isSaving = true

        if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
            let image: UIImage? = await withCheckedContinuation { continuation in
                _ = result.itemProvider.loadObject(ofClass: UIImage.self) { reading, _ in
                    continuation.resume(returning: reading as? UIImage)
                }
            }
            if let image {
                await handleCapturedImage(image)
                return
            }
        }
        isSaving = false
        dismiss()
    }

    private func handleCapturedImage(_ image: UIImage) async {
        isSaving = true
        let position = CGPoint(x: Double.random(in: -80...80), y: Double.random(in: -80...80))
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            isSaving = false
            dismiss()
            return
        }

        // AI image description is stubbed in S3 — returns nil on simulator, device support added later.
        let description: String
        if #available(iOS 26.0, *) {
            description = await AIService().describeImage(data) ?? ""
        } else {
            description = ""
        }

        // Vision OCR — run on background thread so it doesn't block UI
        let ocrText = await Task.detached(priority: .userInitiated) {
            Self.extractText(from: image)
        }.value

        await store.addImageItem(
            toNodeID: targetNodeID,
            imageData: data,
            description: description,
            position: position
        )

        // If OCR found text, append it as a text item alongside the image
        if !ocrText.isEmpty {
            let affectedNodeID = targetNodeID ?? store.nodes.first?.id
            if let nodeID = affectedNodeID {
                await store.appendItemToNode(nodeID: nodeID, item: .text(content: ocrText))
            }
        }

        // Trigger AI tagging on the resulting node
        if let nodeID = targetNodeID {
            await store.processNodeWithAI(nodeID: nodeID)
        } else if let newest = store.nodes.first {
            await store.processNodeWithAI(nodeID: newest.id)
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

// MARK: - PHPickerViewController wrapper

private struct PhotoPickerWrapper: UIViewControllerRepresentable {
    let onPick: (PHPickerResult?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (PHPickerResult?) -> Void
        init(onPick: @escaping (PHPickerResult?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results.first)
        }
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
