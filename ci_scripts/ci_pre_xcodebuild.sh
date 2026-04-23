#!/bin/sh
set -eu

echo "[ci_pre_xcodebuild] Preparing environment"

PROJECT_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(pwd)}"
PROJECT_FILE="$PROJECT_ROOT/iStickies.xcodeproj"

echo "[ci_pre_xcodebuild] Project root: $PROJECT_ROOT"
echo "[ci_pre_xcodebuild] Xcode version:"
xcodebuild -version

if [ -n "${CI_DERIVED_DATA_PATH:-}" ]; then
  echo "[ci_pre_xcodebuild] DerivedData path: $CI_DERIVED_DATA_PATH"
fi

if [ "${CI_XCODE_CLOUD:-}" = "TRUE" ] && [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
  BUILD_NUMBER="${CI_BUILD_NUMBER:-}"
  case "$BUILD_NUMBER" in
    ''|*[!0-9]*)
      echo "[ci_pre_xcodebuild] Expected numeric CI_BUILD_NUMBER for archive actions"
      exit 1
      ;;
  esac

  echo "[ci_pre_xcodebuild] Setting CURRENT_PROJECT_VERSION to $BUILD_NUMBER"
  perl -0pi -e "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/g" \
    "$PROJECT_FILE/project.pbxproj"
fi

echo "[ci_pre_xcodebuild] Available schemes:"
xcodebuild -list -project "$PROJECT_FILE"
