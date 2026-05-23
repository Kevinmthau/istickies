# iStickies Performance Refactor Roadmap

This is a focused performance and architecture roadmap for the current SwiftUI
macOS/iOS app. It complements `docs/refactor-plan.md`, which tracks the broader
sync hardening history and already-completed correctness fixes.

## Current Architecture

- `iStickies/Services/StickyNotesStore.swift` is the main app state boundary. It
  owns normalized note state, published list/status state, local persistence
  scheduling, and sync task execution.
- `iStickies/Services/StickyNotesSyncCoordinator.swift` owns sync orchestration:
  remote fetch, merge, outgoing change selection, result application, and retry
  delay decisions.
- `iStickies/Services/StickyNotesCloudService.swift` owns the CloudKit actor,
  `CKSyncEngine` lifecycle, account state, custom zone state, remote cache
  hydration, legacy import, and CloudKit event handling.
- `iStickies/Services/StickyNotesMergeEngine.swift` owns merge and conflict
  rules for local notes, remote snapshots, sent saves, retries, and deletions.
- `iStickies/Views/NoteEditorView.swift` owns the shared editor plus AppKit and
  UIKit text view bridges.
- `iStickies/Platform/macOS/MacStickyNoteWindowCoordinator.swift` owns macOS
  sticky windows, ordering, focus, and note-window synchronization.

The current shape is good for a small note count. Remaining risk is mostly
write amplification and O(n) work on hot paths, not correctness.

## Priority Refactors

### P1: Reduce local snapshot write amplification

**Problem:** Many small UI mutations still serialize the entire snapshot and
write both the primary JSON file and backup file. This includes editor saves,
open/close changes, and macOS window-frame updates.

**Main files:**

- `iStickies/Services/StickyNotesStore.swift`
  - `updateContent(id:content:expectedBaseContent:)`
  - `updatePreferredFrame(id:frame:)`
  - `commitStateChange(_:mutation:)`
  - `persistSnapshotNow()`
- `iStickies/Services/StickyNotesFileStore.swift`
  - `save(_:)`
- `iStickies/Models/StickyNote.swift`
  - `StickyNotesSnapshot`

**Refactor options:**

1. Split volatile UI state from content/cloud state. Keep `isOpen` and
   `preferredFrame` in a smaller local UI snapshot so window movement does not
   rewrite every note body and remote-cache entry.
2. Store notes by ID on disk instead of a single monolithic array. A small
   manifest can keep ordering, pending deletions, sync metadata, and cloud cache.
3. If full JSON snapshots remain, remove `.prettyPrinted` and `.sortedKeys` for
   production saves. Keep readable output only for test fixtures or debugging.

**Payoff:** Lower disk I/O, less encoding work, faster shutdown flushes, and
better behavior with many notes or long note bodies.

**Suggested first slice:** Keep the current JSON format for note content, but
write a separate `sticky-notes-ui.json` for `isOpen` and `preferredFrame`. Add a
migration path that hydrates UI state from the old snapshot when the UI file is
missing.

### P1: Make store commits targeted

**Problem:** A single-note mutation still does broad work: copy the whole
`notesByID` dictionary, rebuild/equality-check the ordered `notes` array, filter
all open IDs, and diff all note IDs to publish changed observations.

**Main files:**

- `iStickies/Services/StickyNotesStore.swift`
  - `mutateNote(...)`
  - `commitStateChange(_:mutation:)`
  - `publishStoredState()`
  - `publishChangedNoteObservations(comparedTo:)`

**Refactor options:**

1. Change `commitStateChange` to accept or return `changedNoteIDs`,
   `insertedNoteIDs`, and `deletedNoteIDs`.
2. Update `StickyNoteObservation` directly for known changed notes instead of
   diffing the full dictionary.
3. Maintain `openNoteIDs` incrementally for `openNote`, `closeNote`,
   `openAllNotes`, and `deleteNote`.
4. Avoid rebuilding `notes` unless a legacy caller still needs the full ordered
   array. Prefer `noteIDs` plus `note(withID:)`.

**Payoff:** Less main-actor work during typing, frame updates, and window
open/close events.

**Suggested first slice:** Add a targeted mutation result type:

```swift
private struct StoreMutationResult {
    var changedNoteIDs: Set<String> = []
    var insertedNoteIDs: Set<String> = []
    var deletedNoteIDs: Set<String> = []
    var orderChanged = false
    var openStateChanged = false
}
```

Then migrate `mutateNote`, `createNote`, and `deleteNote` before changing sync
application paths.

### P1: Index sync batch application

**Problem:** `StickyNotesMergeEngine.apply(...)` applies saved notes, pending
retry notes, and conflicts with repeated `firstIndex` scans. Large CloudKit
batches can become O(n*m).

**Main files:**

- `iStickies/Services/StickyNotesMergeEngine.swift`
  - `apply(syncResult:to:pendingDeletionIDs:sentNotesByID:)`
  - `applySavedNote(...)`
  - `applyPendingRetryNote(...)`
  - `replace(note:in:)`

**Refactor options:**

1. Build `[String: Int]` once at the start of `apply`.
2. Replace notes by index for saved/retry/conflict updates.
3. Append conflict copies after all indexed replacements.
4. Keep output order unchanged except for appended conflict copies.

**Payoff:** Faster sync completion when many notes are saved or retried at once.

**Suggested first slice:** Keep the public merge API unchanged and implement the
index map internally. Add a unit test that applies a mixed saved/retry/conflict
batch and verifies ordering plus conflict-copy behavior.

