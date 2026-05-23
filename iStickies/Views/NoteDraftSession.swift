import SwiftUI

@MainActor
final class NoteDraftSession: ObservableObject {
    @Published private(set) var draftContent = ""

    private let debounceInterval: Duration
    private let delayedTaskScheduler: any StickyNotesDelayedTaskScheduling
    private var noteID: String?
    private var hasLoadedDraft = false
    private var hasPendingLocalChanges = false
    private var awaitingEditorReplacementContent: String?
    private var draftBaseContent: String?
    private var readPersistedContent: @MainActor () -> String? = { nil }
    private var persistDraftContent: @MainActor (String, String) -> StickyNoteDraftPersistenceResult = { _, _ in .missing }
    private var saveTask: StickyNotesDelayedTask?

    init(
        debounceInterval: Duration = .milliseconds(250),
        delayedTaskScheduler: any StickyNotesDelayedTaskScheduling = StickyNotesLiveDelayedTaskScheduler()
    ) {
        self.debounceInterval = debounceInterval
        self.delayedTaskScheduler = delayedTaskScheduler
    }

    deinit {
        saveTask?.cancel()
    }

    func configure(
        noteID: String,
        initialContent: String,
        force: Bool = false,
        readPersistedContent: @escaping @MainActor () -> String?,
        persistDraftContent: @escaping @MainActor (String, String) -> StickyNoteDraftPersistenceResult
    ) {
        if let existingNoteID = self.noteID, existingNoteID != noteID {
            flush()
            resetState()
        }

        self.noteID = noteID
        self.readPersistedContent = readPersistedContent
        self.persistDraftContent = persistDraftContent
        syncDraft(with: initialContent, force: force || !hasLoadedDraft)
    }

    func handlePersistedContentChange(_ newValue: String) {
        if newValue == draftContent {
            guard awaitingEditorReplacementContent == nil else { return }
            hasPendingLocalChanges = false
            draftBaseContent = newValue
            return
        }

        if let awaitingEditorReplacementContent {
            guard draftContent == awaitingEditorReplacementContent else { return }
            draftContent = newValue
            self.awaitingEditorReplacementContent = newValue
            hasLoadedDraft = true
            return
        }

        guard !hasPendingLocalChanges else { return }
        draftContent = newValue
        draftBaseContent = newValue
        hasLoadedDraft = true
        awaitingEditorReplacementContent = nil
    }

    func updateDraftContent(_ newValue: String) {
        guard !markDraftCleanIfPersistedContentMatches(newValue) else { return }
        guard draftContent != newValue else {
            return
        }
        draftContent = newValue
        schedulePersistence()
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persistDraftIfNeeded(draftContent)
    }

    private func syncDraft(with content: String, force: Bool) {
        guard force || !hasLoadedDraft else { return }
        draftContent = content
        draftBaseContent = content
        hasLoadedDraft = true
        hasPendingLocalChanges = false
        awaitingEditorReplacementContent = nil
    }

    private func schedulePersistence() {
        let persistedContent = readPersistedContent()
        if !hasPendingLocalChanges {
            draftBaseContent = persistedContent ?? draftBaseContent
        }
        hasPendingLocalChanges = persistedContent != draftContent
        saveTask?.cancel()
        saveTask = delayedTaskScheduler.schedule(after: debounceInterval) { [weak self] in
            guard let self else { return }
            self.saveTask = nil
            self.persistDraftIfNeeded(self.draftContent)
        }
    }

    private func persistDraftIfNeeded(_ content: String) {
        guard let persistedContent = readPersistedContent() else {
            hasPendingLocalChanges = false
            awaitingEditorReplacementContent = nil
            draftBaseContent = nil
            return
        }

        guard persistedContent != content else {
            hasPendingLocalChanges = false
            awaitingEditorReplacementContent = nil
            draftBaseContent = persistedContent
            return
        }

        let expectedBaseContent = draftBaseContent ?? persistedContent
        switch persistDraftContent(content, expectedBaseContent) {
        case let .persisted(primaryContent):
            draftContent = primaryContent
            draftBaseContent = primaryContent
            hasPendingLocalChanges = false
            awaitingEditorReplacementContent = nil
        case let .conflicted(primaryContent, _):
            draftContent = primaryContent
            draftBaseContent = expectedBaseContent
            hasPendingLocalChanges = content != primaryContent
            awaitingEditorReplacementContent = hasPendingLocalChanges ? primaryContent : nil
        case .missing:
            hasPendingLocalChanges = false
            awaitingEditorReplacementContent = nil
        }
    }

    @discardableResult
    private func markDraftCleanIfPersistedContentMatches(_ content: String) -> Bool {
        guard hasPendingLocalChanges else { return false }
        guard readPersistedContent() == content else { return false }
        saveTask?.cancel()
        saveTask = nil
        if awaitingEditorReplacementContent != nil, draftContent != content {
            persistDraftIfNeeded(draftContent)
            guard readPersistedContent() == content else { return false }
        }
        draftContent = content
        hasPendingLocalChanges = false
        awaitingEditorReplacementContent = nil
        draftBaseContent = content
        return true
    }

    private func resetState() {
        saveTask?.cancel()
        saveTask = nil
        hasLoadedDraft = false
        hasPendingLocalChanges = false
        awaitingEditorReplacementContent = nil
        draftBaseContent = nil
        draftContent = ""
    }
}
