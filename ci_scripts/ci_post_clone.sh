#!/bin/sh
set -eu

echo "[ci_post_clone] Xcode Cloud checkout complete for iStickies"

# Keep DerivedData inside the CI workspace for easier diagnostics.
if [ -n "${CI_WORKSPACE:-}" ]; then
  DERIVED_DATA_PATH="$CI_WORKSPACE/DerivedData"
  mkdir -p "$DERIVED_DATA_PATH"
  echo "[ci_post_clone] DerivedData path: $DERIVED_DATA_PATH"
fi

# No dependency bootstrap is currently required.
echo "[ci_post_clone] No additional bootstrap steps required"
