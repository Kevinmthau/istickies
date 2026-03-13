# AGENTS.md

Repo-specific guidance for agents working in `iStickies`.

## Project shape

- `iStickies/Services/StickyNotesStore.swift` is the main state container. It persists snapshots locally and schedules CloudKit sync.
- `iStickies/Platform/macOS/MacStickyNoteWindowCoordinator.swift` owns macOS note windows, focus behavior, and frame synchronization.
- `iStickies/Views/NoteEditorView.swift` contains the shared editor plus the AppKit-backed macOS text view bridge.
- `iStickiesTests/iStickiesTests.swift` contains the key unit tests for store behavior and macOS frame-sync logic.

## macOS pitfalls

- Do not immediately reapply model frames while the user is actively dragging a sticky window.
  The coordinator now suppresses model-driven frame writes for a short interval after a local move and retries deferred frames later. If you change window sync behavior, preserve that suppression or the note can jump backward while being dragged.

- Do not persist a captured stale text snapshot from the macOS editor debounce task.
  `NoteEditorView` must persist the latest `draftContent` when the delayed save fires. Capturing an older string causes typing to appear to overwrite or scramble nearby text.

- Be careful with per-keystroke store writes.
  `StickyNotesStore.updateContent` updates `lastModified`, marks the note dirty, and re-sorts `notes`. On macOS that can cause visible churn if the editor writes too aggressively.

## Validation

- Preferred macOS test pass:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iStickies.xcodeproj -scheme iStickies -destination 'platform=macOS' -derivedDataPath /tmp/istickies-deriveddata CODE_SIGNING_ALLOWED=NO test -only-testing:iStickiesTests`

- If you touch the AppKit window coordinator or editor bridge, run the macOS tests before finishing.
