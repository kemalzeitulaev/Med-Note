import Foundation
import AVFoundation
import Speech

/// Локальный кэш голосовых лекций. Источник правды для синхронизации — `audioData` в SwiftData.
enum LectureAudioStore {
    static func directory(for noteID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Lectures/\(noteID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(for recording: LectureRecording, noteID: UUID) -> URL {
        directory(for: noteID).appendingPathComponent(recording.fileName)
    }

    static func makeFileName() -> String {
        "lecture-\(Int(Date().timeIntervalSince1970)).m4a"
    }

    /// Кладёт файл в модель, чтобы он уехал в iCloud вместе с конспектом.
    static func attach(_ recording: LectureRecording, fileAt fileURL: URL, noteID: UUID) {
        recording.fileName = fileURL.lastPathComponent
        recording.audioData = (try? Data(contentsOf: fileURL)) ?? Data()
        let cache = url(for: recording, noteID: noteID)
        if fileURL.standardizedFileURL != cache.standardizedFileURL {
            try? FileManager.default.copyItem(at: fileURL, to: cache)
        }
    }

    /// Старые записи жили только на диске — подхватываем файл в модель при случае.
    static func hydrateIfNeeded(_ recording: LectureRecording, noteID: UUID) {
        guard recording.audioData.isEmpty else { return }
        let file = url(for: recording, noteID: noteID)
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return }
        recording.audioData = data
    }

    /// Путь для воспроизведения: сначала кэш, иначе достаём из синхронизированных данных.
    static func resolvedURL(for recording: LectureRecording, noteID: UUID) -> URL? {
        let file = url(for: recording, noteID: noteID)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !recording.audioData.isEmpty else { return nil }
        do {
            try recording.audioData.write(to: file, options: [.atomic])
            return file
        } catch {
            return nil
        }
    }

    static func remove(_ recording: LectureRecording, noteID: UUID) {
        let file = url(for: recording, noteID: noteID)
        try? FileManager.default.removeItem(at: file)
        recording.audioData = Data()
    }
}

/// Запись лекции в AAC. Сессия микрофона настраивается только на iOS.
@Observable
final class LectureRecorder {
    private(set) var isRecording = false
    private(set) var duration: TimeInterval = 0
    private(set) var lastError: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    func prepare(noteID: UUID) throws -> URL {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif
        let url = LectureAudioStore.directory(for: noteID)
            .appendingPathComponent(LectureAudioStore.makeFileName())
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.prepareToRecord()
        fileURL = url
        return url
    }

    func start(noteID: UUID) {
        lastError = nil
        do {
            let url = try prepare(noteID: noteID)
            guard recorder?.record() == true else {
                lastError = "Не удалось начать запись."
                return
            }
            fileURL = url
            isRecording = true
            duration = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.duration = self?.recorder?.currentTime ?? 0
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() -> (url: URL, duration: TimeInterval)? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        let seconds = recorder?.currentTime ?? duration
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        guard let fileURL else { return nil }
        return (fileURL, seconds)
    }
}

private final class SpeechTaskBox: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
}

struct TranscriptResult {
    var text: String
    var segments: [TranscriptSegment]
}

enum LectureTranscriber {
    static func authorized() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status == .denied || status == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { result in
                continuation.resume(returning: result == .authorized)
            }
        }
    }

    static func transcribe(url: URL, locale: Locale = Locale(identifier: "ru-RU")) async throws -> TranscriptResult {
        guard await authorized() else {
            throw TranscribeError.notAllowed
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw TranscribeError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let box = SpeechTaskBox()
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !finished {
                        finished = true
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if !finished {
                    finished = true
                    let pieces = result.bestTranscription.segments.map { segment in
                        TranscriptSegment(
                            text: segment.substring,
                            start: segment.timestamp,
                            duration: segment.duration
                        )
                    }
                    continuation.resume(returning: TranscriptResult(
                        text: result.bestTranscription.formattedString,
                        segments: pieces
                    ))
                }
            }
            withExtendedLifetime(box) {}
        }
    }

    enum TranscribeError: LocalizedError {
        case notAllowed, unavailable
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Разрешите распознавание речи в настройках, чтобы получить расшифровку лекции."
            case .unavailable: "Распознавание речи сейчас недоступно."
            }
        }
    }
}

@Observable
final class LecturePlayer {
    private var player: AVAudioPlayer?
    private var tick: Timer?
    private(set) var isPlaying = false
    private(set) var currentID: UUID?
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    func toggle(_ recording: LectureRecording, noteID: UUID) {
        if currentID == recording.id {
            if isPlaying {
                player?.pause()
                isPlaying = false
            } else if player != nil {
                player?.play()
                isPlaying = true
            } else {
                play(recording, noteID: noteID)
            }
            return
        }
        play(recording, noteID: noteID)
    }

    func play(_ recording: LectureRecording, noteID: UUID, at time: TimeInterval = 0) {
        guard let url = LectureAudioStore.resolvedURL(for: recording, noteID: noteID) else {
            isPlaying = false
            currentID = nil
            return
        }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if currentID != recording.id || player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
            }
            player?.currentTime = max(0, time)
            player?.play()
            isPlaying = true
            currentID = recording.id
            duration = player?.duration ?? recording.duration
            currentTime = player?.currentTime ?? time
            startTick()
        } catch {
            isPlaying = false
            currentID = nil
        }
    }

    func seek(_ recording: LectureRecording, noteID: UUID, to time: TimeInterval) {
        if currentID == recording.id, player != nil {
            player?.currentTime = max(0, time)
            currentTime = player?.currentTime ?? time
            if player?.isPlaying == false {
                player?.play()
                isPlaying = true
            }
            return
        }
        play(recording, noteID: noteID, at: time)
    }

    func stop() {
        tick?.invalidate()
        tick = nil
        player?.stop()
        isPlaying = false
        currentID = nil
        currentTime = 0
    }

    private func startTick() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.player?.currentTime ?? 0
                self.duration = self.player?.duration ?? self.duration
                if self.player?.isPlaying == false, self.isPlaying {
                    let ended = (self.player?.currentTime ?? 0) >= max(0, (self.player?.duration ?? 0) - 0.2)
                    if ended { self.isPlaying = false }
                }
            }
        }
    }
}
