#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."
MANIFEST="${PROJECT_ROOT}/generated/proto.manifest"
GO_DIR="${PROJECT_ROOT}/generated/go"
SWIFT_GEN_DIR="${PROJECT_ROOT}/generated/swift"
SWIFT_APP_DIR="${PROJECT_ROOT}/cmd/powergrid-app/PowerGrid/PowerGrid/internal/rpc"

sha_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "error: missing required file: $1" >&2
    exit 1
  fi
}

require_file "$MANIFEST"
require_file "${GO_DIR}/powergrid.pb.go"
require_file "${GO_DIR}/powergrid_grpc.pb.go"
require_file "${SWIFT_GEN_DIR}/powergrid.pb.swift"
require_file "${SWIFT_GEN_DIR}/powergrid.grpc.swift"
require_file "${SWIFT_APP_DIR}/powergrid.pb.swift"
require_file "${SWIFT_APP_DIR}/powergrid.grpc.swift"

# shellcheck disable=SC1090
source "$MANIFEST"

expect_match() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: ${label} hash mismatch." >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    echo "Run 'make proto' to regenerate." >&2
    exit 1
  fi
}

expect_match "proto file" "$(sha_file "${PROJECT_ROOT}/proto/powergrid.proto")" "${PROTO_SHA256}"
expect_match "gen script" "$(sha_file "${PROJECT_ROOT}/scripts/gen_proto.sh")" "${GEN_SCRIPT_SHA256}"
expect_match "go pb" "$(sha_file "${GO_DIR}/powergrid.pb.go")" "${GO_PB_SHA256}"
expect_match "go grpc" "$(sha_file "${GO_DIR}/powergrid_grpc.pb.go")" "${GO_GRPC_SHA256}"
expect_match "swift pb generated" "$(sha_file "${SWIFT_GEN_DIR}/powergrid.pb.swift")" "${SWIFT_PB_SHA256}"
expect_match "swift grpc generated" "$(sha_file "${SWIFT_GEN_DIR}/powergrid.grpc.swift")" "${SWIFT_GRPC_SHA256}"
expect_match "swift pb app copy" "$(sha_file "${SWIFT_APP_DIR}/powergrid.pb.swift")" "${SWIFT_PB_SHA256}"
expect_match "swift grpc app copy" "$(sha_file "${SWIFT_APP_DIR}/powergrid.grpc.swift")" "${SWIFT_GRPC_SHA256}"

echo "✅ Proto outputs and copies are up to date."
