import CloudKit
import Foundation

enum CloudKitRecordSaveFailureKind: Equatable {
    case missingZone
    case conflict
    case unknownItemRetry
    /// The server refused the record itself (for example a field that is missing from the
    /// deployed schema or a violated record constraint). Resending the same payload cannot
    /// succeed, so it must be dropped from the automatic queue instead of retried forever.
    case permanentlyRejected
    /// CKSyncEngine or a later external sync trigger can retry this failure without changing the
    /// record payload or app/account configuration.
    case retryable
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

struct CloudKitPermanentlyRejectedSaveFailure: Equatable {
    var noteID: String
    var message: String
}

struct CloudKitPartialRecordSaveFailureClassification: Equatable {
    var unknownItemRetryNoteIDs: [String]
    var permanentlyRejectedSaveFailures: [CloudKitPermanentlyRejectedSaveFailure]
    var serverResponseLostNoteIDs: [String]
    var unhandledSaveFailureNoteIDs: [String]
    var hasUnattributedFailures: Bool

    var hasUnhandledFailures: Bool {
        hasUnattributedFailures
            || !serverResponseLostNoteIDs.isEmpty
            || !unhandledSaveFailureNoteIDs.isEmpty
    }
}

enum CloudKitErrorClassifier {
    static func isMissingZone(_ error: Error) -> Bool {
        guard let ckError = cloudKitError(from: error) else { return false }
        return isMissingZone(ckError)
    }

    static func isServerResponseLost(_ error: Error) -> Bool {
        cloudKitError(from: error)?.code == .serverResponseLost
    }

    static func classifyRecordSaveFailure(_ error: Error) -> CloudKitRecordSaveFailureClassification {
        let message = error.localizedDescription
        guard let ckError = cloudKitError(from: error) else {
            return CloudKitRecordSaveFailureClassification(
                kind: .retryable,
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
        case .partialFailure,
             .networkUnavailable,
             .networkFailure,
             .serviceUnavailable,
             .requestRateLimited,
             .notAuthenticated,
             .operationCancelled,
             .batchRequestFailed,
             .serverResponseLost,
             .zoneBusy,
             .accountTemporarilyUnavailable:
            return CloudKitRecordSaveFailureClassification(
                kind: .retryable,
                serverRecord: nil,
                message: message
            )
        default:
            return CloudKitRecordSaveFailureClassification(
                kind: .permanentlyRejected,
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
        guard let classification = classifyPartialRecordSaveFailures(
            error,
            targetZoneID: targetZoneID,
            pendingSaveNoteIDs: pendingSaveNoteIDs
        ), !classification.unknownItemRetryNoteIDs.isEmpty
        else {
            return .unhandled
        }

        return classification.hasUnhandledFailures
            || !classification.permanentlyRejectedSaveFailures.isEmpty
            ? .partiallyRecoverableUnknownItemSaves(
                noteIDs: classification.unknownItemRetryNoteIDs
            )
            : .recoverableUnknownItemSaves(noteIDs: classification.unknownItemRetryNoteIDs)
    }

    static func classifyPartialRecordSaveFailures(
        _ error: Error,
        targetZoneID: CKRecordZone.ID,
        pendingSaveNoteIDs: Set<String>
    ) -> CloudKitPartialRecordSaveFailureClassification? {
        guard let partialErrors = partialItemErrors(from: error), !partialErrors.isEmpty else {
            return nil
        }

        var unknownItemRetryNoteIDs: Set<String> = []
        var permanentlyRejectedSaveFailures: [CloudKitPermanentlyRejectedSaveFailure] = []
        var serverResponseLostNoteIDs: Set<String> = []
        var unhandledSaveFailureNoteIDs: Set<String> = []
        var hasUnattributedFailures = false

        for (itemID, itemError) in partialErrors {
            guard let recordID = itemID as? CKRecord.ID,
                  recordID.zoneID == targetZoneID,
                  pendingSaveNoteIDs.contains(recordID.recordName)
            else {
                hasUnattributedFailures = true
                continue
            }

            let classification = classifyRecordSaveFailure(itemError)
            switch classification.kind {
            case .unknownItemRetry:
                unknownItemRetryNoteIDs.insert(recordID.recordName)
            case .permanentlyRejected:
                permanentlyRejectedSaveFailures.append(
                    CloudKitPermanentlyRejectedSaveFailure(
                        noteID: recordID.recordName,
                        message: classification.message
                    )
                )
            case .retryable where isServerResponseLost(itemError):
                serverResponseLostNoteIDs.insert(recordID.recordName)
            case .missingZone, .conflict, .retryable:
                unhandledSaveFailureNoteIDs.insert(recordID.recordName)
            }
        }

        return CloudKitPartialRecordSaveFailureClassification(
            unknownItemRetryNoteIDs: unknownItemRetryNoteIDs.sorted(),
            permanentlyRejectedSaveFailures: permanentlyRejectedSaveFailures.sorted {
                $0.noteID < $1.noteID
            },
            serverResponseLostNoteIDs: serverResponseLostNoteIDs.sorted(),
            unhandledSaveFailureNoteIDs: unhandledSaveFailureNoteIDs.sorted(),
            hasUnattributedFailures: hasUnattributedFailures
        )
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
