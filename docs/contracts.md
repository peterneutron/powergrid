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

Current protocol version: `1.3`. Version `1.3` adds charge-limit backend and
range fields to `StatusResponse`.

`GetDaemonInfo` also exposes:

- `auth_mode`
- `build_id_source`
- `build_dirty`

## Runtime Behavior

- event-driven first: battery, sleep, and wake stream from `powerkit-go`
- debounced battery-update coalescing reduces redundant recompute
- watchdog fallback periodically recomputes state
- hardware operations are bounded by timeouts
- charge-limit backend availability is part of daemon state; unavailable charge control is not treated as active charge limiting

## Features

- charge limit control with user and system preference precedence, when a writable backend is available
- force discharge
- prevent display sleep and prevent system sleep
- optional MagSafe LED control
- optional disable-charging-before-sleep policy
- Low Power Mode read and toggle
- daemon-backed CLI controls
- live battery and adapter telemetry in the app
- optional hardware battery percentage display and charge-limit enforcement from raw smart-battery telemetry

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
- `UseHardwareBatteryPercentage` (`bool`)

`ChargeLimit` remains a PowerGrid policy value. It does not guarantee that the
current macOS build exposes a writable low-level charging control for every
configured value.

## Battery Control Availability

PowerGrid depends on `powerkit-go` for low-level battery telemetry and control.
The daemon treats charge-limit backend and SMC control state as
capability-sensitive:

- `StatusResponse.charge_limit_backend` selects `native_macos`, `smc_inhibit`,
  or `unavailable`.
- `charge_limit_min_percent`, `charge_limit_max_percent`,
  `charge_limit_step_percent`, and `charge_limit_allowed_percents` drive app and
  CLI validation.
- `native_macos`: write limits through `powerkit.SetChargeLimit`; skip the SMC
  inhibition loop and SMC disable-before-sleep hook.
- `smc_inhibit`: keep the existing PowerGrid enforcement loop using
  `powerkit.SetChargingState`.

- `SMC.State.ChargingControlAvailable=false`: skip charge-limit enforcement
  writes, report `is_charge_limited=false`, and avoid UI text that implies
  PowerGrid paused charging.
- `SMC.State.AdapterControlAvailable=false`: do not report force discharge as
  active merely because adapter state is unknown.
- Missing SMC state defaults to enabled in user-facing status to avoid
  presenting unavailable data as an active inhibit.

This is especially important on macOS 27.0 Developer Beta 2, where the observed
modern SMC charge-control key `CHTE` and legacy keys `BCLM`, `BCDS`, and `CH0B`
were unavailable, while adapter control through `CHIE` still read back.

## macOS Native Charge Limit Findings

macOS 27 exposes a native manual charge-limit feature through private PowerUI
surfaces. Investigation on macOS 27.0 Developer Beta 2 found:

- `PowerUISmartChargeClient` was callable from an unentitled process for basic
  reads and accepted allowed manual charge limits.
- `availableChargeLimitsWithError:` returned `80, 85, 90, 95, 100`.
- `setMCLLimit:error:` accepted `85` and restored `80`, but rejected `60` with
  `PowerUISmartChargingErrorDomain Code=4`.
- `temporarilyOverrideMCLTargetSoC:error:` also rejected `60` with the same
  error.
- `PowerUIChargingController` looked lower-level, but direct token registration
  and `setChargeLimitTo:forLimitType:` calls returned no usable token / false
  from an unentitled user process.
- Direct `IOPSCopyBatteryLevelLimits` / `IOPSLimitBatteryLevel*` calls are
  gated by Apple private entitlements such as `com.apple.private.iokit.soc-limit`.
- SMC and IORegistry sweeps did not reveal an obvious replacement key that
  tracks native target changes below Apple's `80%` floor.

PowerGrid integrates this through `powerkit-go` as the `native_macos`
charge-limit backend. The app limits the slider to the backend-reported range
and allowed values, currently `80, 85, 90, 95, 100` when the PowerUI probe
succeeds.

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
