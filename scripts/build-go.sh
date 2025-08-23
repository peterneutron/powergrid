#
# =================================================================
# BUILDS THE GO BINARIES
# =================================================================

set -e

echo "--- Building Go Binaries ---"

# =================================================================
# 1. ENVIRONMENT & PATH SETUP
# =================================================================
if [ -n "$SRCROOT" ]; then
    echo "🔨 Xcode environment detected. Setting up Homebrew and Go…"

    #
    # ——————— Homebrew Environment Setup ———————
    #
    echo "--- Setting up Homebrew Environment ---"
    if [ -x /opt/homebrew/bin/brew ]; then
        HB_PREFIX=/opt/homebrew
    elif [ -x /usr/local/bin/brew ]; then
        HB_PREFIX=/usr/local
    else
        echo "❌ ERROR: Homebrew not found." >&2
        exit 1
    fi

    eval "$(${HB_PREFIX}/bin/brew shellenv)"

    if ! command -v go &> /dev/null; then
        echo "❌ ERROR: 'go' not found. Please run 'brew install go'." >&2
        exit 1
    fi
    echo "✅ Homebrew environment configured. Using 'go' from: $(command -v go)"

    PROJECT_ROOT="${SRCROOT}/../../.."
    echo "Using SRCROOT: $SRCROOT (Project Root: $PROJECT_ROOT)"
else
    echo "🖥 Manual execution detected. Skipping Homebrew setup."

    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    PROJECT_ROOT="${SCRIPT_DIR}/.."
    echo "Calculated Project Root: $PROJECT_ROOT"
fi

# =================================================================
# 2. DEFINE PATHS (Now that the environment is set)
# =================================================================
BUILD_OUTPUT_DIR="${PROJECT_ROOT}/build-go"
DAEMON_SOURCE_DIR="${PROJECT_ROOT}/cmd/powergrid-daemon"
HELPER_SOURCE_DIR="${PROJECT_ROOT}/cmd/powergrid-helper"

# =================================================================
# 3. BUILDING
# =================================================================
echo "--- Starting Go Compilation ---"
mkdir -p "${BUILD_OUTPUT_DIR}"

# Derive daemon BuildID from git tree for cmd/powergrid-daemon, with repository-wide dirty flag
echo "--- Computing daemon BuildID (git) ---"
if command -v git >/dev/null 2>&1; then
    DAEMON_BUILD_ID=$(git -C "${PROJECT_ROOT}" rev-parse --short=12 HEAD:cmd/powergrid-daemon || true)
    # Mark as dirty if repository has any changes (whole tree), using porcelain to avoid non-zero exits with set -e
    DIRTY_SUFFIX=""
    STATUS=$(git -C "${PROJECT_ROOT}" status --porcelain || true)
    if [ -n "$STATUS" ]; then DIRTY_SUFFIX="-dirty"; fi
    DAEMON_BUILD_ID="${DAEMON_BUILD_ID}${DIRTY_SUFFIX}"
fi
if [ -z "${DAEMON_BUILD_ID}" ]; then
    echo "❌ ERROR: Unable to compute daemon BuildID from git. Ensure this is a git checkout." >&2
    exit 1
fi
echo "Daemon BuildID: ${DAEMON_BUILD_ID}"

# Build steps (stamp BuildID via ldflags)
echo "--- Building powergrid-daemon ---"
go build -ldflags "-X 'main.BuildID=${DAEMON_BUILD_ID}'" -o "${BUILD_OUTPUT_DIR}/powergrid-daemon" "${DAEMON_SOURCE_DIR}"

# Write sidecar BuildID file for the app bundle to read at runtime
echo "${DAEMON_BUILD_ID}" > "${BUILD_OUTPUT_DIR}/powergrid-daemon.buildid"
echo "Wrote sidecar: ${BUILD_OUTPUT_DIR}/powergrid-daemon.buildid"

echo "--- Building powergrid-helper ---"
go build -o "${BUILD_OUTPUT_DIR}/powergrid-helper" "${HELPER_SOURCE_DIR}"

echo "✅ Go binaries built successfully."

# If invoked from Xcode, also copy the sidecar into the built app's Resources
# if [ -n "$SRCROOT" ] && [ -n "$TARGET_BUILD_DIR" ] && [ -n "$UNLOCALIZED_RESOURCES_FOLDER_PATH" ]; then
#   DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
#   mkdir -p "$DEST_DIR"
#   cp "${BUILD_OUTPUT_DIR}/powergrid-daemon.buildid" "$DEST_DIR/"
#   echo "✅ Copied powergrid-daemon.buildid to app Resources: $DEST_DIR"
# fi
