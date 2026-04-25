# iStickies Refactor, Performance, and Hardening Review

## Executive summary

This checkout is a SwiftUI macOS/iOS sticky-notes app with local JSON persistence and CloudKit sync. It is not the Vite/React/Netlify/Supabase repository described in the initial review prompt: there is no `package.json`, `netlify/`, `assistant.ts`, `sync.ts`, TypeScript, SQL, or Supabase code in this repo.

The biggest production risk is that an empty, unavailable, partial, or otherwise incomplete CloudKit result can currently look the same as a complete empty remote snapshot. That makes it possible for clean local notes to disappear during sync. The second major risk is cross-device conflict handling: an active editor draft can ignore a remote update and later flush over it without checking whether the persisted base changed.

Architecturally, `iStickies/Services/StickyNotesCloudService.swift` is the most overloaded module. It combines CloudKit entitlement gating, sync-engine lifecycle, zone management, event handling, retry classification, record mapping, legacy migration, and query pagination. `iStickies/Services/StickyNotesStore.swift` is also doing too much: state mutation, persistence, sync scheduling, merge application, and user-facing error state all live in one `@MainActor` object.

Runtime performance is fine for a small sticky-notes app, but the current model does full-array sorting, full-snapshot persistence, broad `@Published` notifications, and cold-launch CloudKit hydration that will age poorly as note count grows. The existing tests cover several important regressions, including out-of-order snapshot writes, editor debounce behavior, conflict copies, and macOS frame suppression. The main test gap is around actual CloudKit state transitions and failure modes, because most sync tests use a simple mock service.

Validation run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iStickies.xcodeproj -scheme iStickies -destination 'platform=macOS' -derivedDataPath /tmp/istickies-deriveddata CODE_SIGNING_ALLOWED=NO test -only-testing:iStickiesTests
```

Result: passed.

## Prioritized findings

### P0: Incomplete or unavailable CloudKit snapshots can delete clean local notes

**Status:** Implemented in this pass. `fetchAllNotes()` now returns a typed `CloudRemoteSnapshot` with completeness metadata, merge only applies remote-deletion semantics to `.complete` snapshots, disabled CloudKit reports `.unavailable`, CloudKit record-level fetch/decode problems make the snapshot `.partial`, and incomplete snapshots no longer advance `lastSuccessfulCloudSync`.

**Why it matters:** `StickyNotesStore.syncNow()` treats `cloudService.fetchAllNotes()` as authoritative. `StickyNotesMergeEngine.merge()` then drops local notes that are not dirty and are not present in the remote array. That is only safe when the remote array is known to be a complete snapshot. Today, disabled CloudKit, account changes, partial query failures, skipped malformed records, or any incomplete fetch can all collapse into a plain `[StickyNote]`.

**Files/functions involved:**

- `iStickies/Services/StickyNotesStore.swift`
  - `StickyNotesStore.syncNow()`
- `iStickies/Services/StickyNotesMergeEngine.swift`
  - `StickyNotesMergeEngine.merge(localNotes:remoteNotes:pendingDeletionIDs:)`
- `iStickies/Services/StickyNotesCloudService.swift`
  - `StickyNotesCloudSyncing.fetchAllNotes()`
  - `DisabledStickyNotesCloudService.fetchAllNotes()`
  - `CloudKitStickyNotesCloudService.fetchAllNotes()`
  - `CloudKitStickyNotesCloudService.fetchRecords(query:zoneID:)`
  - `CloudKitStickyNotesCloudService.handleEvent(_:syncEngine:)`

**Concrete recommendation:** Replace the bare `[StickyNote]` fetch contract with a typed result, for example:

```swift
struct CloudRemoteSnapshot: Sendable {
    var notes: [StickyNote]
    var completeness: CloudRemoteSnapshotCompleteness
}

