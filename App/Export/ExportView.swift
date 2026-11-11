import SwiftUI

struct ExportView: View {
    let project: Project
    @Bindable var model: ExportModel

    @Environment(AppSettings.self) private var settings
    @Environment(ThermalMonitor.self) private var thermal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch model.state {
                case .idle:
                    idle
                case .exporting:
                    exporting
                case .finished(let url):
                    finished(url)
                case .failed(let title, let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.red)
                        Text(title).font(.headline)
                        Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Попробовать ещё раз") { start() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Экспорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isExporting ? "Отменить" : "Закрыть") {
                        if model.isExporting { model.cancel() } else { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(model.isExporting)
            .errorAlert($model.saveError)
        }
        .presentationDetents([.medium, .large])
    }

    private var bitrate: Int { settings.bitrate(forFPS: project.fps) }

    private var idle: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("\(Format.duration(project.duration)) → \(Format.duration(project.outputDuration))")
                    .font(.title2.weight(.semibold))
                Text("HEVC · \(project.width)×\(project.height) · \(Int(project.fps.rounded())) кадров/с · \(bitrate / 1_000_000) Мбит/с")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Примерный размер: \(Format.bytes(Int64(Double(bitrate + 192_000) / 8 * project.outputDuration)))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                start()
            } label: {
                Label("Экспортировать", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var exporting: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.progress) {
                Text("Кодирую видео")
            } currentValueLabel: {
                Text("\(Int(model.progress * 100))%")
            }
            Banner(
                icon: "iphone.radiowaves.left.and.right", tint: .orange,
                text: "Не сворачивай приложение и не блокируй экран, пока идёт экспорт.")
            if let warning = thermal.warning {
                Banner(icon: "thermometer.high", tint: .red, text: warning)
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(Color.accentColor)
            Text("Ролик готов").font(.title3.weight(.semibold))
            Text("\(Format.duration(project.outputDuration)) · \(Format.bytes(Disk.fileSize(url)))")
                .font(.footnote).foregroundStyle(.secondary)

            Button {
                model.saveToPhotos()
            } label: {
                Group {
                    if model.isSaving {
                        ProgressView()
                    } else if model.savedToPhotos {
                        Label("Сохранено в Фото", systemImage: "checkmark")
                    } else {
                        Label("Сохранить в Фото", systemImage: "photo.badge.plus")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.isSaving || model.savedToPhotos)

            ShareLink(item: url) {
                Label("Поделиться", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private func start() {
        model.start(project: project, bitrate: bitrate)
    }
}
