# Contract and Architecture

This document holds the durable architecture, compatibility, and operational detail for PowerGrid.

## Architecture

PowerGrid has three main components:

- privileged daemon: `cmd/powergrid-daemon`
- menu bar app: `cmd/powergrid-app/PowerGrid/PowerGrid/PowerGridApp.swift`
- local CLI: `cmd/powergridctl`

Core daemon packages:

- `internal/daemon/server`: RPC handlers and orchestration
- `internal/daemon/engine`: charge and LED decision logic
- `internal/daemon/session`: console-user preference transitions
- `internal/daemon/ipc`: socket bootstrap and authorization

RPC and generated code:

- schema: `proto/powergrid.proto`
- generated Go stubs: `internal/rpc`
- generated Swift files copied into the app: `cmd/powergrid-app/PowerGrid/PowerGrid/internal/rpc`

## Security Model

- daemon runs as root
- socket path: `/var/run/powergrid.sock`
- socket target mode: `0660`
- socket owner: root
- socket group:
  - root when no console user is active
  - active console user primary group when a user is logged in
- authorized callers:
  - root
  - active console user

All state changes flow through:

- `ApplyMutation(MutationRequest)`

## Compatibility Model

PowerGrid uses a two-layer compatibility model:

1. protocol semver via `GetDaemonInfo`
2. build ID for diagnostics and upgrade UX

Protocol rules:

- `api_major` mismatch: incompatible
- insufficient `api_minor`: degraded or blocked
- same major plus sufficient minor: compatible

`GetDaemonInfo` also exposes:

- `auth_mode`
- `build_id_source`
- `build_dirty`

## Runtime Behavior

- event-driven first: battery, sleep, and wake stream from `powerkit-go`
- debounced battery-update coalescing reduces redundant recompute
- watchdog fallback periodically recomputes state
- hardware operations are bounded by timeouts

## Features

- charge limit control with user and system preference precedence
- force discharge
- prevent display sleep and prevent system sleep
- optional MagSafe LED control
- optional disable-charging-before-sleep policy
- Low Power Mode read and toggle
- daemon-backed CLI controls
- live battery and adapter telemetry in the app

## CLI

When PowerGrid is installed through the helper, `powergridctl` is installed to:

- `/usr/local/bin/powergridctl`

Examples:

```bash
powergridctl status
powergridctl limit 80
powergridctl limit off
powergridctl lowpower on
powergridctl sleep display
powergridctl discharge on
```

## Configuration

System daemon preferences:

- `/Library/Preferences/com.neutronstar.powergrid.daemon.plist`
- `ChargeLimit` (`int`, `60-100`)

Per-user preferences:

- `~/Library/Preferences/com.neutronstar.powergrid.plist`
- `ChargeLimit` (`int`, `60-100`)
- `ControlMagsafeLED` (`bool`)
- `DisableChargingBeforeSleep` (`bool`)

## Build and Tooling

Prerequisites:

- macOS
- Xcode plus Command Line Tools
- XcodeGen
- Go toolchain
- protobuf toolchain:
  - `protoc`
  - `protoc-gen-go`
  - `protoc-gen-go-grpc`
  - `protoc-gen-swift`
- optional local lint tool:
  - `golangci-lint`

The repo builds and caches its pinned `protoc-gen-grpc-swift-2` automatically via
`scripts/ensure-grpc-swift-plugin.sh`, using the app's checked-in Swift package graph.

PowerGrid app and tests are Apple Silicon only:

- `ARCHS = arm64`
- `EXCLUDED_ARCHS[sdk=macosx*] = x86_64`

## Generated Code Policy

Do not hand-edit generated protobuf or gRPC artifacts.

Sources of truth:

- `proto/powergrid.proto`
- `scripts/gen_proto.sh`

Generated artifacts:

- Go: `internal/rpc/powergrid.pb.go`, `internal/rpc/powergrid_grpc.pb.go`
- Swift: under `generated/swift` and `cmd/powergrid-app/PowerGrid/PowerGrid/internal/rpc`

Integrity checks:

- `scripts/proto-check.sh`
- `generated/proto.manifest`

## Signing and Xcode Notes

- deterministic signing resolution: `scripts/resolve-signing.sh`
- supported env overrides:
  - `SIGNING_IDENTITY`
  - `DEVELOPMENT_TEAM`
- local signing override template:
  - `cmd/powergrid-app/PowerGrid/Config/Signing.local.xcconfig.example`

Xcode sandboxing remains enabled. `scripts/build-go.sh` is expected to remain sandbox-safe in Xcode mode.

## Logging

Daemon logs use subsystem:

- `com.neutronstar.powergrid.daemon`

```bash
log stream --predicate 'subsystem == "com.neutronstar.powergrid.daemon"'
```

## Related Project

PowerGrid depends on `powerkit-go` for low-level telemetry and control. The pinned version lives in `go.mod`.
