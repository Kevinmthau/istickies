import Foundation

actor StickyNotesFileStore {
    private let fileURL: URL
    private let backupFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var latestGeneratedSave = 0

    init(fileURL: URL = StickyNotesFileStore.defaultFileURL()) {
        self.fileURL = fileURL
        backupFileURL = URL(fileURLWithPath: fileURL.path + ".bak")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> StickyNotesSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if FileManager.default.fileExists(atPath: backupFileURL.path) {
                return try loadSnapshot(from: backupFileURL)
            }
            return StickyNotesSnapshot()
        }

        do {
            return try loadSnapshot(from: fileURL)
        } catch {
            let primaryError = error
            let quarantinedPrimaryURL = try? quarantineCorruptFile(at: fileURL)

            guard FileManager.default.fileExists(atPath: backupFileURL.path) else {
                throw StickyNotesFileStoreError.unrecoverableSnapshot(
                    primaryError: primaryError,
                    backupError: nil,
                    quarantinedPrimaryURL: quarantinedPrimaryURL
                )
            }

            do {
                return try loadSnapshot(from: backupFileURL)
            } catch {
                throw StickyNotesFileStoreError.unrecoverableSnapshot(
                    primaryError: primaryError,
                    backupError: error,
                    quarantinedPrimaryURL: quarantinedPrimaryURL
                )
            }
        }
    }

    func save(_ snapshot: StickyNotesSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try data.write(to: backupFileURL, options: .atomic)
    }

    func save(_ snapshot: StickyNotesSnapshot, generation: Int) throws {
        // Snapshot saves are dispatched asynchronously, so a stale write can arrive late.
        guard generation >= latestGeneratedSave else { return }
        latestGeneratedSave = generation
        try save(snapshot)
    }

    private func loadSnapshot(from fileURL: URL) throws -> StickyNotesSnapshot {
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(StickyNotesSnapshot.self, from: data)
    }

    private func quarantineCorruptFile(at fileURL: URL) throws -> URL {
        let quarantineURL = quarantineURL(for: fileURL)
        try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
        return quarantineURL
    }

    private func quarantineURL(for fileURL: URL) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let candidateURL = URL(fileURLWithPath: "\(fileURL.path).corrupt-\(timestamp)")

        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return candidateURL
        }

        return URL(fileURLWithPath: "\(candidateURL.path)-\(UUID().uuidString)")
    }

    nonisolated static func defaultFileURL(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.mushpot.iStickies"
    ) -> URL {
        let baseURL =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return baseURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("sticky-notes.json", isDirectory: false)
    }
}

enum StickyNotesFileStoreError: LocalizedError {
    case unrecoverableSnapshot(
        primaryError: Error,
        backupError: Error?,
        quarantinedPrimaryURL: URL?
    )

    var errorDescription: String? {
        switch self {
        case let .unrecoverableSnapshot(primaryError, backupError, _):
            if let backupError {
                return "The local notes file and its backup could not be read. Primary: \(primaryError.localizedDescription) Backup: \(backupError.localizedDescription)"
            }

            return "The local notes file could not be read and no backup was available. \(primaryError.localizedDescription)"
        }
    }
}
