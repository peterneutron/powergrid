#!/bin/bash
set -euo pipefail

echo "--- Building Go Binaries ---"

resolve_go() {
    if [ -n "${GO_BIN:-}" ]; then
        if [ -x "${GO_BIN}" ]; then
            echo "${GO_BIN}"
            return 0
        fi
        echo "❌ ERROR: GO_BIN is set but not executable: ${GO_BIN}" >&2
        exit 1
    fi

    if command -v go >/dev/null 2>&1; then
        command -v go
        return 0
    fi

    for candidate in \
        "${HOME}/.nix-profile/bin/go" \
        "${HOME}/go/bin/go" \
        "${HOME}/.asdf/shims/go" \
        "${HOME}/.local/bin/go"
    do
        if [ -x "${candidate}" ]; then
            echo "${candidate}"
            return 0
        fi
    done

    cat >&2 <<'ERR'
❌ ERROR: Could not locate a Go toolchain.
Tried:
  - GO_BIN override
  - PATH lookup (command -v go)
  - Common locations:
      $HOME/.nix-profile/bin/go
      $HOME/go/bin/go
      $HOME/.asdf/shims/go
      $HOME/.local/bin/go

If this is an Xcode build, remember Xcode uses a minimal shell environment.
Set GO_BIN to an absolute path in your scheme/build environment, for example:
  GO_BIN=/Users/<you>/.nix-profile/bin/go
ERR
    exit 1
}

hash_daemon_sources() {
    local digest_input
    digest_input="$({
        find "${DAEMON_SOURCE_DIR}" -type f -print | sort
        printf '%s\n' "${PROJECT_ROOT}/go.mod"
        printf '%s\n' "${PROJECT_ROOT}/go.sum"
    } | while read -r f; do
        [ -f "$f" ] || continue
        printf '%s\n' "${f#${PROJECT_ROOT}/}"
        shasum -a 256 "$f" | awk '{print $1}'
    done)"

    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "${digest_input}" | shasum -a 256 | awk '{print substr($1,1,12)}'
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "${digest_input}" | md5 | awk '{print substr($NF,1,12)}'
    else
        printf '%s' "${digest_input}" | cksum | awk '{print substr($1,1,12)}'
    fi
}

append_flag() {
    local current="$1"
    local flag="$2"
    if [ -z "${current}" ]; then
        printf '%s' "${flag}"
    else
        printf '%s %s' "${current}" "${flag}"
    fi
}

if [ -n "${PROJECT_ROOT:-}" ]; then
    echo "Using PROJECT_ROOT override: ${PROJECT_ROOT}"
elif [ -n "${SRCROOT:-}" ]; then
    echo "🔨 Xcode environment detected."
    PROJECT_ROOT="${SRCROOT}/../../.."
    echo "Using SRCROOT: ${SRCROOT} (Project Root: ${PROJECT_ROOT})"
else
    echo "🖥 Manual execution detected."
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    PROJECT_ROOT="${SCRIPT_DIR}/.."
    echo "Calculated Project Root: ${PROJECT_ROOT}"
fi

GO_BIN_RESOLVED="$(resolve_go)"
echo "Using go binary: ${GO_BIN_RESOLVED}"
"${GO_BIN_RESOLVED}" version

DAEMON_SOURCE_DIR="${PROJECT_ROOT}/cmd/powergrid-daemon"
HELPER_SOURCE_DIR="${PROJECT_ROOT}/cmd/powergrid-helper"
CLI_SOURCE_DIR="${PROJECT_ROOT}/cmd/powergridctl"
XCODE_MODE=0
if [ -n "${SRCROOT:-}" ] && [ -n "${DERIVED_FILE_DIR:-}" ]; then
    XCODE_MODE=1
fi

if [ "${XCODE_MODE}" -eq 1 ]; then
    BUILD_OUTPUT_DIR="${DERIVED_FILE_DIR}/powergrid-go"
else
    BUILD_OUTPUT_DIR="${PROJECT_ROOT}/build-go"
fi
DAEMON_BUILDMETA_PATH="${BUILD_OUTPUT_DIR}/powergrid-daemon.buildmeta"

mkdir -p "${BUILD_OUTPUT_DIR}"

echo "--- Computing daemon BuildID ---"
BUILD_ID_SOURCE="${DAEMON_BUILD_SOURCE:-}"
BUILD_DIRTY="false"
DAEMON_BUILD_ID="${DAEMON_BUILD_ID:-}"

