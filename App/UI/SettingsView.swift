import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var modelsSize: Int64 = 0
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("Вырезать паузы длиннее \(settings.minPause, format: .number.precision(.fractionLength(2))) с")
                        Slider(value: $settings.minPause, in: 0.25...2, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Отступ вокруг речи: \(Int(settings.paddingMs)) мс")
                        Slider(value: $settings.paddingMs, in: 40...300, step: 10)
                    }
                    Toggle("Silero VAD", isOn: $settings.useSilero)
                } header: {
                    Text("Паузы")
                } footer: {
                    Text("Silero VAD точнее отличает речь от шума. Если его выключить или он не загрузится, паузы ищутся по громкости.")
                }

                Section {
                    Picker("Модель", selection: $settings.whisperModel) {
                        ForEach(WhisperModel.allCases) { model in
                            VStack(alignment: .leading) {
                                Text(model.title)
                                Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Распознавание речи (Whisper)")
                }

                Section {
                    Picker("Модель", selection: $settings.retakeModel) {
                        ForEach(RetakeModel.allCases) { model in
                            VStack(alignment: .leading) {
                                Text(model.title)
                                Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Поиск дублей")
                } footer: {
                    Text("Если большой модели не хватит памяти, приложение само переключится на запасную.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("До 30 кадров/с: \(Int(settings.bitrate30)) Мбит/с")
                        Slider(value: $settings.bitrate30, in: 4...40, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("50–60 кадров/с: \(Int(settings.bitrate60)) Мбит/с")
                        Slider(value: $settings.bitrate60, in: 6...60, step: 1)
                    }
                } header: {
                    Text("Экспорт (HEVC)")
                } footer: {
                    Text("Разрешение и частота кадров остаются как у исходника.")
                }

                Section {
                    LabeledContent("Скачанные модели", value: Format.bytes(modelsSize))
                    Button("Удалить модели", role: .destructive) { confirmDelete = true }
                        .disabled(modelsSize == 0)
                } footer: {
                    Text("Модели скачиваются при первой обработке. После этого интернет не нужен.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Удалить скачанные модели?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    ModelStore.deleteAll()
                    modelsSize = 0
                }
            } message: {
                Text("При следующей обработке они скачаются заново.")
            }
            .task {
                modelsSize = await Task.detached { ModelStore.totalSize() }.value
            }
        }
    }
}
