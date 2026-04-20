#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="${SCRIPT_DIR}/.."
PACKAGE_RESOLVED="${PROJECT_ROOT}/cmd/powergrid-app/PowerGrid/PowerGrid.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CACHE_ROOT="${GRPC_SWIFT_PLUGIN_CACHE_DIR:-${HOME}/Library/Caches/powergrid/grpc-swift-plugin}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "❌ ERROR: ${PYTHON_BIN} not found. Install Python 3 or set PYTHON_BIN." >&2
    exit 1
fi

if [ ! -f "${PACKAGE_RESOLVED}" ]; then
    echo "❌ ERROR: ${PACKAGE_RESOLVED} not found. Resolve Swift packages first." >&2
    exit 1
fi

while IFS=$'\t' read -r identity location version revision; do
    case "${identity}" in
        grpc-swift-protobuf)
            grpc_swift_protobuf_location="${location}"
            grpc_swift_protobuf_version="${version}"
            ;;
        grpc-swift-2)
            grpc_swift_2_location="${location}"
            grpc_swift_2_version="${version}"
            grpc_swift_2_revision="${revision}"
            ;;
        swift-protobuf)
            swift_protobuf_location="${location}"
            swift_protobuf_version="${version}"
            swift_protobuf_revision="${revision}"
            ;;
        swift-collections)
            swift_collections_location="${location}"
            swift_collections_version="${version}"
            swift_collections_revision="${revision}"
            ;;
    esac
done < <("${PYTHON_BIN}" - "${PACKAGE_RESOLVED}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

pins = {pin["identity"]: pin for pin in data["pins"]}
required = [
    "grpc-swift-protobuf",
    "grpc-swift-2",
    "swift-protobuf",
    "swift-collections",
]

for identity in required:
    pin = pins.get(identity)
    if pin is None:
        raise SystemExit(f"missing pin for {identity}")

    state = pin["state"]
    print("\t".join([
        identity,
        pin["location"],
        state["version"],
        state["revision"],
    ]))
PY
)

cache_key="${grpc_swift_protobuf_version}-${grpc_swift_2_version}-${swift_protobuf_version}-${swift_collections_version}"
plugin_root="${CACHE_ROOT}/${cache_key}"
plugin_dir="${plugin_root}/src"
plugin_bin="${plugin_root}/bin/protoc-gen-grpc-swift-2"

if [ -x "${plugin_bin}" ]; then
    installed_version="$("${plugin_bin}" --version 2>/dev/null | awk '{print $2}')"
    if [ "${installed_version}" = "${grpc_swift_protobuf_version}" ]; then
        printf '%s\n' "${plugin_bin}"
        exit 0
    fi
fi

tmp_root="${plugin_root}.tmp.$$"
trap 'rm -rf "${tmp_root}"' EXIT
rm -rf "${tmp_root}"
mkdir -p "${tmp_root}/bin"

git clone --depth 1 --branch "${grpc_swift_protobuf_version}" "${grpc_swift_protobuf_location}" "${tmp_root}/src" >/dev/null 2>&1

cat > "${tmp_root}/src/Package.resolved" <<EOF
{
  "pins" : [
    {
      "identity" : "grpc-swift-2",
      "kind" : "remoteSourceControl",
      "location" : "${grpc_swift_2_location}",
      "state" : {
        "revision" : "${grpc_swift_2_revision}",
        "version" : "${grpc_swift_2_version}"
      }
    },
    {
      "identity" : "swift-collections",
      "kind" : "remoteSourceControl",
      "location" : "${swift_collections_location}",
      "state" : {
        "revision" : "${swift_collections_revision}",
        "version" : "${swift_collections_version}"
      }
    },
    {
      "identity" : "swift-protobuf",
      "kind" : "remoteSourceControl",
      "location" : "${swift_protobuf_location}",
      "state" : {
        "revision" : "${swift_protobuf_revision}",
        "version" : "${swift_protobuf_version}"
      }
    }
  ],
  "version" : 3
}
EOF

swift build --package-path "${tmp_root}/src" -c release --product protoc-gen-grpc-swift-2 >/dev/null
install -m 0755 "${tmp_root}/src/.build/release/protoc-gen-grpc-swift-2" "${tmp_root}/bin/protoc-gen-grpc-swift-2"

rm -rf "${plugin_root}"
mkdir -p "${CACHE_ROOT}"
mv "${tmp_root}" "${plugin_root}"
trap - EXIT

printf '%s\n' "${plugin_bin}"