enum CloudRemoteSnapshotCompleteness: Sendable, Equatable {
    case complete
    case unavailable(String)
    case partial(String)
}
```

Only allow remote-deletion semantics when completeness is `.complete`. Treat disabled CloudKit, account unavailable, partial query failures, and malformed/skipped records as non-authoritative snapshots. In those states, merge remote additions/updates if safe, but do not delete local clean notes just because they are missing remotely.

Also update `fetchRecords(query:zoneID:)` so `recordMatchedBlock` failures are collected and reported. It currently appends successful records and silently ignores failed records.

**Expected payoff:** Removes the highest data-loss path in the app.

**Rough implementation scope:** medium.

### P0: Dirty editor drafts can silently overwrite remote edits

**Why it matters:** `NoteDraftSession` intentionally ignores persisted content changes while local edits are pending. That prevents active typing from being disrupted, but when the delayed save later fires, it persists the local draft through `store.updateContent()` without checking whether the underlying persisted content changed while the draft was dirty. A remote edit can therefore arrive, be ignored, and then get overwritten by the stale local draft.

**Files/functions involved:**

- `iStickies/Views/NoteDraftSession.swift`
  - `handlePersistedContentChange(_:)`
  - `schedulePersistence()`
  - `persistDraftIfNeeded(_:)`
- `iStickies/Views/NoteEditorView.swift`
  - `StickyNoteEditor.configureDraftSession(with:force:)`
- `iStickies/Services/StickyNotesStore.swift`
  - `updateContent(id:content:)`

**Concrete recommendation:** Track a draft base value or content version when editing starts. On flush, compare:

- draft base content/version
- current persisted content/version
- draft content

If persisted content changed since the draft base and differs from the draft, route through explicit conflict handling instead of blindly calling `updateContent`. A small first step is to create a conflict copy for the local draft and leave the remote/persisted content as the primary note.

**Expected payoff:** Prevents silent cross-device overwrite during active typing.

**Rough implementation scope:** medium.

### P1: CloudKit service is the main architectural bottleneck

**Why it matters:** `CloudKitStickyNotesCloudService` is 805 lines and owns too many responsibilities. This makes failure behavior hard to reason about and hard to test without live CloudKit.

**Files/functions involved:**

- `iStickies/Services/StickyNotesCloudService.swift`
  - `CloudKitStickyNotesCloudService`
  - `CloudKitStickyNotesCloudService.ensureSyncEngine()`
  - `CloudKitStickyNotesCloudService.ensureZoneExistsForWrites(syncEngine:)`
  - `CloudKitStickyNotesCloudService.importLegacyDefaultZoneNotesIfNeeded(syncEngine:)`
  - `CloudKitStickyNotesCloudService.hydrateRemoteZoneSnapshotIfNeeded()`
  - `CloudKitStickyNotesCloudService.applySentRecordZoneChanges(_:syncEngine:)`
  - `CloudKitStickyNotesCloudService.recoverRetriableSaves(from:)`
  - `StickyNote.init?(record:)`
  - `StickyNote.makeRecord(zoneID:)`
  - `ActiveSendContext`

**Concrete recommendation:** Split this file along testable seams:

- `CloudKitSyncClient`: owns `CKSyncEngine`, state serialization, fetch/send calls, and delegate forwarding.
- `CloudKitZoneStore`: owns custom zone existence, zone creation, deletion state, and legacy default-zone import.
- `StickyNoteRecordMapper`: owns `CKRecord` to `StickyNote` conversion, field compatibility, and system-field archiving.
- `CloudKitSendBatchTracker`: owns `ActiveSendContext`, saved/deleted/conflict/retry bookkeeping, and result finalization.
- `CloudKitErrorClassifier`: maps CloudKit errors into retry, conflict, missing zone, partial failure, and terminal failure categories.

Start by extracting record mapping and send-batch tracking because those require the least behavior change and can be covered with pure unit tests.

**Expected payoff:** Smaller review surface, better tests, and safer changes to sync behavior.

**Rough implementation scope:** large.

### P1: Corrupt persisted CKSyncEngine state can wedge sync

**Why it matters:** `ensureSyncEngine()` decodes persisted `CKSyncEngine.State.Serialization` directly. If that decode fails, `syncNow()` catches the error, persists again, and keeps the same bad state in the snapshot. Future launches can repeat the same failure.

**Files/functions involved:**

- `iStickies/Services/StickyNotesCloudService.swift`
  - `CloudKitStickyNotesCloudService.ensureSyncEngine()`
- `iStickies/Services/StickyNotesStore.swift`
  - `StickyNotesStore.syncNow()`
  - `StickyNotesStore.persistSnapshot()`

**Concrete recommendation:** Catch decode failures inside the cloud service, discard only the sync-engine serialization, mark the remote cache as needing hydration, and continue with a fresh sync engine. Preserve local notes and pending deletions. Add a test with invalid `cloudKitStateSerializationData`.

**Expected payoff:** Converts a persistent sync failure into self-healing recovery.

**Rough implementation scope:** small to medium.

### P1: Cold launch does a full CloudKit zone query

**Why it matters:** With restored sync state, `fetchAllNotes()` calls `syncEngine.fetchChanges()` and then `hydrateRemoteZoneSnapshotIfNeeded()`. Because `remoteNotesByID` is in-memory only, every fresh app process with persisted sync state can still query the whole custom zone.

**Files/functions involved:**

- `iStickies/Services/StickyNotesCloudService.swift`
  - `CloudKitStickyNotesCloudService.fetchAllNotes()`
  - `CloudKitStickyNotesCloudService.hydrateRemoteZoneSnapshotIfNeeded()`
  - `CloudKitStickyNotesCloudService.fetchRecords(query:zoneID:)`
- `iStickies/Services/StickyNotesStore.swift`
  - `StickyNotesStore.load()`
  - `StickyNotesStore.applyLoadedSnapshot(_:)`

**Concrete recommendation:** Seed the cloud actor's remote cache from the local snapshot, or persist a compact remote-cache snapshot alongside CKSyncEngine state. Then use incremental `CKSyncEngine` fetches as intended rather than re-querying the whole zone after each process launch.

**Expected payoff:** Faster launch sync and lower CloudKit cost as note count grows.

**Rough implementation scope:** medium.

### P1: Store writes and republishes whole-note state too often

**Why it matters:** Content updates sort the full notes array, rebuild `notesByID`, persist the entire JSON snapshot, and notify every subscriber. Dashboard and window code then rebuild dictionaries from the published array.

**Files/functions involved:**

- `iStickies/Services/StickyNotesStore.swift`
  - `notes` didSet
  - `updateContent(id:content:)`
  - `commitStateChange(_:mutation:)`
  - `persistSnapshot()`
  - `sortNotes(_:)`
- `iStickies/Views/NotesDashboardView.swift`
  - `MobileNotesSceneView.orderedNotes`
- `iStickies/Platform/macOS/MacStickyNoteWindowCoordinator.swift`
  - `syncWindows(with:)`

**Concrete recommendation:** Normalize store state into `notesByID` plus ordered note IDs. Publish smaller derived views, or provide targeted accessors for `note(id:)` and ordered IDs. Coalesce snapshot writes during editing and avoid resorting unless `lastModified` actually changes order.

**Expected payoff:** Less UI churn and better scaling to many notes.

**Rough implementation scope:** medium.

### P1: macOS window dictionary is mutated during iteration

**Why it matters:** `syncWindows(with:)` iterates `windows` and calls `window.closeFromCoordinator()`. Closing can synchronously trigger `windowWillClose`, whose `onClose` closure removes from `windows` and `windowOrder`. Mutating a Swift dictionary while iterating it is a plausible runtime crash.

**Files/functions involved:**

- `iStickies/Platform/macOS/MacStickyNoteWindowCoordinator.swift`
  - `MacStickyNoteWindowCoordinator.syncWindows(with:)`
  - `StickyNoteWindow.closeFromCoordinator()`
  - `StickyNoteWindow.windowWillClose(_:)`

**Concrete recommendation:** Collect windows or note IDs to close first, then close them after the dictionary iteration:

```swift
let windowsToClose = windows.filter { id, _ in notesByID[id]?.isOpen != true }
for (_, window) in windowsToClose {
    window.closeFromCoordinator()
}
```

**Expected payoff:** Removes a plausible runtime crash in window sync.

**Rough implementation scope:** small.

### P1: Conflict resolution depends on client clocks

**Why it matters:** `lastModified` is set from local `Date()` and used to decide whether remote or local content wins. Devices with skewed clocks can incorrectly overwrite newer edits or create bogus conflicts.

**Files/functions involved:**

- `iStickies/Services/StickyNotesStore.swift`
  - `mutateNote(id:touchModifiedAt:markNeedsCloudUpload:commitOptions:mutation:)`
- `iStickies/Services/StickyNotesMergeEngine.swift`
  - `merge(localNotes:remoteNotes:pendingDeletionIDs:)`
  - `hasCloudChangesSinceSend(_:sentNotesByID:)`
- `iStickies/Services/StickyNotesCloudService.swift`
  - `StickyNote.write(to:)`

**Concrete recommendation:** Separate display edit time from conflict versioning. Use CloudKit server metadata/change tags or a persisted base revision for conflict detection. Keep `lastModified` for display and sort order, but do not rely on it as the only cross-device conflict arbiter.

**Expected payoff:** Safer multi-device sync.

**Rough implementation scope:** medium to large.

### P1: Snapshot decode has no versioning or recovery path

**Why it matters:** `StickyNotesFileStore.load()` decodes one JSON file directly. Decode failure causes `StickyNotesStore.load()` to set an error and continue to initial sync with empty local state.

**Files/functions involved:**

- `iStickies/Services/StickyNotesFileStore.swift`
  - `load()`
  - `save(_:)`
- `iStickies/Services/StickyNotesStore.swift`
  - `load()`
  - `loadIfNeeded()`
- `iStickies/Models/StickyNote.swift`
  - `StickyNotesSnapshot`

**Concrete recommendation:** Add snapshot schema versioning, backup/quarantine of unreadable files, and migration tests. On decode failure, preserve the corrupt file for diagnosis and avoid treating empty local state as authoritative until the user or recovery path resolves it.

**Expected payoff:** Better local-first reliability across app updates and file corruption.

**Rough implementation scope:** medium.

### P1: App Store Connect workflow uses unpinned third-party actions with secrets

**Why it matters:** `.github/workflows/trigger-xcode-cloud.yml` passes App Store Connect credentials to tag-based third-party actions. Tags can move, and the secrets are high-value.

**Files/functions involved:**

- `.github/workflows/trigger-xcode-cloud.yml`
  - `yuki0n0/action-appstoreconnect-token@v1.0`
  - `yorifuji/actions-xcode-cloud-dispatcher@v1`

**Concrete recommendation:** Pin actions to commit SHAs, put App Store Connect secrets behind a protected environment, and restrict or review branch dispatches.

**Expected payoff:** Reduces CI supply-chain risk.

**Rough implementation scope:** small.

### P2: UI tests are mostly template scaffolding

**Why it matters:** The unit tests cover core pure logic well, but UI tests currently only launch the app and measure launch performance. They do not exercise note creation, edit persistence, deletion confirmation, or window behavior.

**Files/functions involved:**

- `iStickiesUITests/iStickiesUITests.swift`
- `iStickiesUITests/iStickiesUITestsLaunchTests.swift`

**Concrete recommendation:** Replace the template UI tests with a small set of launch-argument-controlled flows using an isolated temporary store:

- create and edit a note
- relaunch and verify it persists
- delete a note with confirmation
- macOS: open multiple sticky windows and verify close/delete behavior

**Expected payoff:** Better coverage for user-facing regressions.

**Rough implementation scope:** medium.

### P2: Observability is missing from sync and persistence paths

**Why it matters:** There are no `Logger`, `OSLog`, signposts, or structured diagnostics in the sync/persistence paths. Production failures will surface mostly as user-facing alert strings.

**Files/functions involved:**

- `iStickies/Services/StickyNotesStore.swift`
  - `load()`
  - `syncNow()`
  - `persistSnapshot()`
- `iStickies/Services/StickyNotesCloudService.swift`
  - `handleEvent(_:syncEngine:)`
  - `syncChanges(saves:deletions:)`
  - `fetchRecords(query:zoneID:)`

**Concrete recommendation:** Add `OSLog` categories for sync, CloudKit, persistence, and window coordination. Log account changes, snapshot completeness, retry counts, conflict counts, partial failures, corrupt-state recovery, and persistence failures. Keep note content out of logs.

**Expected payoff:** Faster diagnosis of production sync failures without exposing user content.

**Rough implementation scope:** small to medium.

## Refactor plan

### Stage 1: Lock down sync safety

Start with the P0 sync contract change. This is the most important behavior fix and should happen before large file splitting. Introduce a typed remote snapshot result, update merge semantics so incomplete snapshots cannot delete clean local notes, and add targeted tests.

Keep the implementation incremental:

1. Add `CloudRemoteSnapshot` and completeness states.
2. Change `StickyNotesCloudSyncing.fetchAllNotes()` to return that type.
3. Update `StickyNotesStore.syncNow()` to pass snapshot completeness into merge.
4. Update merge logic to only apply remote deletion semantics for complete snapshots.
5. Add tests for disabled cloud, partial fetch failure, and malformed/skipped records.

### Stage 2: Extract CloudKit pure seams

Extract low-risk components from `StickyNotesCloudService.swift` without changing behavior:

1. `StickyNoteRecordMapper`
2. `CloudKitSendBatchTracker`
3. `CloudKitErrorClassifier`

These components can be unit-tested without live CloudKit and will make the later sync fixes easier to review.

### Stage 3: Separate sync orchestration from store mutation

Move `syncNow()` orchestration out of `StickyNotesStore` into a small coordinator that receives local state and returns a state transition:

- fetch remote snapshot
- merge local and remote
- compute outgoing saves/deletions
- send changes
- apply sync result
- choose retry delay

The store should still own published state and UI-facing mutation APIs, but it should not own the whole sync workflow.

### Stage 4: Harden editor draft conflict handling

Add draft base tracking to `NoteDraftSession` and a store API that can persist a draft only if the expected base still matches. If not, preserve the local draft as a conflict copy.

### Stage 5: Normalize state and reduce UI churn

Only after correctness is improved, consider normalizing store state into `notesByID` and ordered IDs. This is more invasive and should follow the sync safety work.

## Performance plan

### Quick wins

1. Collect macOS windows to close before mutating the coordinator dictionary.
2. Avoid rebuilding note dictionaries in dashboard/window paths when the store already maintains `notesByID`.
3. Coalesce local snapshot writes more aggressively during editing.
4. Avoid resorting on every content flush unless order actually changes.

### Deeper work

1. Seed or persist the CloudKit remote cache to avoid full-zone hydration on every cold launch.
2. Normalize store state into ID-indexed storage plus ordered IDs.
3. Publish narrower state changes so one note edit does not make every subscriber recompute.
4. Move conflict/version metadata away from client-clock-only `lastModified`.

## Hardening plan

### Highest-risk correctness issues

1. Incomplete CloudKit snapshots deleting clean local notes.
   - Add tests for disabled CloudKit, account unavailable, partial query failure, malformed record skip, and missing zone.
   - Add observability for snapshot completeness and record-level failures.

2. Dirty local drafts overwriting remote edits.
   - Add a test where a local draft is pending, remote content arrives, then flush preserves both versions.
   - Add base-version checks to draft persistence.

3. Corrupt sync-state serialization wedging sync.
   - Add a test with invalid `cloudKitStateSerializationData`.
   - Discard only bad CloudKit engine state and preserve local notes.

4. Corrupt local snapshot file causing empty-state sync.
   - Add decode recovery tests.
   - Quarantine unreadable snapshots and avoid treating empty local state as authoritative.

5. Client-clock conflict mistakes.
   - Add tests with skewed local/remote `lastModified` values.
   - Introduce stable sync revision metadata.

### Security and production readiness

1. Pin GitHub Actions by commit SHA and protect App Store Connect secrets.
2. Keep note content out of logs and diagnostics.
3. Add structured logs for sync state changes, retries, conflict copies, persistence failures, and CloudKit account changes.
4. Consider a user-visible recovery path for local snapshot corruption and persistent CloudKit account errors.

## Best next implementation prompt

Implement the P0 sync safety fix: change the CloudKit fetch contract so unavailable or incomplete remote snapshots cannot delete clean local notes; collect per-record query failures; update `StickyNotesStore.syncNow` and `StickyNotesMergeEngine` accordingly; add tests for disabled cloud service with a clean local snapshot, partial remote fetch failure, and malformed remote record handling.