if [ -n "${DAEMON_BUILD_ID}" ]; then
    if [ -z "${BUILD_ID_SOURCE}" ]; then
        BUILD_ID_SOURCE="override"
    fi
elif [ "${XCODE_MODE}" -eq 1 ]; then
    DAEMON_BUILD_ID="$(hash_daemon_sources)-xcode"
    BUILD_ID_SOURCE="xcode-derived"
elif command -v git >/dev/null 2>&1 && [ -d "${PROJECT_ROOT}/.git" ]; then
    DAEMON_BUILD_ID=$(git -C "${PROJECT_ROOT}" rev-parse --short=12 HEAD:cmd/powergrid-daemon || true)
    DIRTY_SUFFIX=""
    DIRTY_PATHS=(
        "cmd/powergrid-daemon"
        "cmd/powergrid-helper"
        "scripts/build-go.sh"
        "go.mod"
        "go.sum"
    )
    if ! git -C "${PROJECT_ROOT}" diff --quiet -- "${DIRTY_PATHS[@]}" 2>/dev/null; then
        DIRTY_SUFFIX="-dirty"
        BUILD_DIRTY="true"
    elif ! git -C "${PROJECT_ROOT}" diff --cached --quiet -- "${DIRTY_PATHS[@]}" 2>/dev/null; then
        DIRTY_SUFFIX="-dirty"
        BUILD_DIRTY="true"
    elif [ -n "$(git -C "${PROJECT_ROOT}" ls-files --others --exclude-standard -- "${DIRTY_PATHS[@]}" 2>/dev/null)" ]; then
        DIRTY_SUFFIX="-dirty"
        BUILD_DIRTY="true"
    fi
    DAEMON_BUILD_ID="${DAEMON_BUILD_ID}${DIRTY_SUFFIX}"
    if [ -n "${DAEMON_BUILD_ID}" ] && [ -z "${BUILD_ID_SOURCE}" ]; then
        BUILD_ID_SOURCE="git"
    fi
fi

if [ -z "${DAEMON_BUILD_ID}" ]; then
    DAEMON_BUILD_ID="$(hash_daemon_sources)-fallback"
    if [ -z "${BUILD_ID_SOURCE}" ]; then
        BUILD_ID_SOURCE="fallback"
    fi
    echo "⚠️ WARNING: git metadata unavailable; using fallback BuildID."
fi

if [ -z "${DAEMON_BUILD_ID}" ]; then
    echo "❌ ERROR: Unable to compute daemon BuildID." >&2
    exit 1
fi

if [[ "${DAEMON_BUILD_ID}" == *"-dirty" ]]; then
    BUILD_DIRTY="true"
fi

echo "Daemon BuildID: ${DAEMON_BUILD_ID} (source=${BUILD_ID_SOURCE}, dirty=${BUILD_DIRTY})"

# Keep the Go/Cgo deployment target aligned with project target.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.5}"
export CGO_CFLAGS="$(append_flag "${CGO_CFLAGS:-}" "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}")"
export CGO_LDFLAGS="$(append_flag "${CGO_LDFLAGS:-}" "-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}")"

echo "--- Building powergrid-daemon ---"
"${GO_BIN_RESOLVED}" build \
    -ldflags "-X 'main.BuildID=${DAEMON_BUILD_ID}' -X 'main.BuildIDSource=${BUILD_ID_SOURCE}' -X 'main.BuildDirty=${BUILD_DIRTY}'" \
    -o "${BUILD_OUTPUT_DIR}/powergrid-daemon" \
    "${DAEMON_SOURCE_DIR}"

echo "${DAEMON_BUILD_ID}" > "${BUILD_OUTPUT_DIR}/powergrid-daemon.buildid"
cat > "${DAEMON_BUILDMETA_PATH}" <<META
build_id=${DAEMON_BUILD_ID}
build_id_source=${BUILD_ID_SOURCE}
build_dirty=${BUILD_DIRTY}
META

echo "--- Building powergrid-helper ---"
"${GO_BIN_RESOLVED}" build -o "${BUILD_OUTPUT_DIR}/powergrid-helper" "${HELPER_SOURCE_DIR}"

echo "--- Building powergridctl ---"
"${GO_BIN_RESOLVED}" build -o "${BUILD_OUTPUT_DIR}/powergridctl" "${CLI_SOURCE_DIR}"

echo "✅ Go binaries built successfully."
