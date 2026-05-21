import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Stage 3.1a commit (c) — UIKit bridge for `UIDocumentPickerViewController`,
/// presented as a sheet from `NodeDetailView` when the user taps the "+"
/// dropdown's Document item, and from `DocumentGalleryBody`'s chrome "+"
/// for within-entry appends.
///
/// Stage 4.6 commit 3 — multi-select. The picker now returns `[URL]` (the
/// user can select multiple files in one pass) and `onPick` is called once
/// per pick session with the full set. Caller is responsible for copying
/// contents into the corpus before the security scopes expire. An empty
/// `urls` parameter is theoretically not reachable (the system doesn't
/// invoke the delegate when nothing was picked — it calls
/// `documentPickerWasCancelled` instead), but callers should still guard
/// since multi-select pickers have been observed to return empty arrays
/// on some iOS versions.
///
/// `.import` mode is used (not `.open`) so the system hands us a coordinated
/// snapshot rather than a live reference. That matches how audio/image are
/// already imported — `CorpusStore.saveItemFile` does a straight FileManager
/// copy, no provider coordination needed downstream.
struct DocumentPickerView: UIViewControllerRepresentable {

    let onPick: ([URL]) -> Void

    /// `.data` is the broadest reasonable type — PDFs, Office docs, plain
    /// text, archives, anything the system has a UTType for. If the corpus
    /// later grows opinions about acceptable document types, narrow this.
    private static let allowedTypes: [UTType] = [.data]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.allowedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // No-op — the picker is a one-shot modal.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // No-op — sheet dismissal is handled by SwiftUI via the @State binding.
        }
    }
}