### P2: Split the CloudKit actor into smaller services

**Problem:** `CloudKitStickyNotesCloudService` is the main architectural
bottleneck. It combines account checking, sync-engine restore, custom-zone
management, remote-cache hydration, legacy migration, batching, retry recovery,
and delegate event handling.

**Main file:**

- `iStickies/Services/StickyNotesCloudService.swift`

**Recommended seams:**

- `CloudKitAccountSession`: account identifier lookup, accepted account state,
  sign-in/sign-out/switch handling, and cache invalidation decisions.
- `CloudKitSyncEngineStore`: `CKSyncEngine` construction, state serialization
  recovery, and delegate state-update handling.
- `CloudKitZoneCache`: custom zone existence, remote note cache, hydration, zone
  reset handling, and legacy default-zone import.
- `CloudKitChangeTransport`: record-zone pending changes, `sendChanges`,
  `fetchChanges`, and `nextRecordZoneChangeBatch`.

**Payoff:** Smaller review surface, more unit-testable CloudKit behavior, and
less risk when changing sync performance.

**Suggested first slice:** Extract account access and cache invalidation into a
small value-oriented helper before moving any `CKSyncEngine` code.

### P2: Simplify sticky-paper rendering in large lists

**Problem:** Every card surface uses multiple gradients, a compositing group,
two shadows, custom shapes, and repeated texture subviews. It looks good, but it
is expensive when many cards are visible or many macOS windows are open.

**Main file:**

- `iStickies/Views/NotesDashboardView.swift`
  - `StickyNotePaperSurface`
  - `StickyNotePaperBackground`
  - `StickyNotePaperTexture`
  - `StickyNoteCornerCurl`

**Refactor options:**

1. Use the full paper treatment only for the active editor or macOS windows.
2. Use a simplified paper surface for grid cards.
3. Replace per-card texture subviews with a cached/resizable raster or a single
   lightweight overlay.
4. Measure with Instruments before and after, especially on iOS scrolling.

**Payoff:** Smoother grid scrolling and less compositing work.

**Suggested first slice:** Add `StickyNotePaperSurfaceStyle.full` and
`.compact`, then switch `StickyNoteCardView` to `.compact` while keeping editor
cards on `.full`.

### P2: Throttle editor layout measurement

**Problem:** The AppKit and UIKit text bridges call layout measurement on most
updates and text changes to vertically center content. For long notes,
`ensureLayout` plus `usedRect` can become a typing hotspot.

**Main file:**

- `iStickies/Views/NoteEditorView.swift`
  - `MacStickyTextView.updateStickyTextInsets(...)`
  - `CenteredStickyTextView.updateStickyTextInsets()`
  - `textDidChange(_:)`
  - `textViewDidChange(_:)`

**Refactor options:**

1. Cache the last measured bounds height, text length, and inset.
2. Recalculate only when bounds change or text length crosses a line-wrapping
   threshold.
3. For active editing, schedule inset updates on the next run loop instead of
   doing them synchronously on every keystroke.
4. Keep immediate updates for programmatic text replacement and initial layout.

**Payoff:** Lower typing latency for longer notes.

**Suggested first slice:** Add a small coordinator-side debounce for inset
updates during active typing, then preserve synchronous updates for make/update
view paths.

### P3: Remove smaller quadratic helpers

**Problem:** Some presentation helpers are quadratic but only run during explicit
commands, so they are lower priority.

**Main files:**

- `iStickies/Platform/macOS/MacStickyNoteWindowCoordinator.swift`
  - `orderedWindowsForPresentation()`
  - `StickyNoteWindowGridLayout.framesRespectGap(...)`

**Refactor options:**

1. Replace `windowOrder.contains` checks with a `Set`.
2. Leave grid gap checking alone unless tiling many windows becomes a real
   problem; it is user-triggered and likely small.

**Payoff:** Small cleanup, mostly useful after the P1/P2 work.

## Suggested Implementation Order

1. Index `StickyNotesMergeEngine.apply(...)`. This is low-risk, easy to test,
   and removes a clear algorithmic issue.
2. Add targeted store mutation results. Start with create/update/delete note
   paths, then migrate open/close/frame paths.
3. Split UI persistence from content/cloud persistence. This has the highest
   runtime payoff but needs careful migration and recovery tests.
4. Add compact paper rendering for grid cards and profile scrolling.
5. Debounce editor inset recalculation if typing still shows measurable layout
   cost.
6. Continue decomposing `CloudKitStickyNotesCloudService` along account, zone
   cache, sync-engine, and transport boundaries.

## Validation

For store, editor, sync, or macOS window changes, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iStickies.xcodeproj -scheme iStickies -destination 'platform=macOS' -derivedDataPath /tmp/istickies-deriveddata CODE_SIGNING_ALLOWED=NO test -only-testing:iStickiesTests
```

For rendering changes, also manually inspect:

- iOS note grid with many notes.
- iOS active editor with a long note.
- macOS multiple sticky windows.
- macOS window drag/resize behavior, including frame persistence.

## Non-Goals

- Do not redo the completed P0 sync safety and dirty-draft conflict fixes unless
  a new bug is found.
- Do not remove the local snapshot backup/quarantine path.
- Do not weaken macOS frame suppression while dragging sticky windows.
- Do not make CloudKit snapshots authoritative unless their completeness is
  known to be `.complete`.
