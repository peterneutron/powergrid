#
# =================================================================
# BUILDS THE GO BINARIES
# =================================================================

set -e

echo "--- Building Go Binaries ---"

resolve_go() {
    # Highest priority: explicit override.
    if [ -n "${GO_BIN:-}" ]; then
        if [ -x "${GO_BIN}" ]; then
            echo "${GO_BIN}"
            return 0
        fi
        echo "❌ ERROR: GO_BIN is set but not executable: ${GO_BIN}" >&2
        exit 1
    fi

    # Standard PATH.
    if command -v go >/dev/null 2>&1; then
        command -v go
        return 0
    fi

    # Common non-Homebrew locations.
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

compute_build_id_fallback() {
    # Deterministic fallback for source snapshots without git metadata.
    local digest_input
    digest_input="$(
        find "${DAEMON_SOURCE_DIR}" -type f -print | sort | while read -r f; do
            printf '%s\n' "${f#${PROJECT_ROOT}/}"
            shasum -a 256 "$f" | awk '{print $1}'
        done
    )"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "${digest_input}" | shasum -a 256 | awk '{print substr($1,1,12)}'
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "${digest_input}" | md5 | awk '{print substr($NF,1,12)}'
    else
        # Last resort: stable string length checksum.
        printf '%s' "${digest_input}" | cksum | awk '{print substr($1,1,12)}'
    fi
}

# =================================================================
# 1. ENVIRONMENT & ROOT RESOLUTION
# =================================================================
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

# =================================================================
# 2. DEFINE PATHS (Now that the environment is set)
# =================================================================
BUILD_OUTPUT_DIR="${PROJECT_ROOT}/build-go"
DAEMON_SOURCE_DIR="${PROJECT_ROOT}/cmd/powergrid-daemon"
HELPER_SOURCE_DIR="${PROJECT_ROOT}/cmd/powergrid-helper"
DAEMON_BUILDMETA_PATH="${BUILD_OUTPUT_DIR}/powergrid-daemon.buildmeta"

# =================================================================
# 3. BUILDING
# =================================================================
echo "--- Starting Go Compilation ---"
mkdir -p "${BUILD_OUTPUT_DIR}"

# Derive daemon BuildID from override, git, or deterministic fallback.
echo "--- Computing daemon BuildID ---"
BUILD_ID_SOURCE="${DAEMON_BUILD_SOURCE:-}"
BUILD_DIRTY="false"
DAEMON_BUILD_ID="${DAEMON_BUILD_ID:-}"

if [ -n "${DAEMON_BUILD_ID}" ]; then
    if [ -z "${BUILD_ID_SOURCE}" ]; then
        BUILD_ID_SOURCE="override"
    fi
elif command -v git >/dev/null 2>&1 && [ -d "${PROJECT_ROOT}/.git" ]; then
    DAEMON_BUILD_ID=$(git -C "${PROJECT_ROOT}" rev-parse --short=12 HEAD:cmd/powergrid-daemon || true)
    DIRTY_SUFFIX=""
    # Keep sandbox-friendly: check only build-relevant paths instead of repo-wide status.
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
    if [ -n "${DAEMON_BUILD_ID}" ]; then
        if [ -z "${BUILD_ID_SOURCE}" ]; then
            BUILD_ID_SOURCE="git"
        fi
    fi
fi

if [ -z "${DAEMON_BUILD_ID}" ]; then
    DAEMON_BUILD_ID="$(compute_build_id_fallback)-fallback"
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
if [[ "${DAEMON_BUILD_ID}" == *"-fallback" && -z "${DAEMON_BUILD_SOURCE:-}" ]]; then
    BUILD_ID_SOURCE="fallback"
fi

echo "Daemon BuildID: ${DAEMON_BUILD_ID} (source=${BUILD_ID_SOURCE}, dirty=${BUILD_DIRTY})"

# Build steps (stamp BuildID via ldflags)
echo "--- Building powergrid-daemon ---"
"${GO_BIN_RESOLVED}" build -ldflags "-X 'main.BuildID=${DAEMON_BUILD_ID}' -X 'main.BuildIDSource=${BUILD_ID_SOURCE}' -X 'main.BuildDirty=${BUILD_DIRTY}'" -o "${BUILD_OUTPUT_DIR}/powergrid-daemon" "${DAEMON_SOURCE_DIR}"

# Write sidecar BuildID file for the app bundle to read at runtime
echo "${DAEMON_BUILD_ID}" > "${BUILD_OUTPUT_DIR}/powergrid-daemon.buildid"
echo "Wrote sidecar: ${BUILD_OUTPUT_DIR}/powergrid-daemon.buildid"
cat > "${DAEMON_BUILDMETA_PATH}" <<EOF
build_id=${DAEMON_BUILD_ID}
build_id_source=${BUILD_ID_SOURCE}
build_dirty=${BUILD_DIRTY}
EOF
echo "Wrote sidecar: ${DAEMON_BUILDMETA_PATH}"

echo "--- Building powergrid-helper ---"
"${GO_BIN_RESOLVED}" build -o "${BUILD_OUTPUT_DIR}/powergrid-helper" "${HELPER_SOURCE_DIR}"

echo "✅ Go binaries built successfully."

# If invoked from Xcode, copy runtime artifacts into app Resources.
if [ -n "${SRCROOT:-}" ] && [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
    mkdir -p "${DEST_DIR}"

    cp "${BUILD_OUTPUT_DIR}/powergrid-daemon" "${DEST_DIR}/powergrid-daemon"
    cp "${BUILD_OUTPUT_DIR}/powergrid-helper" "${DEST_DIR}/powergrid-helper"
    cp "${BUILD_OUTPUT_DIR}/powergrid-daemon.buildid" "${DEST_DIR}/powergrid-daemon.buildid"
    cp "${PROJECT_ROOT}/install/com.neutronstar.powergrid.daemon.plist" "${DEST_DIR}/com.neutronstar.powergrid.daemon.plist"

    echo "✅ Copied daemon/helper/buildid/plist to app Resources: ${DEST_DIR}"
fi
