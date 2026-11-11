import CutCore
import Foundation
import Observation

@MainActor
@Observable
final class ExportModel {
    enum State: Equatable {
        case idle
        case exporting
        case finished(URL)
        case failed(String, String)
    }

    private(set) var state: State = .idle
    private(set) var progress: Double = 0
    private(set) var savedToPhotos = false
    private(set) var isSaving = false
    var saveError: AppError?

    @ObservationIgnored private var task: Task<Void, Never>?

    var isExporting: Bool { state == .exporting }

    func start(project: Project, bitrate: Int) {
        guard !isExporting else { return }
        state = .exporting
        progress = 0
        savedToPhotos = false
        let sourceURL = ProjectStore.sourceURL(for: project)
        let outputURL = Self.outputURL(for: project)
        let cuts = project.finalCuts
        BackgroundKeeper.shared.begin(title: "CleanCut: экспорт ролика")

        let throttle = ProgressThrottle { [weak self] value in
            guard let self, self.isExporting else { return }
            self.progress = value
            BackgroundKeeper.shared.update(progress: value, subtitle: "Экспорт")
        }

        task = Task {
            var success = false
            do {
                try await VideoExporter.export(
                    sourceURL: sourceURL, cuts: cuts, outputURL: outputURL, bitrate: bitrate
                ) { throttle.report($0) }
                progress = 1
                state = .finished(outputURL)
                success = true
            } catch is CancellationError {
                state = .idle
            } catch {
                let appError = AppError.wrap(error, title: "Экспорт не удался")
                state = Task.isCancelled ? .idle : .failed(appError.title, appError.message)
            }
            BackgroundKeeper.shared.end(success: success)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        guard !isExporting else { return }
        state = .idle
    }

    func saveToPhotos() {
        guard case .finished(let url) = state, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await PhotoSaver.save(url)
                savedToPhotos = true
            } catch {
                saveError = AppError.wrap(error, title: "Не сохранилось")
            }
        }
    }

    /// Готовый файл лежит в папке проекта под понятным именем: его видно в «Файлах» и в share sheet.
    static func outputURL(for project: Project) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        var name = String(project.title.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "video" }
        return ProjectStore.directory(for: project.id).appendingPathComponent("\(name.prefix(60)) CleanCut.mp4")
    }
}
