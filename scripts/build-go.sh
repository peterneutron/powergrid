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

# Build steps
echo "--- Building powergrid-daemon ---"
go build -o "${BUILD_OUTPUT_DIR}/powergrid-daemon" "${DAEMON_SOURCE_DIR}"

echo "--- Building powergrid-helper ---"
go build -o "${BUILD_OUTPUT_DIR}/powergrid-helper" "${HELPER_SOURCE_DIR}"

echo "✅ Go binaries built successfully."