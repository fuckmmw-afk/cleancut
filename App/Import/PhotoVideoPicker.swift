import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Выбор видео из Фото через PHPicker. Доступ к медиатеке не запрашивается.
struct PhotoVideoPicker: UIViewControllerRepresentable {
    /// Вызывается на главном потоке: nil, если пользователь закрыл пикер.
    var onStart: @MainActor () -> Void
    /// Доля загрузки 0…1: видео из iCloud сначала скачивается.
    var onProgress: @MainActor (Double) -> Void = { _ in }
    var onFinish: @MainActor (Result<URL, any Error>?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        configuration.selectionLimit = 1
        // .current отдаёт оригинал без перекодирования в H.264.
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onStart: onStart, onProgress: onProgress, onFinish: onFinish)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onStart: @MainActor () -> Void
        let onProgress: @MainActor (Double) -> Void
        let onFinish: @MainActor (Result<URL, any Error>?) -> Void

        init(
            onStart: @escaping @MainActor () -> Void,
            onProgress: @escaping @MainActor (Double) -> Void,
            onFinish: @escaping @MainActor (Result<URL, any Error>?) -> Void
        ) {
            self.onStart = onStart
            self.onProgress = onProgress
            self.onFinish = onFinish
        }

        nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let start = onStart
            let report = onProgress
            let finish = onFinish
            guard let provider = results.first?.itemProvider,
                provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            else {
                Task { @MainActor in finish(nil) }
                return
            }
            Task { @MainActor in start() }
            // Просим тот тип, в котором видео лежит в медиатеке (обычно com.apple.quicktime-movie).
            // На общий public.movie система может перекодировать ролик, и это идёт минутами.
            let type =
                provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true }
                ?? UTType.movie.identifier
            // Система выгружает видео во временный файл и удаляет его после выхода из колбэка,
            // поэтому забираем файл прямо здесь, синхронно.
            nonisolated(unsafe) let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                let result: Result<URL, any Error>
                if let url {
                    result = Result { try VideoImporter.stage(url) }
                } else {
                    result = .failure(
                        error
                            ?? AppError(
                                "Видео не загрузилось",
                                "Не получилось получить видео из Фото. Если оно в iCloud, дождись загрузки."))
                }
                Task { @MainActor in finish(result) }
            }
            Task { @MainActor in
                while !progress.isFinished, !progress.isCancelled {
                    report(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }
}
