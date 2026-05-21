#!/bin/sh
set -eu

echo "[ci_post_xcodebuild] Preparing TestFlight tester notes"

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TESTFLIGHT_DIR="$PROJECT_ROOT/TestFlight"
WHAT_TO_TEST_FILE="$TESTFLIGHT_DIR/WhatToTest.en-US.txt"

if [ "${CI_XCODE_CLOUD:-}" != "TRUE" ]; then
  echo "[ci_post_xcodebuild] Not running in Xcode Cloud; skipping tester notes"
  exit 0
fi

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo "[ci_post_xcodebuild] Xcode action is not archive; skipping tester notes"
  exit 0
fi

if [ -z "${CI_APP_STORE_SIGNED_APP_PATH:-}" ] || [ ! -d "$CI_APP_STORE_SIGNED_APP_PATH" ]; then
  echo "[ci_post_xcodebuild] App Store signed app is unavailable; skipping tester notes"
  exit 0
fi

cd "$PROJECT_ROOT"

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
  git fetch --deepen=5 || echo "[ci_post_xcodebuild] Could not deepen checkout; using available commit history"
fi

CHANGE_LINES="$(git log --no-merges -5 --pretty=format:'- %s' 2>/dev/null || true)"

if [ -z "$CHANGE_LINES" ]; then
  CHANGE_LINES="$(git log -5 --pretty=format:'- %s' 2>/dev/null || true)"
fi

if [ -z "$CHANGE_LINES" ]; then
  CHANGE_LINES="- Xcode Cloud build ${CI_BUILD_NUMBER:-unknown}"
fi

mkdir -p "$TESTFLIGHT_DIR"
{
  echo "Changes in this build:"
  printf '%s\n' "$CHANGE_LINES"
} > "$WHAT_TO_TEST_FILE"

echo "[ci_post_xcodebuild] Wrote $WHAT_TO_TEST_FILE"
