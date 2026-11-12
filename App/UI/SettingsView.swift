import SwiftUI

struct SettingsView: View {
    private var selectedKinds: [ModelKind] {
        var kinds: [ModelKind] = [.whisper(settings.whisperModel)]
        if settings.useSilero { kinds.append(.silero) }
        if settings.retakeModel.isLLM { kinds.append(.llm(settings.retakeModel)) }
        return kinds
    }

    private func isSelected(_ kind: ModelKind) -> Bool { selectedKinds.contains(kind) }

    private var missingSelected: [ModelKind] {
        selectedKinds.filter { kind in
            switch models.status(kind) {
            case .installed, .working: false
            default: true
            }
        }
    }

    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var models
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    ForEach(ModelKind.all) { kind in
                        ModelRow(kind: kind, inUse: isSelected(kind))
                    }
                    if !missingSelected.isEmpty {
                        Button {
                            for kind in missingSelected { models.install(kind) }
                        } label: {
                            Label(
                                "Скачать выбранные (\(Format.bytes(missingSelected.reduce(0) { $0 + $1.estimatedSize })))",
                                systemImage: "arrow.down.circle.fill")
                        }
                    }
                } header: {
                    Text("Модели")
                } footer: {
                    Text("Модели скачиваются здесь один раз, дальше обработка работает без интернета. «Выбрана» — модель, которая сейчас указана в настройках ниже. Пока идёт скачивание, не сворачивай приложение.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Вырезать паузы длиннее \(settings.minPause, format: .number.precision(.fractionLength(2))) с")
                        Slider(value: $settings.minPause, in: 0.25...2, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text("Отступ перед речью: \(Int(settings.paddingMs)) мс")
                        Slider(value: $settings.paddingMs, in: 20...300, step: 10)
                    }
                    VStack(alignment: .leading) {
                        Text("Тишина после фразы: \(Int(settings.tailPaddingMs)) мс")
                        Slider(value: $settings.tailPaddingMs, in: 0...300, step: 10)
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
                                Text(model.detail + (models.isInstalled(.whisper(model)) ? "" : " · не скачана"))
                                    .font(.footnote).foregroundStyle(.secondary)
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
                                Text(
                                    model.detail
                                        + (model.isLLM && !models.isInstalled(.llm(model)) ? " · не скачана" : "")
                                )
                                .font(.footnote).foregroundStyle(.secondary)
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Поиск дублей")
                } footer: {
                    Text("Если большой модели не хватит памяти, приложение переключится на запасную, когда она скачана.")
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
                    LabeledContent("Занято моделями", value: Format.bytes(models.totalSize))
                    Button("Удалить все модели", role: .destructive) { confirmDelete = true }
                        .disabled(models.totalSize == 0 || models.isBusy)
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
                    models.deleteAll()
                }
            } message: {
                Text("Чтобы снова обрабатывать видео, их нужно будет скачать заново.")
            }
            .onAppear { models.refresh() }
        }
    }
}

/// Строка модели: размер, состояние, скачать / отменить / удалить.
struct ModelRow: View {
    let kind: ModelKind
    var inUse = false

    @Environment(ModelManager.self) private var models
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.title)
                        if inUse {
                            Text("выбрана")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            if case .working(let fraction, let text) = models.status(kind) {
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    ProgressView(value: nil as Double?).progressViewStyle(.linear)
                }
                Text(text + (fraction.map { " · \(Int($0 * 100))%" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let message) = models.status(kind) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Удалить \(kind.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { models.delete(kind) }
        }
    }

    private var subtitle: String {
        switch models.status(kind) {
        case .installed(let size): "\(kind.purpose) · скачана, \(Format.bytes(size))"
        default: "\(kind.purpose) · ≈ \(Format.bytes(kind.estimatedSize))"
        }
    }

    @ViewBuilder
    private var action: some View {
        switch models.status(kind) {
        case .installed:
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Удалить")
        case .working:
            Button {
                models.cancel(kind)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Отменить")
        case .notInstalled, .failed:
            Button {
                models.install(kind)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Скачать")
        }
    }
}
