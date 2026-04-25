import SwiftUI

@MainActor
final class NoteDraftSession: ObservableObject {
    @Published private(set) var draftContent = ""

    private let debounceInterval: Duration
    private var noteID: String?
    private var hasLoadedDraft = false
    private var hasPendingLocalChanges = false
    private var isAwaitingEditorContentReplacement = false
    private var draftBaseContent: String?
    private var readPersistedContent: @MainActor () -> String? = { nil }
    private var persistDraftContent: @MainActor (String, String) -> StickyNoteDraftPersistenceResult = { _, _ in .missing }
    private var saveTask: Task<Void, Never>?

    init(debounceInterval: Duration = .milliseconds(250)) {
        self.debounceInterval = debounceInterval
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
            guard !isAwaitingEditorContentReplacement else { return }
            hasPendingLocalChanges = false
            draftBaseContent = newValue
            return
        }

        if isAwaitingEditorContentReplacement {
            draftContent = newValue
            hasLoadedDraft = true
            return
        }

        guard !hasPendingLocalChanges else { return }
        draftContent = newValue
        draftBaseContent = newValue
        hasLoadedDraft = true
        isAwaitingEditorContentReplacement = false
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
        isAwaitingEditorContentReplacement = false
    }

    private func schedulePersistence() {
        let persistedContent = readPersistedContent()
        if !hasPendingLocalChanges {
            draftBaseContent = persistedContent ?? draftBaseContent
        }
        hasPendingLocalChanges = persistedContent != draftContent
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            self.persistDraftIfNeeded(self.draftContent)
        }
    }

    private func persistDraftIfNeeded(_ content: String) {
        guard let persistedContent = readPersistedContent() else {
            hasPendingLocalChanges = false
            isAwaitingEditorContentReplacement = false
            draftBaseContent = nil
            return
        }

        guard persistedContent != content else {
            hasPendingLocalChanges = false
            isAwaitingEditorContentReplacement = false
            draftBaseContent = persistedContent
            return
        }

        let expectedBaseContent = draftBaseContent ?? persistedContent
        switch persistDraftContent(content, expectedBaseContent) {
        case let .persisted(primaryContent):
            draftContent = primaryContent
            draftBaseContent = primaryContent
            hasPendingLocalChanges = false
            isAwaitingEditorContentReplacement = false
        case let .conflicted(primaryContent, _):
            draftContent = primaryContent
            draftBaseContent = expectedBaseContent
            hasPendingLocalChanges = content != primaryContent
            isAwaitingEditorContentReplacement = hasPendingLocalChanges
        case .missing:
            hasPendingLocalChanges = false
            isAwaitingEditorContentReplacement = false
        }
    }

    @discardableResult
    private func markDraftCleanIfPersistedContentMatches(_ content: String) -> Bool {
        guard hasPendingLocalChanges else { return false }
        guard readPersistedContent() == content else { return false }
        saveTask?.cancel()
        saveTask = nil
        draftContent = content
        hasPendingLocalChanges = false
        isAwaitingEditorContentReplacement = false
        draftBaseContent = content
        return true
    }

    private func resetState() {
        saveTask?.cancel()
        saveTask = nil
        hasLoadedDraft = false
        hasPendingLocalChanges = false
        isAwaitingEditorContentReplacement = false
        draftBaseContent = nil
        draftContent = ""
    }
}
