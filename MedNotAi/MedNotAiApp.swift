//
//  MedNotAiApp.swift
//  MedNotAi
//
//  Created by Kemal Zeitulaev on 03.09.2026.
//

import SwiftUI
import SwiftData

@main
struct MedNotAiApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let store: PersistentStore = PersistentStore.make()

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(\.storeRecoveryNotice, store.recoveryNotice)
                .environment(\.isCloudSyncEnabled, store.isCloudSyncEnabled)
        }
        .modelContainer(store.container)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await AuthService.shared.refreshAppleCredentialState()
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        #endif
    }

    @ViewBuilder
    private var rootView: some View {
        #if os(macOS)
        RootView()
            .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        #else
        RootView()
        #endif
    }
}

// MARK: - Хранилище

/// Поднимает SwiftData так, чтобы приложение никогда не падало на старте,
/// но и не теряло данные молча.
///
/// Раньше при несовместимой схеме файл базы просто удалялся: приложение
/// запускалось, а все конспекты пользователя исчезали без предупреждения.
/// Теперь старый файл отправляется в резервную копию, а пользователь видит
/// сообщение о том, что произошло и где искать данные.
struct PersistentStore {
    let container: ModelContainer
    let recoveryNotice: StoreRecoveryNotice?
    /// Конспекты уходят в iCloud. Если контейнер не открылся — работаем только локально.
    let isCloudSyncEnabled: Bool

    private static let schema = Schema([
        Note.self, Flashcard.self, StudyEvent.self,
        ChatThread.self, ChatMessage.self, StudyGroup.self,
        LectureRecording.self, NotePhoto.self
    ])

    static func make() -> PersistentStore {
        let cloud = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private(AccountCloud.containerID)
        )
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            return PersistentStore(container: container, recoveryNotice: nil, isCloudSyncEnabled: true)
        }

        let local = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [local]) {
            return PersistentStore(container: container, recoveryNotice: nil, isCloudSyncEnabled: false)
        }

        // Схема не сошлась. Уводим старый файл в сторону и пробуем начать заново.
        let backup = archiveStore(at: local.url)
        if let container = try? ModelContainer(for: schema, configurations: [cloud]) {
            return PersistentStore(container: container, recoveryNotice: .init(backupURL: backup, isMemoryOnly: false), isCloudSyncEnabled: true)
        }
        if let container = try? ModelContainer(for: schema, configurations: [local]) {
            return PersistentStore(container: container, recoveryNotice: .init(backupURL: backup, isMemoryOnly: false), isCloudSyncEnabled: false)
        }

        // Даже чистый файл не открылся — работаем в памяти, чтобы дать
        // пользователю добраться до настроек и выгрузить резервную копию.
        let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: schema, configurations: [fallback]) {
            return PersistentStore(container: container, recoveryNotice: .init(backupURL: backup, isMemoryOnly: true), isCloudSyncEnabled: false)
        }

        // Недостижимо: контейнер в памяти не зависит ни от файловой системы,
        // ни от миграций. Если и он не создался, работать всё равно нечем.
        fatalError("Не удалось создать хранилище SwiftData даже в памяти")
    }

    /// Переименовывает файлы базы, добавляя метку времени. Возвращает путь к копии.
    private static func archiveStore(at url: URL) -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }

        let stamp = DateFormatter.backupStamp.string(from: Date())
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        var archived: URL?

        // SwiftData держит рядом с базой файлы -wal и -shm: переносим их тоже,
        // иначе SQLite подхватит журнал от старой схемы.
        let siblings = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in siblings where file.lastPathComponent.hasPrefix(name) {
            let suffix = file.lastPathComponent.dropFirst(name.count)
            let destination = directory.appendingPathComponent("\(name).backup-\(stamp)\(suffix)")
            guard (try? manager.moveItem(at: file, to: destination)) != nil else { continue }
            if suffix.isEmpty { archived = destination }
        }
        return archived
    }
}

/// Что случилось с базой при запуске — показываем это на «Главной».
struct StoreRecoveryNotice: Equatable {
    let backupURL: URL?
    /// Данные существуют только в памяти и пропадут при закрытии приложения.
    let isMemoryOnly: Bool

    var title: String {
        isMemoryOnly ? "База данных недоступна" : "База данных пересоздана"
    }

    var message: String {
        if isMemoryOnly {
            return "Приложение работает во временном режиме: всё, что вы создадите сейчас, исчезнет после закрытия. Переустановите приложение, чтобы восстановить работу."
        }
        if backupURL != nil {
            return "Формат хранения изменился, поэтому база создана заново. Прежние записи сохранены в резервной копии рядом с базой приложения."
        }
        return "Формат хранения изменился, поэтому база создана заново."
    }
}

private struct StoreRecoveryKey: EnvironmentKey {
    static let defaultValue: StoreRecoveryNotice? = nil
}

private struct CloudSyncKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var storeRecoveryNotice: StoreRecoveryNotice? {
        get { self[StoreRecoveryKey.self] }
        set { self[StoreRecoveryKey.self] = newValue }
    }

    var isCloudSyncEnabled: Bool {
        get { self[CloudSyncKey.self] }
        set { self[CloudSyncKey.self] = newValue }
    }
}

private extension DateFormatter {
    /// Без двоеточий: они допустимы в путях POSIX, но ломают отображение в Finder.
    static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
