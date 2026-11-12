import CutCore
import SwiftUI

struct ReviewView: View {
    let projectID: UUID
    var onReanalyze: () -> Void = {}

    @Environment(ProjectStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: ReviewModel?
    @State private var exportModel = ExportModel()
    @State private var showExport = false
    @State private var confirmReanalyze = false

    var body: some View {
        Group {
            if let model {
                ReviewContent(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.project.title ?? "Ревью")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let model {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!model.canUndo)
                    .accessibilityLabel("Отменить правку")

                    Menu {
                        Button {
                            model.recomputePauses(
                                minPause: settings.minPause, padding: settings.paddingMs / 1000,
                                tailPadding: settings.tailPaddingMs / 1000)
                        } label: {
                            Label("Пересчитать паузы по настройкам", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button {
                            confirmReanalyze = true
                        } label: {
                            Label("Найти дубли заново", systemImage: "sparkles")
                        }
                        if let logURL = model.logURL {
                            ShareLink(item: logURL) {
                                Label("Журнал анализа", systemImage: "doc.text")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }

                    Button("Экспорт") {
                        model.pause()
                        exportModel.reset()
                        showExport = true
                    }
                    .fontWeight(.semibold)
                    .disabled(!model.isReady)
                }
            }
        }
        .confirmationDialog("Найти дубли заново?", isPresented: $confirmReanalyze, titleVisibility: .visible) {
            Button("Найти заново") {
                model?.prepareReanalysis()
                onReanalyze()
            }
        } message: {
            Text("Распознавать речь заново не придётся. Паузы и дубли посчитаются с текущими настройками, ручные правки сбросятся.")
        }
        .sheet(isPresented: $showExport) {
            if let model {
                ExportView(project: model.project, model: exportModel)
            }
        }
        .task {
            guard model == nil, let project = store.project(projectID) else { return }
            let created = ReviewModel(project: project, store: store)
            model = created
            await created.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model?.pause() }
        }
        .onDisappear {
            exportModel.cancel()
            model?.teardown()
        }
    }
}

private struct ReviewContent: View {
    @Bindable var model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            player
            transport
            stats
            Picker("Режим тапа", selection: $model.tapMode) {
                ForEach(ReviewModel.TapMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)

            legend

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.project.notes, id: \.self) { note in
                        Banner(icon: "info.circle", tint: .blue, text: note.replacingOccurrences(of: "\u{200B}", with: ""))
                            .padding(.bottom, 6)
                    }
                    ForEach(model.items) { item in
                        switch item {
                        case .phrase(let phrase):
                            PhraseRow(phrase: phrase, model: model)
                        case .pause(let cut):
                            PauseRow(cut: cut, model: model)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if model.tapMode == .select {
                selectionBar
            }
        }
        .errorAlert($model.error)
    }

    private var player: some View {
        let ratio = CGFloat(max(model.project.width, 1)) / CGFloat(max(model.project.height, 1))
        return PlayerSurface(player: model.player)
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 280)
            .background(.black)
            .overlay {
                if !model.isReady {
                    ProgressView()
                } else if !model.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30))
                        .padding(18)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Text(Format.duration(model.currentOutputTime)).monospacedDigit()
            Slider(
                value: Binding(
                    get: { model.currentOutputTime },
                    set: { model.seek(toOutput: $0) }),
                in: 0...max(model.outputDuration, 0.1))
            Text(Format.duration(model.outputDuration)).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            StatCell(title: "Было", value: Format.duration(model.project.duration))
            StatCell(title: "Стало", value: Format.duration(model.outputDuration), accent: true)
            StatCell(title: "Вырезано", value: Format.duration(max(0, model.project.duration - model.outputDuration)))
            StatCell(title: "Резов", value: "\(model.cutCount)")
        }
        .padding(.vertical, 8)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([CutKind.pause, .retake, .falseStart, .garbage, .manual], id: \.self) { kind in
                HStack(spacing: 4) {
                    Circle().fill(kind.color).frame(width: 7, height: 7)
                    Text(kind.label)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private var selectionBar: some View {
        HStack {
            if model.selection == nil {
                Text("Тапни первое и последнее слово куска").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text(model.selectionText).font(.footnote).monospacedDigit()
                Spacer()
                Button("Сброс") { model.clearSelection() }
                    .buttonStyle(.bordered)
                Button("Вернуть") { model.restoreSelection() }
                    .buttonStyle(.bordered)
                Button("Вырезать") { model.cutSelection() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct StatCell: View {
    let title: String
    let value: String
    var accent = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(accent ? Color.accentColor : .primary)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PhraseRow: View {
    let phrase: Phrase
    let model: ReviewModel

    var body: some View {
        let kind = model.phraseKind(phrase)
        let isCurrent = model.isCurrent(phrase)

        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? Color.accentColor : (kind?.color.opacity(0.7) ?? .clear))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Format.timecode(phrase.start)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    if let kind {
                        Text(kind.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(kind.color.opacity(0.25), in: Capsule())
                            .foregroundStyle(kind.color)
                    } else if let suggestion = model.suggestion(for: phrase) {
                        Text("возможно \(suggestion.kind.label)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(suggestion.kind.color.opacity(0.6), lineWidth: 1))
                            .foregroundStyle(suggestion.kind.color.opacity(0.8))
                    }
                }
                if let note = (model.activeCut(for: phrase) ?? model.suggestion(for: phrase))?.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                if model.tapMode == .select {
                    words
                } else {
                    Text(attributed).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            (kind?.color.opacity(0.08) ?? .clear), in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.tapMode != .select { model.tapPhrase(phrase) }
        }
        .accessibilityAddTraits(.isButton)
    }

    private func kind(at index: Int) -> CutKind? {
        model.wordKinds.indices.contains(index) ? model.wordKinds[index] : nil
    }

    /// Текст фразы: вырезанные слова зачёркнуты и подсвечены цветом причины.
    private var attributed: AttributedString {
        var result = AttributedString()
        for index in phrase.wordRange where model.project.words.indices.contains(index) {
            var run = AttributedString(model.project.words[index].text + " ")
            if let kind = kind(at: index) {
                run.swiftUI.strikethroughStyle = Text.LineStyle.single
                run.swiftUI.foregroundColor = kind.color
            }
            result.append(run)
        }
        return result
    }

    private var words: some View {
        FlowLayout {
            ForEach(Array(phrase.wordRange), id: \.self) { index in
                if model.project.words.indices.contains(index) {
                    let kind = kind(at: index)
                    let selected = model.selection?.contains(index) ?? false
                    Text(model.project.words[index].text)
                        .strikethrough(kind != nil)
                        .foregroundStyle(selected ? Color.black : (kind?.color ?? .primary))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            selected ? Color.accentColor : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .onTapGesture { model.tapWord(index) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PauseRow: View {
    let cut: Cut
    let model: ReviewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: cut.enabled ? "scissors" : "pause.fill").font(.caption2)
            Text("пауза \(String(format: "%.1f", cut.end - cut.start)) с")
                .strikethrough(cut.enabled)
            Text(cut.enabled ? "вырезана" : "оставлена").foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(cut.enabled ? CutKind.pause.color : .primary)
        .padding(.vertical, 4)
        .padding(.horizontal, 17)
        .contentShape(Rectangle())
        .onTapGesture { model.tapPause(cut) }
        .accessibilityAddTraits(.isButton)
    }
}
