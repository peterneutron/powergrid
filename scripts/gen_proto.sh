#!/bin/bash

# =================================================================
# GENERATES GRPC/PROTOBUF CODE FOR GO AND SWIFT
#
# This script is now context-agnostic. It always generates both
# Go and Swift files into a top-level './generated' directory.
# The Makefile is responsible for copying files where they need to go.
# =================================================================

# Fail fast on any error
set -e

echo "--- Generating gRPC Code ---"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."
PLUGIN_RESOLVER_SCRIPT="${PROJECT_ROOT}/scripts/ensure-grpc-swift-plugin.sh"

PROTOC_PATH="${PROTOC_PATH:-$(command -v protoc || true)}"
SWIFT_PLUGIN_PATH="${SWIFT_PLUGIN_PATH:-$(command -v protoc-gen-swift || true)}"
REQUIRED_GRPC_SWIFT_PLUGIN_VERSION_PREFIX="${REQUIRED_GRPC_SWIFT_PLUGIN_VERSION_PREFIX:-}"
if [ -n "${GRPC_SWIFT_PLUGIN_PATH:-}" ]; then
    true
elif [ -x "${PLUGIN_RESOLVER_SCRIPT}" ]; then
    GRPC_SWIFT_PLUGIN_PATH="$("${PLUGIN_RESOLVER_SCRIPT}")"
elif command -v protoc-gen-grpc-swift-2 >/dev/null 2>&1; then
    GRPC_SWIFT_PLUGIN_PATH="$(command -v protoc-gen-grpc-swift-2)"
elif command -v protoc-gen-grpc-swift >/dev/null 2>&1; then
    GRPC_SWIFT_PLUGIN_PATH="$(command -v protoc-gen-grpc-swift)"
else
    GRPC_SWIFT_PLUGIN_PATH=""
fi

PROTO_FILE="${PROJECT_ROOT}/proto/powergrid.proto"
GO_OUT_DIR="${PROJECT_ROOT}/internal/rpc"
SWIFT_OUT_DIR="${PROJECT_ROOT}/generated/swift" # New temporary location
MANIFEST_PATH="${PROJECT_ROOT}/generated/proto.manifest"
SWIFT_TARGET_DIR="${PROJECT_ROOT}/cmd/powergrid-app/PowerGrid/PowerGrid/internal/rpc"

sha_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

if [ -z "$PROTOC_PATH" ] || [ ! -x "$PROTOC_PATH" ]; then
    echo "❌ ERROR: protoc not found. Set PROTOC_PATH or add it to PATH." >&2
    exit 1
fi

if [ -z "$SWIFT_PLUGIN_PATH" ] || [ ! -x "$SWIFT_PLUGIN_PATH" ]; then
    echo "❌ ERROR: protoc-gen-swift not found. Set SWIFT_PLUGIN_PATH or add it to PATH." >&2
    exit 1
fi

if [ -z "$GRPC_SWIFT_PLUGIN_PATH" ] || [ ! -x "$GRPC_SWIFT_PLUGIN_PATH" ]; then
    echo "❌ ERROR: protoc-gen-grpc-swift(-2) not found. Set GRPC_SWIFT_PLUGIN_PATH or add plugin binary to PATH." >&2
    exit 1
fi

if [ -n "${REQUIRED_GRPC_SWIFT_PLUGIN_VERSION_PREFIX}" ]; then
    GRPC_SWIFT_PLUGIN_VERSION="$("$GRPC_SWIFT_PLUGIN_PATH" --version 2>/dev/null | awk '{print $2}')"
    if [ -z "$GRPC_SWIFT_PLUGIN_VERSION" ]; then
        echo "❌ ERROR: Unable to determine protoc-gen-grpc-swift(-2) version from $GRPC_SWIFT_PLUGIN_PATH." >&2
        exit 1
    fi

    case "$GRPC_SWIFT_PLUGIN_VERSION" in
        "${REQUIRED_GRPC_SWIFT_PLUGIN_VERSION_PREFIX}"*)
            ;;
        *)
            echo "❌ ERROR: protoc-gen-grpc-swift(-2) version ${GRPC_SWIFT_PLUGIN_VERSION} is incompatible. Expected ${REQUIRED_GRPC_SWIFT_PLUGIN_VERSION_PREFIX}x." >&2
            exit 1
            ;;
    esac
fi

mkdir -p "${GO_OUT_DIR}"
mkdir -p "${SWIFT_OUT_DIR}"

echo "Compiling ${PROTO_FILE} for Go and Swift..."

"$PROTOC_PATH" \
    --proto_path="${PROJECT_ROOT}/proto" \
    --go_out="${GO_OUT_DIR}" --go_opt=paths=source_relative \
    --go-grpc_out="${GO_OUT_DIR}" --go-grpc_opt=paths=source_relative \
    --plugin="protoc-gen-swift=${SWIFT_PLUGIN_PATH}" \
    --plugin="protoc-gen-grpc-swift=${GRPC_SWIFT_PLUGIN_PATH}" \
    --swift_out="${SWIFT_OUT_DIR}" \
    --swift_opt=Visibility=Public \
    --grpc-swift_out="${SWIFT_OUT_DIR}" \
    --grpc-swift_opt=Visibility=Public \
    "$PROTO_FILE"

mkdir -p "${SWIFT_TARGET_DIR}"
cp "${SWIFT_OUT_DIR}"/*.swift "${SWIFT_TARGET_DIR}/"

cat > "${MANIFEST_PATH}" <<EOF
PROTO_SHA256=$(sha_file "${PROTO_FILE}")
GEN_SCRIPT_SHA256=$(sha_file "${PROJECT_ROOT}/scripts/gen_proto.sh")
GO_PB_SHA256=$(sha_file "${GO_OUT_DIR}/powergrid.pb.go")
GO_GRPC_SHA256=$(sha_file "${GO_OUT_DIR}/powergrid_grpc.pb.go")
SWIFT_PB_SHA256=$(sha_file "${SWIFT_OUT_DIR}/powergrid.pb.swift")
SWIFT_GRPC_SHA256=$(sha_file "${SWIFT_OUT_DIR}/powergrid.grpc.swift")
EOF

echo "✅ gRPC code generated successfully into ./generated directory."
