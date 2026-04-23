#!/bin/sh
set -eu

echo "[ci_post_clone] Xcode Cloud checkout complete for iStickies"

# Xcode Cloud chooses the DerivedData location and exposes it to scripts.
if [ -n "${CI_DERIVED_DATA_PATH:-}" ]; then
  mkdir -p "$CI_DERIVED_DATA_PATH"
  echo "[ci_post_clone] DerivedData path: $CI_DERIVED_DATA_PATH"
fi

# No dependency bootstrap is currently required.
echo "[ci_post_clone] No additional bootstrap steps required"
