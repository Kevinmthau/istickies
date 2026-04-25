import CloudKit
import Foundation

struct StickyNoteRecordMappingResult: Sendable {
    var notesByID: [String: StickyNote]
    var issueMessages: [String]
}

enum StickyNoteRecordMapper {
    static let recordType = "StickyNote"
    static let lastModifiedSortKey = StickyNoteRecordField.lastModified

    static func map(
        records: [CKRecord],
        expectedZoneID: CKRecordZone.ID?
    ) -> StickyNoteRecordMappingResult {
        var notesByID: [String: StickyNote] = [:]
        var skippedRecordCount = 0

        for record in records {
            if let expectedZoneID, record.recordID.zoneID != expectedZoneID {
                continue
            }

            guard record.recordType == recordType else {
                continue
            }

            guard let note = note(from: record) else {
                skippedRecordCount += 1
                continue
            }

            notesByID[note.id] = note.markedClean()
        }

        let issueMessages = skippedRecordCount == 0
            ? []
            : ["\(skippedRecordCount) CloudKit record(s) could not be decoded."]
        return StickyNoteRecordMappingResult(notesByID: notesByID, issueMessages: issueMessages)
    }

    static func note(from record: CKRecord) -> StickyNote? {
        guard record.recordType == recordType,
              let content = record[StickyNoteRecordField.content] as? String,
              let lastModified = record[StickyNoteRecordField.lastModified] as? Date
        else {
            return nil
        }

        let createdAt =
            (record[StickyNoteRecordField.createdAt] as? Date)
            ?? record.creationDate
            ?? lastModified

        let color: StickyNoteColor
        if let colorRawValue = record[StickyNoteRecordField.color] as? String,
           let decodedColor = StickyNoteColor(rawValue: colorRawValue)
        {
            color = decodedColor
        } else {
            color = .yellow
        }

        return StickyNote(
            id: record.recordID.recordName,
            content: content,
            titleOverride: record[StickyNoteRecordField.titleOverride] as? String,
            color: color,
            createdAt: createdAt,
            lastModified: lastModified,
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: record.encodedSystemFieldsData()
        )
    }

    static func record(for note: StickyNote, zoneID: CKRecordZone.ID) -> CKRecord {
        let expectedRecordID = CKRecord.ID(recordName: note.id, zoneID: zoneID)
        let record =
            restoredRecord(from: note.cloudKitSystemFieldsData, expectedRecordID: expectedRecordID)
            ?? CKRecord(recordType: recordType, recordID: expectedRecordID)

        write(note, to: record)
        return record
    }

    static func write(_ note: StickyNote, to record: CKRecord) {
        record[StickyNoteRecordField.content] = note.content as CKRecordValue
        if let titleOverride = note.titleOverride, !titleOverride.isEmpty {
            record[StickyNoteRecordField.titleOverride] = titleOverride as CKRecordValue
        } else {
            record[StickyNoteRecordField.titleOverride] = nil
        }

        // Keep writes compatible with the deployed production schema. Shared CloudKit records
        // only store note content metadata; window visibility and frame are local device state.
        record[StickyNoteRecordField.color] = nil
        record[StickyNoteRecordField.createdAt] = nil
        record[StickyNoteRecordField.lastModified] = note.lastModified as CKRecordValue
        record[StickyNoteRecordField.isOpen] = nil
        record[StickyNoteRecordField.frameX] = nil
        record[StickyNoteRecordField.frameY] = nil
        record[StickyNoteRecordField.frameWidth] = nil
        record[StickyNoteRecordField.frameHeight] = nil
    }

    private static func restoredRecord(
        from cloudKitSystemFieldsData: Data?,
        expectedRecordID: CKRecord.ID
    ) -> CKRecord? {
        guard let cloudKitSystemFieldsData else { return nil }

        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: cloudKitSystemFieldsData)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }

            guard let record = CKRecord(coder: unarchiver),
                  record.recordID == expectedRecordID,
                  record.recordType == recordType
            else {
                return nil
            }

            return record
        } catch {
            return nil
        }
    }
}

extension StickyNote {
    static let recordType = StickyNoteRecordMapper.recordType

    init?(record: CKRecord) {
        guard let note = StickyNoteRecordMapper.note(from: record) else {
            return nil
        }

        self = note
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        StickyNoteRecordMapper.record(for: self, zoneID: zoneID)
    }

    func write(to record: CKRecord) {
        StickyNoteRecordMapper.write(self, to: record)
    }
}

private enum StickyNoteRecordField {
    static let content = "content"
    static let titleOverride = "titleOverride"
    static let color = "color"
    static let createdAt = "createdAt"
    static let lastModified = "lastModified"
    static let isOpen = "isOpen"
    static let frameX = "frameX"
    static let frameY = "frameY"
    static let frameWidth = "frameWidth"
    static let frameHeight = "frameHeight"
}

private extension CKRecord {
    func encodedSystemFieldsData() -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
