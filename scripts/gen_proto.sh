#
# =================================================================
# GENERATES THE GRPC CODE
# =================================================================

# Fail fast on any error
set -e

echo "--- Preparing to Generate gRPC Code ---"

# =================================================================
# 1. ENVIRONMENT & PATH SETUP 
# =================================================================
if [ -n "$SRCROOT" ]; then
    echo "🔨 Xcode environment detected. Setting up Homebrew and protoc"

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

    # Load Homebrew's environment. This correctly sets the PATH.
    eval "$(${HB_PREFIX}/bin/brew shellenv)"

    # Verify we can now see ‘protoc’
    if ! command -v protoc &> /dev/null; then
        echo "❌ ERROR: 'protoc' not found. Please run 'brew install protobuf'." >&2
        exit 1
    fi
    echo "✅ Environment configured. Using protoc from: $(command -v protoc)"

    # Compute project root relative to Xcode’s SRCROOT
    PROJECT_ROOT="${SRCROOT}/../../.."
    echo "Using SRCROOT: $SRCROOT (Project Root: $PROJECT_ROOT)"
else
    echo "🖥 Manual execution detected. Skipping Homebrew setup."
    
    # Compute project root relative to script file
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    PROJECT_ROOT="${SCRIPT_DIR}/.."
    echo "Calculated Project Root: $PROJECT_ROOT"
fi

# =================================================================
# 2. DEFINE PATHS (Now that the environment is set)
# =================================================================
SWIFT_PLUGIN_PATH="/opt/homebrew/bin/protoc-gen-swift"
GRPC_SWIFT_PLUGIN_PATH="/opt/homebrew/bin/protoc-gen-grpc-swift-2"

PROTO_FILE="${PROJECT_ROOT}/proto/powergrid.proto"
GO_OUT_DIR="${PROJECT_ROOT}/generated/go"
SWIFT_OUT_DIR="${PROJECT_ROOT}/cmd/powergrid-app/PowerGrid/PowerGrid/internal/rpc"

# =================================================================
# 3. PROTOCOL COMPILATION (Using explicit plugin paths)
# =================================================================
echo "--- Starting Protocol Buffer Compilation ---"

# Always create the Swift output directory
mkdir -p "${SWIFT_OUT_DIR}"

# Start building the command with common arguments
PROTOC_ARGS=(
    "--proto_path=${PROJECT_ROOT}/proto"

    # Swift Flags
    "--plugin=protoc-gen-swift=${SWIFT_PLUGIN_PATH}"
    "--plugin=protoc-gen-grpc-swift=${GRPC_SWIFT_PLUGIN_PATH}"
    "--swift_out=${SWIFT_OUT_DIR}"
    "--swift_opt=Visibility=Public"
    "--grpc-swift_out=${SWIFT_OUT_DIR}"
    "--grpc-swift_opt=Visibility=Public"
)

# --- Conditional Part ---
# If SRCROOT is NOT set (i.e., this is a manual run), add the Go flags.
if [ -z "$SRCROOT" ]; then
    echo "--- Adding Go generation flags for manual run ---"
    # Create the Go output directory
    mkdir -p "${GO_OUT_DIR}"

    # Add Go flags to our arguments array
    PROTOC_ARGS+=(
        "--go_out=${GO_OUT_DIR}" "--go_opt=paths=source_relative"
        "--go-grpc_out=${GO_OUT_DIR}" "--go-grpc_opt=paths=source_relative"
    )
fi

# Add the final proto file to be compiled
PROTOC_ARGS+=("${PROTO_FILE}")

# Execute the command with all the accumulated arguments
protoc "${PROTOC_ARGS[@]}"

echo "✅ gRPC code generated successfully."