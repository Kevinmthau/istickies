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
    var cloudRevision: String?

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
        cloudKitSystemFieldsData: Data? = nil,
        cloudRevision: String? = nil
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
        self.cloudRevision = cloudRevision
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
        copy.cloudRevision = nil
        return copy
    }
}

struct StickyNotesSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = Self.currentSchemaVersion
    var notes: [StickyNote] = []
    var pendingDeletionIDs: [String] = []
    var lastSuccessfulCloudSync: Date?
    var cloudKitStateSerializationData: Data?
    var cloudAccountIdentifier: String?
    var cloudRemoteCache: [StickyNote] = []

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        notes: [StickyNote] = [],
        pendingDeletionIDs: [String] = [],
        lastSuccessfulCloudSync: Date? = nil,
        cloudKitStateSerializationData: Data? = nil,
        cloudAccountIdentifier: String? = nil,
        cloudRemoteCache: [StickyNote] = []
    ) {
        self.schemaVersion = schemaVersion
        self.notes = notes
        self.pendingDeletionIDs = pendingDeletionIDs
        self.lastSuccessfulCloudSync = lastSuccessfulCloudSync
        self.cloudKitStateSerializationData = cloudKitStateSerializationData
        self.cloudAccountIdentifier = cloudAccountIdentifier
        self.cloudRemoteCache = cloudRemoteCache
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? 1
        notes = try container.decode([StickyNote].self, forKey: .notes)
        pendingDeletionIDs = try container.decodeIfPresent([String].self, forKey: .pendingDeletionIDs)
            ?? []
        lastSuccessfulCloudSync = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulCloudSync)
        cloudKitStateSerializationData = try container.decodeIfPresent(
            Data.self,
            forKey: .cloudKitStateSerializationData
        )
        cloudAccountIdentifier = try container.decodeIfPresent(String.self, forKey: .cloudAccountIdentifier)
        cloudRemoteCache = try container.decodeIfPresent([StickyNote].self, forKey: .cloudRemoteCache)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(notes, forKey: .notes)
        try container.encode(pendingDeletionIDs, forKey: .pendingDeletionIDs)
        try container.encodeIfPresent(lastSuccessfulCloudSync, forKey: .lastSuccessfulCloudSync)
        try container.encodeIfPresent(cloudKitStateSerializationData, forKey: .cloudKitStateSerializationData)
        try container.encodeIfPresent(cloudAccountIdentifier, forKey: .cloudAccountIdentifier)
        try container.encode(cloudRemoteCache, forKey: .cloudRemoteCache)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case notes
        case pendingDeletionIDs
        case lastSuccessfulCloudSync
        case cloudKitStateSerializationData
        case cloudAccountIdentifier
        case cloudRemoteCache
    }
}

struct StickyNotesCloudPersistedState: Codable, Equatable, Sendable {
    var stateSerializationData: Data?
    var accountIdentifier: String?
    var remoteNotes: [StickyNote]

    init(
        stateSerializationData: Data? = nil,
        accountIdentifier: String? = nil,
        remoteNotes: [StickyNote] = []
    ) {
        self.stateSerializationData = stateSerializationData
        self.accountIdentifier = accountIdentifier
        self.remoteNotes = remoteNotes
    }
}
