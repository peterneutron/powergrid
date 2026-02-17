#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."
SPEC_FILE="${PROJECT_ROOT}/project.yml"
PROJECT_PATH="${PROJECT_ROOT}/cmd/powergrid-app/PowerGrid/PowerGrid.xcodeproj"
PBXPROJ_PATH="${PROJECT_PATH}/project.pbxproj"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found in PATH" >&2
  exit 1
fi

normalize_pbxproj() {
  local src="$1"
  local dst="$2"
  sed -E \
    -e 's/objectVersion = [0-9]+;/objectVersion = <normalized>;/g' \
    -e 's/preferredProjectObjectVersion = [0-9]+;/preferredProjectObjectVersion = <normalized>;/g' \
    "$src" >"$dst"
}

if [[ ! -f "$SPEC_FILE" ]]; then
  echo "error: missing spec file: $SPEC_FILE" >&2
  exit 1
fi

if [[ ! -f "$PBXPROJ_PATH" ]]; then
  echo "error: missing generated project file: $PBXPROJ_PATH" >&2
  exit 1
fi

before_norm="$(mktemp)"
after_norm="$(mktemp)"
trap 'rm -f "$before_norm" "$after_norm"' EXIT

normalize_pbxproj "$PBXPROJ_PATH" "$before_norm"
before_hash="$(shasum -a 256 "$before_norm" | awk '{print $1}')"
xcodegen generate --spec "$SPEC_FILE" --project "${PROJECT_ROOT}/cmd/powergrid-app/PowerGrid" >/dev/null
normalize_pbxproj "$PBXPROJ_PATH" "$after_norm"
after_hash="$(shasum -a 256 "$after_norm" | awk '{print $1}')"
if [[ "$before_hash" != "$after_hash" ]]; then
  echo "error: Xcode project is stale. Run: make xcodegen" >&2
  diff -u "$before_norm" "$after_norm" | sed -n '1,120p' >&2 || true
  exit 1
fi

echo "✅ Xcode project is in sync with project.yml."
