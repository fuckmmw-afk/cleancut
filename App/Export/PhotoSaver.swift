import Foundation
import Photos

enum PhotoSaver {
    /// Сохраняет ролик в Фото. Запрашивается только право на добавление.
    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw AppError(
                "Нет доступа к Фото",
                "Разреши CleanCut добавлять видео: Настройки → Приложения → CleanCut → Фото. Или отправь файл через «Поделиться»."
            )
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: url, options: options)
            }
        } catch {
            throw AppError("Не сохранилось", "Фото не приняло ролик: \(error.localizedDescription)")
        }
    }
}
