import CloudKit
import Foundation

enum CloudKitRecordSaveFailureKind: Equatable {
    case missingZone
    case conflict
    case unknownItemRetry
    case terminal
}

struct CloudKitRecordSaveFailureClassification {
    var kind: CloudKitRecordSaveFailureKind
    var serverRecord: CKRecord?
    var message: String
}

enum CloudKitRecordDeleteFailureKind: Equatable {
    case alreadyDeleted
    case missingZone
    case terminal
}

struct CloudKitRecordDeleteFailureClassification {
    var kind: CloudKitRecordDeleteFailureKind
    var message: String
}

enum CloudKitRetriableSavePartialFailureClassification: Equatable {
    case recoverableUnknownItemSaves(noteIDs: [String])
    case partiallyRecoverableUnknownItemSaves(noteIDs: [String])
    case unhandled
}

enum CloudKitErrorClassifier {
    static func isMissingZone(_ error: Error) -> Bool {
        guard let ckError = cloudKitError(from: error) else { return false }
        return isMissingZone(ckError)
    }

    static func classifyRecordSaveFailure(_ error: Error) -> CloudKitRecordSaveFailureClassification {
        let message = error.localizedDescription
        guard let ckError = cloudKitError(from: error) else {
            return CloudKitRecordSaveFailureClassification(
                kind: .terminal,
                serverRecord: nil,
                message: message
            )
        }

        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return CloudKitRecordSaveFailureClassification(
                kind: .missingZone,
                serverRecord: nil,
                message: message
            )
        case .serverRecordChanged:
            return CloudKitRecordSaveFailureClassification(
                kind: .conflict,
                serverRecord: ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                message: message
            )
        case .unknownItem:
            return CloudKitRecordSaveFailureClassification(
                kind: .unknownItemRetry,
                serverRecord: nil,
                message: message
            )
        default:
            return CloudKitRecordSaveFailureClassification(
                kind: .terminal,
                serverRecord: nil,
                message: message
            )
        }
    }

    static func classifyRecordDeleteFailure(_ error: Error) -> CloudKitRecordDeleteFailureClassification {
        let message = error.localizedDescription
        guard let ckError = cloudKitError(from: error) else {
            return CloudKitRecordDeleteFailureClassification(kind: .terminal, message: message)
        }

        switch ckError.code {
        case .unknownItem:
            return CloudKitRecordDeleteFailureClassification(kind: .alreadyDeleted, message: message)
        case .zoneNotFound, .userDeletedZone:
            return CloudKitRecordDeleteFailureClassification(kind: .missingZone, message: message)
        default:
            return CloudKitRecordDeleteFailureClassification(kind: .terminal, message: message)
        }
    }

    static func classifyRetriableSavePartialFailure(
        _ error: Error,
        targetZoneID: CKRecordZone.ID,
        pendingSaveNoteIDs: Set<String>
    ) -> CloudKitRetriableSavePartialFailureClassification {
        guard let partialErrors = partialItemErrors(from: error), !partialErrors.isEmpty else {
            return .unhandled
        }

        var retriableNoteIDs: Set<String> = []
        var encounteredUnhandledError = false

        for (itemID, itemError) in partialErrors {
            guard let recordID = itemID as? CKRecord.ID,
                  recordID.zoneID == targetZoneID,
                  pendingSaveNoteIDs.contains(recordID.recordName),
                  cloudKitError(from: itemError)?.code == .unknownItem
            else {
                encounteredUnhandledError = true
                continue
            }

            retriableNoteIDs.insert(recordID.recordName)
        }

        guard !retriableNoteIDs.isEmpty else {
            return .unhandled
        }

        let noteIDs = retriableNoteIDs.sorted()
        return encounteredUnhandledError
            ? .partiallyRecoverableUnknownItemSaves(noteIDs: noteIDs)
            : .recoverableUnknownItemSaves(noteIDs: noteIDs)
    }

    private static func isMissingZone(_ error: CKError) -> Bool {
        error.code == .zoneNotFound || error.code == .userDeletedZone
    }

    private static func cloudKitError(from error: Error) -> CKError? {
        if let ckError = error as? CKError {
            return ckError
        }

        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else {
            return nil
        }

        return CKError(_nsError: nsError)
    }

    private static func partialItemErrors(from error: Error) -> [AnyHashable: Error]? {
        let nsError = error as NSError
        let rawPartialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey]

        if let partialErrors = rawPartialErrors as? [AnyHashable: Error] {
            return partialErrors
        }

        guard let partialErrors = rawPartialErrors as? [AnyHashable: Any] else {
            return nil
        }

        var typedPartialErrors: [AnyHashable: Error] = [:]
        for (itemID, itemError) in partialErrors {
            guard let itemError = itemError as? Error else {
                return nil
            }

            typedPartialErrors[itemID] = itemError
        }

        return typedPartialErrors
    }
}
