import Foundation

actor StickyNotesFileStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var latestGeneratedSave = 0

    init(fileURL: URL = StickyNotesFileStore.defaultFileURL()) {
        self.fileURL = fileURL

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
            return StickyNotesSnapshot()
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(StickyNotesSnapshot.self, from: data)
    }

    func save(_ snapshot: StickyNotesSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    func save(_ snapshot: StickyNotesSnapshot, generation: Int) throws {
        // Snapshot saves are dispatched asynchronously, so a stale write can arrive late.
        guard generation >= latestGeneratedSave else { return }
        latestGeneratedSave = generation
        try save(snapshot)
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
