import Foundation

struct StickyNoteFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum StickyNoteCloudUploadBlock: String, Codable, Equatable, Sendable {
    case permanentlyRejected
}

struct CloudSaveVerification: Codable, Equatable, Sendable {
    var noteID: String
    var content: String
    var lastModified: Date

    init(note: StickyNote) {
        noteID = note.id
        content = note.content
        lastModified = StickyNoteCloudTimestamp.canonicalized(note.lastModified)
    }

    func matches(_ note: StickyNote) -> Bool {
        content == note.content
            && StickyNoteCloudTimestamp.representsSameInstant(lastModified, note.lastModified)
    }
}

enum StickyNoteCloudTimestamp {
    // CloudKit represents Date/Time fields as milliseconds since the Unix epoch. A server
    // round trip can therefore remove sub-millisecond precision from a Swift Date.
    private static let maximumRoundTripDelta: TimeInterval = 0.001

    static func canonicalized(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    static func representsSameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < maximumRoundTripDelta
    }
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
    var cloudUploadBlock: StickyNoteCloudUploadBlock?
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
        cloudUploadBlock: StickyNoteCloudUploadBlock? = nil,
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
        self.cloudUploadBlock = cloudUploadBlock
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

    var shouldAttemptCloudUpload: Bool {
        needsCloudUpload && cloudUploadBlock == nil
    }

    func markedClean() -> StickyNote {
        var copy = self
        copy.needsCloudUpload = false
        copy.cloudUploadBlock = nil
        return copy
    }

    func resettingCloudKitSystemFields() -> StickyNote {
        var copy = self
        copy.needsCloudUpload = true
        copy.cloudKitSystemFieldsData = nil
        copy.cloudRevision = nil
        return copy
    }

    static func enforcingYellow(_ notes: [StickyNote]) -> [StickyNote] {
        notes.map { note in
            guard note.color != .yellow else { return note }

            var copy = note
            copy.color = .yellow
            copy.needsCloudUpload = true
            return copy
        }
    }
}

enum StickyNoteOrdering {
    static func areInIncreasingOrder(_ lhs: StickyNote, _ rhs: StickyNote) -> Bool {
        if lhs.lastModified != rhs.lastModified {
            return lhs.lastModified > rhs.lastModified
        }

        return lhs.createdAt > rhs.createdAt
    }
}

struct StickyNotesSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int = Self.currentSchemaVersion
    var notes: [StickyNote] = []
    var pendingDeletionIDs: [String] = []
    var lastSuccessfulCloudSync: Date?
    var cloudKitStateSerializationData: Data?
    var cloudAccountIdentifier: String?
    var cloudRemoteCache: [StickyNote] = []
    var cloudSaveVerifications: [CloudSaveVerification] = []

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        notes: [StickyNote] = [],
        pendingDeletionIDs: [String] = [],
        lastSuccessfulCloudSync: Date? = nil,
        cloudKitStateSerializationData: Data? = nil,
        cloudAccountIdentifier: String? = nil,
        cloudRemoteCache: [StickyNote] = [],
        cloudSaveVerifications: [CloudSaveVerification] = []
    ) {
        self.schemaVersion = schemaVersion
        self.notes = notes
        self.pendingDeletionIDs = pendingDeletionIDs
        self.lastSuccessfulCloudSync = lastSuccessfulCloudSync
        self.cloudKitStateSerializationData = cloudKitStateSerializationData
        self.cloudAccountIdentifier = cloudAccountIdentifier
        self.cloudRemoteCache = cloudRemoteCache
        self.cloudSaveVerifications = cloudSaveVerifications
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
        cloudSaveVerifications = try container.decodeIfPresent(
            [CloudSaveVerification].self,
            forKey: .cloudSaveVerifications
        ) ?? []
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
        try container.encode(
            cloudSaveVerifications,
            forKey: .cloudSaveVerifications
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case notes
        case pendingDeletionIDs
        case lastSuccessfulCloudSync
        case cloudKitStateSerializationData
        case cloudAccountIdentifier
        case cloudRemoteCache
        case cloudSaveVerifications
    }
}

struct StickyNotesCloudPersistedState: Codable, Equatable, Sendable {
    var stateSerializationData: Data?
    var accountIdentifier: String?
    var remoteNotes: [StickyNote]
    var saveVerifications: [CloudSaveVerification]

    init(
        stateSerializationData: Data? = nil,
        accountIdentifier: String? = nil,
        remoteNotes: [StickyNote] = [],
        saveVerifications: [CloudSaveVerification] = []
    ) {
        self.stateSerializationData = stateSerializationData
        self.accountIdentifier = accountIdentifier
        self.remoteNotes = remoteNotes
        self.saveVerifications = saveVerifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stateSerializationData = try container.decodeIfPresent(
            Data.self,
            forKey: .stateSerializationData
        )
        accountIdentifier = try container.decodeIfPresent(String.self, forKey: .accountIdentifier)
        remoteNotes = try container.decodeIfPresent([StickyNote].self, forKey: .remoteNotes) ?? []
        saveVerifications = try container.decodeIfPresent(
            [CloudSaveVerification].self,
            forKey: .saveVerifications
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(stateSerializationData, forKey: .stateSerializationData)
        try container.encodeIfPresent(accountIdentifier, forKey: .accountIdentifier)
        try container.encode(remoteNotes, forKey: .remoteNotes)
        try container.encode(
            saveVerifications,
            forKey: .saveVerifications
        )
    }

    private enum CodingKeys: String, CodingKey {
        case stateSerializationData
        case accountIdentifier
        case remoteNotes
        case saveVerifications
    }
}
