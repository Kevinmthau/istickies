import SwiftUI

@MainActor
final class NoteDraftSession: ObservableObject {
    @Published private(set) var draftContent = ""

    private let debounceInterval: Duration
    private var noteID: String?
    private var hasLoadedDraft = false
    private var hasPendingLocalChanges = false
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
            hasPendingLocalChanges = false
            draftBaseContent = newValue
            return
        }

        guard !hasPendingLocalChanges else { return }
        draftContent = newValue
        draftBaseContent = newValue
        hasLoadedDraft = true
    }

    func updateDraftContent(_ newValue: String) {
        guard draftContent != newValue else { return }
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
            draftBaseContent = nil
            return
        }

        guard persistedContent != content else {
            hasPendingLocalChanges = false
            draftBaseContent = persistedContent
            return
        }

        let expectedBaseContent = draftBaseContent ?? persistedContent
        let result = persistDraftContent(content, expectedBaseContent)
        if let primaryContent = result.primaryContent {
            draftContent = primaryContent
            draftBaseContent = primaryContent
        }
        hasPendingLocalChanges = false
    }

    private func resetState() {
        saveTask?.cancel()
        saveTask = nil
        hasLoadedDraft = false
        hasPendingLocalChanges = false
        draftBaseContent = nil
        draftContent = ""
    }
}
