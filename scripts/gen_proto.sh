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

PROTOC_PATH="${PROTOC_PATH:-$(command -v protoc || true)}"
SWIFT_PLUGIN_PATH="${SWIFT_PLUGIN_PATH:-$(command -v protoc-gen-swift || true)}"
GRPC_SWIFT_PLUGIN_PATH="${GRPC_SWIFT_PLUGIN_PATH:-$(command -v protoc-gen-grpc-swift-2 || true)}"

PROTO_FILE="${PROJECT_ROOT}/proto/powergrid.proto"
GO_OUT_DIR="${PROJECT_ROOT}/generated/go"
SWIFT_OUT_DIR="${PROJECT_ROOT}/generated/swift" # New temporary location

if [ -z "$PROTOC_PATH" ] || [ ! -x "$PROTOC_PATH" ]; then
    echo "❌ ERROR: protoc not found. Set PROTOC_PATH or add it to PATH." >&2
    exit 1
fi

if [ -z "$SWIFT_PLUGIN_PATH" ] || [ ! -x "$SWIFT_PLUGIN_PATH" ]; then
    echo "❌ ERROR: protoc-gen-swift not found. Set SWIFT_PLUGIN_PATH or add it to PATH." >&2
    exit 1
fi

if [ -z "$GRPC_SWIFT_PLUGIN_PATH" ] || [ ! -x "$GRPC_SWIFT_PLUGIN_PATH" ]; then
    echo "❌ ERROR: protoc-gen-grpc-swift-2 not found. Set GRPC_SWIFT_PLUGIN_PATH or add it to PATH." >&2
    exit 1
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

echo "✅ gRPC code generated successfully into ./generated directory."
