# iStickies

iStickies is a SwiftUI sticky-notes app for macOS and iOS with local-first persistence and CloudKit sync.

## Current architecture

- `StickyNotesStore` keeps note state in memory, writes it to disk immediately, and syncs in the background.
- `CKSyncEngine` drives CloudKit sync with persisted engine state and per-note system fields for incremental fetch/send behavior.
- macOS uses AppKit-backed floating note windows plus a dashboard window for managing hidden notes.
- iOS uses a SwiftUI list/detail interface over the same shared store.

## Notable behaviors

- Notes survive offline edits because the app persists to `Application Support` before syncing.
- When a newer CloudKit version beats a local unsynced edit, the remote note wins and a `Conflict Copy` is preserved locally instead of dropping the draft.
- macOS note windows restore their size and position.

## Development

- macOS compile check:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iStickies.xcodeproj -scheme iStickies -destination 'platform=macOS' -derivedDataPath /tmp/istickies-deriveddata CODE_SIGNING_ALLOWED=NO build`
- iOS compile check:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iStickies.xcodeproj -scheme iStickies -destination 'generic/platform=iOS' -derivedDataPath /tmp/istickies-ios-deriveddata CODE_SIGNING_ALLOWED=NO build`
