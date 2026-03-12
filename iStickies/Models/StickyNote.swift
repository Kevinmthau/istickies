import Foundation

struct StickyNoteFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct StickyNote: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var content: String
    var titleOverride: String?
    var color: StickyNoteColor
    var createdAt: Date
    var lastModified: Date
    var isOpen: Bool
    var preferredFrame: StickyNoteFrame?
    var needsCloudUpload: Bool
    var cloudKitSystemFieldsData: Data?

    init(
        id: String = UUID().uuidString,
        content: String = "",
        titleOverride: String? = nil,
        color: StickyNoteColor = .yellow,
        createdAt: Date = Date(),
        lastModified: Date = Date(),
        isOpen: Bool = true,
        preferredFrame: StickyNoteFrame? = nil,
        needsCloudUpload: Bool = true,
        cloudKitSystemFieldsData: Data? = nil
    ) {
        self.id = id
        self.content = content
        self.titleOverride = titleOverride
        self.color = color
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.isOpen = isOpen
        self.preferredFrame = preferredFrame
        self.needsCloudUpload = needsCloudUpload
        self.cloudKitSystemFieldsData = cloudKitSystemFieldsData
    }

    var title: String {
        if let titleOverride, !titleOverride.isEmpty {
            return titleOverride
        }

        let firstMeaningfulLine = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })

        return firstMeaningfulLine?.prefix(36).description ?? "Untitled Note"
    }

    var summary: String {
        let collapsed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if collapsed.isEmpty {
            return "Empty note"
        }

        return String(collapsed.prefix(80))
    }

    func markedClean() -> StickyNote {
        var copy = self
        copy.needsCloudUpload = false
        return copy
    }

    func resettingCloudKitSystemFields() -> StickyNote {
        var copy = self
        copy.needsCloudUpload = true
        copy.cloudKitSystemFieldsData = nil
        return copy
    }
}

struct StickyNotesSnapshot: Codable, Sendable {
    var notes: [StickyNote] = []
    var pendingDeletionIDs: [String] = []
    var lastSuccessfulCloudSync: Date?
    var cloudKitStateSerializationData: Data?
}
