import CloudKit
import Foundation

enum CloudKitRecordSaveFailureKind: Equatable {
    case missingZone
    case conflict
    case unknownItemRetry
    case batchRequestFailed
    case limitExceeded
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

struct CloudKitAttributedSaveFailure: Equatable {
    var noteID: String
    var message: String
}

struct CloudKitConflictSaveFailure {
    var noteID: String
    var serverRecord: CKRecord?
    var message: String
}

struct CloudKitPartialRecordSaveFailureClassification {
    var unknownItemRetryNoteIDs: [String]
    var permanentlyRejectedSaveFailures: [CloudKitAttributedSaveFailure]
    var conflictSaveFailures: [CloudKitConflictSaveFailure]
    var limitExceededSaveFailures: [CloudKitAttributedSaveFailure]
    var batchRequestFailedSaveFailures: [CloudKitAttributedSaveFailure]
    var serverResponseLostNoteIDs: [String]
    var missingZoneSaveNoteIDs: [String]
    var unhandledSaveFailureNoteIDs: [String]
    var hasUnattributedFailures: Bool

    var canRetryBatchDependents: Bool {
        !batchRequestFailedSaveFailures.isEmpty
            && (!unknownItemRetryNoteIDs.isEmpty
                || !permanentlyRejectedSaveFailures.isEmpty
                || !conflictSaveFailures.isEmpty)
            && limitExceededSaveFailures.isEmpty
            && serverResponseLostNoteIDs.isEmpty
            && missingZoneSaveNoteIDs.isEmpty
            && unhandledSaveFailureNoteIDs.isEmpty
            && !hasUnattributedFailures
    }

    var limitExceededRetrySaveFailures: [CloudKitAttributedSaveFailure] {
        guard !limitExceededSaveFailures.isEmpty else { return [] }

        var failuresByNoteID = Dictionary(
            limitExceededSaveFailures.map { ($0.noteID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for failure in batchRequestFailedSaveFailures {
            failuresByNoteID[failure.noteID] = failure
        }
        return failuresByNoteID.values.sorted { $0.noteID < $1.noteID }
    }

    var hasUnhandledFailures: Bool {
        hasUnattributedFailures
            || !conflictSaveFailures.isEmpty
            || !limitExceededSaveFailures.isEmpty
            || !batchRequestFailedSaveFailures.isEmpty
            || !serverResponseLostNoteIDs.isEmpty
            || !missingZoneSaveNoteIDs.isEmpty
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

    static func isLimitExceeded(_ error: Error) -> Bool {
        cloudKitError(from: error)?.code == .limitExceeded
    }

    static func classifyRecordSaveFailure(_ error: Error) -> CloudKitRecordSaveFailureClassification {
        let message = error.localizedDescription
        if error is CancellationError {
            return CloudKitRecordSaveFailureClassification(
                kind: .retryable,
                serverRecord: nil,
                message: message
            )
        }
        guard let ckError = cloudKitError(from: error) else {
            return CloudKitRecordSaveFailureClassification(
                kind: .permanentlyRejected,
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
        case .batchRequestFailed:
            return CloudKitRecordSaveFailureClassification(
                kind: .batchRequestFailed,
                serverRecord: nil,
                message: message
            )
        case .limitExceeded:
            return CloudKitRecordSaveFailureClassification(
                kind: .limitExceeded,
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

        var attributedFailures: [(recordID: CKRecord.ID, error: Error)] = []
        var hasUnattributedFailures = false
        for (itemID, itemError) in partialErrors {
            guard let recordID = itemID as? CKRecord.ID else {
                hasUnattributedFailures = true
                continue
            }
            attributedFailures.append((recordID, itemError))
        }

        return classifyRecordSaveFailures(
            attributedFailures,
            targetZoneID: targetZoneID,
            pendingSaveNoteIDs: pendingSaveNoteIDs,
            hasUnattributedFailures: hasUnattributedFailures
        )
    }

    static func classifyRecordSaveFailures(
        _ failures: [(recordID: CKRecord.ID, error: Error)],
        targetZoneID: CKRecordZone.ID,
        pendingSaveNoteIDs: Set<String>,
        hasUnattributedFailures initialHasUnattributedFailures: Bool = false
    ) -> CloudKitPartialRecordSaveFailureClassification {

        var unknownItemRetryNoteIDs: Set<String> = []
        var permanentlyRejectedSaveFailures: [CloudKitAttributedSaveFailure] = []
        var conflictSaveFailures: [CloudKitConflictSaveFailure] = []
        var limitExceededSaveFailures: [CloudKitAttributedSaveFailure] = []
        var batchRequestFailedSaveFailures: [CloudKitAttributedSaveFailure] = []
        var serverResponseLostNoteIDs: Set<String> = []
        var missingZoneSaveNoteIDs: Set<String> = []
        var unhandledSaveFailureNoteIDs: Set<String> = []
        var hasUnattributedFailures = initialHasUnattributedFailures

        for failure in failures {
            let recordID = failure.recordID
            let itemError = failure.error
            guard recordID.zoneID == targetZoneID,
                  pendingSaveNoteIDs.contains(recordID.recordName)
            else {
                hasUnattributedFailures = true
                continue
            }

            let classification = classifyRecordSaveFailure(itemError)
            switch classification.kind {
            case .unknownItemRetry:
                unknownItemRetryNoteIDs.insert(recordID.recordName)
            case .conflict:
                conflictSaveFailures.append(
                    CloudKitConflictSaveFailure(
                        noteID: recordID.recordName,
                        serverRecord: classification.serverRecord,
                        message: classification.message
                    )
                )
            case .permanentlyRejected:
                permanentlyRejectedSaveFailures.append(
                    CloudKitAttributedSaveFailure(
                        noteID: recordID.recordName,
                        message: classification.message
                    )
                )
            case .limitExceeded:
                limitExceededSaveFailures.append(
                    CloudKitAttributedSaveFailure(
                        noteID: recordID.recordName,
                        message: classification.message
                    )
                )
            case .batchRequestFailed:
                batchRequestFailedSaveFailures.append(
                    CloudKitAttributedSaveFailure(
                        noteID: recordID.recordName,
                        message: classification.message
                    )
                )
            case .retryable where isServerResponseLost(itemError):
                serverResponseLostNoteIDs.insert(recordID.recordName)
            case .missingZone:
                missingZoneSaveNoteIDs.insert(recordID.recordName)
            case .retryable:
                unhandledSaveFailureNoteIDs.insert(recordID.recordName)
            }
        }

        return CloudKitPartialRecordSaveFailureClassification(
            unknownItemRetryNoteIDs: unknownItemRetryNoteIDs.sorted(),
            permanentlyRejectedSaveFailures: permanentlyRejectedSaveFailures.sorted {
                $0.noteID < $1.noteID
            },
            conflictSaveFailures: conflictSaveFailures.sorted { $0.noteID < $1.noteID },
            limitExceededSaveFailures: limitExceededSaveFailures.sorted {
                $0.noteID < $1.noteID
            },
            batchRequestFailedSaveFailures: batchRequestFailedSaveFailures.sorted {
                $0.noteID < $1.noteID
            },
            serverResponseLostNoteIDs: serverResponseLostNoteIDs.sorted(),
            missingZoneSaveNoteIDs: missingZoneSaveNoteIDs.sorted(),
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
