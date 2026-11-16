import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Выбор видео из «Файлов». Система сама докачивает файл из iCloud и отдаёт нам копию,
/// поэтому не нужен ни security-scoped доступ, ни чтение файла на месте.
struct DocumentVideoPicker: UIViewControllerRepresentable {
    /// Вызывается на главном потоке: nil, если пользователь закрыл выбор.
    var onFinish: @MainActor (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie], asCopy: true)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIDocumentPickerDelegate {
        let onFinish: @MainActor (URL?) -> Void

        init(onFinish: @escaping @MainActor (URL?) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(nil)
        }
    }
}
