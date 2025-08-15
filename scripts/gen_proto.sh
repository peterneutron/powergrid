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

# --- Define Paths ---
# Get the project root directory (the parent of the 'scripts' directory)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."

# Define explicit paths for protoc and plugins for reliability
PROTOC_PATH="/opt/homebrew/bin/protoc"
SWIFT_PLUGIN_PATH="/opt/homebrew/bin/protoc-gen-swift"
GRPC_SWIFT_PLUGIN_PATH="/opt/homebrew/bin/protoc-gen-grpc-swift-2"

# Define source and output directories
PROTO_FILE="${PROJECT_ROOT}/proto/powergrid.proto"
GO_OUT_DIR="${PROJECT_ROOT}/generated/go"
SWIFT_OUT_DIR="${PROJECT_ROOT}/generated/swift" # New temporary location

# Verify the core protoc binary exists
if [ ! -x "$PROTOC_PATH" ]; then
    echo "❌ ERROR: protoc not found at ${PROTOC_PATH}. Please run 'brew install protobuf'." >&2
    exit 1
fi

# Create all output directories
mkdir -p "${GO_OUT_DIR}"
mkdir -p "${SWIFT_OUT_DIR}"

# --- Execute protoc ---
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

echo "✅ gRPC code generated successfully into ./generated directory."