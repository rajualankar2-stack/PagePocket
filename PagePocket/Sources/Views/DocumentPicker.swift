import SwiftUI
import UniformTypeIdentifiers

/// Wraps `UIDocumentPickerViewController` in "open" mode.
///
/// `asCopy: false` is deliberate: it lets the user pick a *folder* so a
/// document's CSS, scripts and images come with it, which is what makes
/// relative paths and `fetch()` work once the folder is served over HTTP.
struct DocumentPicker: UIViewControllerRepresentable {

    /// Content types offered in the picker.
    var contentTypes: [UTType] = DocumentPicker.defaultContentTypes

    /// Called with the chosen URLs. Must be consumed synchronously by the
    /// caller (or copied) — see ``AppModel/handleIncomingFile(_:)``.
    var onPick: ([URL]) -> Void

    static var defaultContentTypes: [UTType] {
        var types: [UTType] = []
        if let html = UTType("public.html") { types.append(html) }
        types.append(.html)
        types.append(.folder)
        types.append(.zip)
        types.append(.plainText)
        if let svg = UTType("public.svg-image") { types.append(svg) }
        return types
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Nothing to do; the sheet simply closes.
        }
    }
}

/// A picker constrained to a single file, used for `<input type="file">`.
struct SingleFilePicker: UIViewControllerRepresentable {

    var allowsMultipleSelection: Bool
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
