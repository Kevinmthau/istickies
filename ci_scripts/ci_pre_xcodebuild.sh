#!/bin/sh
set -eu

echo "[ci_pre_xcodebuild] Preparing environment"

PROJECT_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(pwd)}"
PROJECT_FILE="$PROJECT_ROOT/iStickies.xcodeproj"

echo "[ci_pre_xcodebuild] Project root: $PROJECT_ROOT"
echo "[ci_pre_xcodebuild] Xcode version:"
xcodebuild -version

echo "[ci_pre_xcodebuild] Available schemes:"
xcodebuild -list -project "$PROJECT_FILE"
