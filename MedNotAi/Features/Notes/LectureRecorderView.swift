import SwiftUI
import SwiftData

/// Запись голосовой лекции, расшифровка и добавление текста в конспект.
struct LectureRecorderView: View {
    @Bindable var note: Note

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = LectureRecorder()
    @State private var player = LecturePlayer()
    @State private var isTranscribing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        recordCard
                        if !note.recordings.isEmpty { recordingsCard }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .readableWidth(520)
                }
            }
            .navigationTitle("Голосовая лекция")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        if recorder.isRecording { _ = recorder.stop() }
                        player.stop()
                        dismiss()
                    }
                }
            }
            .onAppear {
                for item in note.recordings {
                    LectureAudioStore.hydrateIfNeeded(item, noteID: note.id)
                }
                if !note.recordings.isEmpty { try? context.save() }
            }
            .alert("Не получилось", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("Понятно") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var recordCard: some View {
        GlassCard(padding: 22) {
            VStack(spacing: 16) {
                GradientIcon(systemName: recorder.isRecording ? "waveform" : "mic.fill", size: 72)
                Text(recorder.isRecording ? "Идёт запись" : "Запишите лекцию")
                    .font(.title3.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(recorder.isRecording
                     ? format(recorder.duration)
                     : "После остановки речь будет расшифрована и её можно вставить в конспект.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                if let lastError = recorder.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }

                Button(recorder.isRecording ? "Остановить" : "Начать запись") {
                    if recorder.isRecording {
                        finishRecording()
                    } else {
                        recorder.start(noteID: note.id)
                    }
                }
                .buttonStyle(BrandButtonStyle())
            }
        }
    }

    private var recordingsCard: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Записи")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)

                ForEach(note.recordings.sorted { $0.createdAt > $1.createdAt }) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button {
                                player.toggle(item, noteID: note.id)
                            } label: {
                                Image(systemName: player.currentID == item.id && player.isPlaying
                                      ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Theme.primary)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.createdAt.localized(Date.FormatStyle(date: .abbreviated, time: .shortened)))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(item.displayDuration)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                delete(item)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Theme.danger)
                            }
                            .buttonStyle(.plain)
                        }

                        if !item.segments.isEmpty || !item.transcript.isEmpty {
                            TranscriptTimeline(
                                recording: item,
                                noteID: note.id,
                                player: player
                            )
                            Button("Добавить расшифровку в конспект") {
                                appendTranscript(item.flowingTranscript)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                        } else if isTranscribing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if item.id != note.recordings.sorted(by: { $0.createdAt > $1.createdAt }).last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
    }

    private func finishRecording() {
        guard let result = recorder.stop() else { return }
        let recording = LectureRecording(fileName: result.url.lastPathComponent, duration: result.duration)
        note.recordings.append(recording)
        LectureAudioStore.attach(recording, fileAt: result.url, noteID: note.id)
        note.updatedAt = Date()
        try? context.save()
        Task { await transcribe(recording, url: result.url) }
    }

    private func transcribe(_ recording: LectureRecording, url: URL) async {
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let result = try await LectureTranscriber.transcribe(url: url)
            recording.transcript = result.text
            recording.segments = result.segments
            note.updatedAt = Date()
            try? context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendTranscript(_ text: String) {
        let block = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !block.isEmpty else { return }
        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note.body = block
        } else {
            note.body += "\n\n" + block
        }
        if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note.title = "Лекция \(note.createdAt.localized(Date.FormatStyle(date: .abbreviated, time: .omitted)))"
        }
        note.updatedAt = Date()
        try? context.save()
    }

    private func delete(_ recording: LectureRecording) {
        if player.currentID == recording.id { player.stop() }
        LectureAudioStore.remove(recording, noteID: note.id)
        context.delete(recording)
        note.updatedAt = Date()
        try? context.save()
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Связная расшифровка: слова идут подряд, нажатие всё ещё перематывает запись.
struct TranscriptTimeline: View {
    let recording: LectureRecording
    let noteID: UUID
    var player: LecturePlayer

    private var words: [TranscriptSegment] {
        if recording.segments.isEmpty, !recording.transcript.isEmpty {
            return [TranscriptSegment(text: recording.transcript, start: 0, duration: recording.duration)]
        }
        return recording.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Нажмите на слово — запись перейдёт к этому месту")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)

            TranscriptFlowLayout(spacing: 5, lineSpacing: 6) {
                ForEach(words) { segment in
                    let active = player.currentID == recording.id
                        && player.currentTime >= segment.start
                        && player.currentTime < segment.start + max(segment.duration, 0.35)
                    Button {
                        player.seek(recording, noteID: noteID, to: segment.start)
                    } label: {
                        Text(segment.text)
                            .font(.body)
                            .foregroundStyle(active ? Theme.primary : Theme.textPrimary)
                            .padding(.horizontal, 2)
                            .background(active ? Theme.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Строки расшифровки без разрывов: слова переносятся как обычный абзац.
/// `SwiftUI.Layout` — иначе конфликт с enum Layout в DesignSystem.
private struct TranscriptFlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(in: proposal.width ?? 0, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(in: bounds.width, subviews: subviews).positions
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(
                at: CGPoint(x: bounds.minX + positions[index].x, y: bounds.minY + positions[index].y),
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let limit = width > 0 ? width : .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var positions: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > limit, x > 0 {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            lineHeight = max(lineHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: limit.isFinite ? limit : x, height: y + lineHeight), positions)
    }
}
