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
- macOS unit tests:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iStickies.xcodeproj -scheme iStickiesUnitTests -destination 'platform=macOS' -derivedDataPath /tmp/istickies-deriveddata CODE_SIGNING_ALLOWED=NO test`
- iOS compile check:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project iStickies.xcodeproj -scheme iStickies -destination 'generic/platform=iOS' -derivedDataPath /tmp/istickies-ios-deriveddata CODE_SIGNING_ALLOWED=NO build`

## Xcode Cloud + TestFlight setup

The repo is now prepped for Xcode Cloud with a committed shared scheme (`iStickies.xcodeproj/xcshareddata/xcschemes/iStickies.xcscheme`) plus optional CI scripts under `ci_scripts/`.

1. In Xcode, open `Settings > Accounts` and sign in with the Apple Developer account that owns your App Store Connect app.
2. Open `iStickies.xcodeproj`, then go to `Report navigator > Cloud` and create a new workflow for this repository.
3. Configure the workflow:
   - **Start condition**: remove the automatic **Branch Changes** condition. GitHub Actions triggers `main` builds, and the workflow remains available for manual branch builds.
   - **Action**: **Archive** the `iStickies` scheme.
   - **Post-action**: **Distribute to TestFlight**.
4. Optional script hooks:
   - **Post-clone**: `ci_scripts/ci_post_clone.sh`
   - **Pre-xcodebuild**: `ci_scripts/ci_pre_xcodebuild.sh`
   - **Post-xcodebuild**: `ci_scripts/ci_post_xcodebuild.sh`
5. Add signing assets and App Store Connect access in workflow settings, then run the workflow once manually.

### Notes

- Xcode Cloud/TestFlight account linking is configured in Xcode + App Store Connect UI (not in Git files).
- `ci_pre_xcodebuild.sh` syncs Apple Generic build numbers to Xcode Cloud's `CI_BUILD_NUMBER` during archive actions so uploads don't reuse the checked-in build number.
- `ci_post_xcodebuild.sh` generates `TestFlight/WhatToTest.en-US.txt` from recent commit subjects during archive actions, so Xcode Cloud populates TestFlight's "What to Test" field automatically.
- If App Store Connect already has higher build numbers for this app, set the workflow's next build number in Xcode Cloud before the first upload.
- After the first successful archive/upload run, pushes to `main` can auto-publish to TestFlight through the GitHub Actions trigger below.

## Triggering Xcode Cloud from GitHub

The GitHub Actions workflow at `.github/workflows/trigger-xcode-cloud.yml` dispatches the existing Xcode Cloud workflow whenever `main` is pushed. It can also be run manually for another branch.

### One-time setup in GitHub

1. Create a GitHub environment named `app-store-connect`.
2. Add these environment secrets:
   - `APP_STORE_CONNECT_ISSUER_ID`
   - `APP_STORE_CONNECT_KEY_ID`
   - `APP_STORE_CONNECT_PRIVATE_KEY` (full `.p8` key contents)
3. Add this environment variable:
   - `XCODE_CLOUD_WORKFLOW_ID` (from App Store Connect URL: `/ci/workflows/{workflow-id}`)
4. Run **Actions > Trigger Xcode Cloud Build > Run workflow** once and choose `main` to verify the credentials.

After setup, each push to `main` triggers the Xcode Cloud workflow through the App Store Connect API without requiring local Xcode interaction. The manual action remains available for branch-specific builds.
