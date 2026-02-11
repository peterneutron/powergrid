# PowerGrid
<img alt="Main View" src="assets/powergrid.png" />

PowerGrid is a macOS power management project with two components:
- A privileged daemon (`powergrid-daemon`) that enforces power policy.
- A SwiftUI menu bar app (`PowerGrid.app`) that presents status and sends user-intent mutations.

## Status
PowerGrid is still experimental. Interfaces and internals can change.

## Architecture
- Daemon entrypoint: `cmd/powergrid-daemon`
- Daemon internals:
  - `internal/daemon/server` (RPC + orchestration)
  - `internal/daemon/engine` (decision logic)
  - `internal/daemon/session` (console-user preference profile)
  - `internal/daemon/ipc` (UNIX socket security + RPC auth interceptor)
- App entrypoint: `cmd/powergrid-app/PowerGrid/PowerGrid/PowerGridApp.swift`
- RPC schema: `proto/powergrid.proto`

## Security Model
- Daemon runs as root.
- IPC uses a UNIX socket at `/var/run/powergrid.sock` with restricted permissions (`0660`).
- Socket ownership remains `root`, and socket group is updated at runtime:
  - no active user: group reset to `root`
  - active console user: group set to that user's primary GID (so the app can open the socket)
- The daemon reads peer credentials and authorizes RPC calls by UID.
- Allowed callers for read/mutation RPCs:
  - root
  - active console user
- Mutating requests use one typed RPC envelope:
  - `ApplyMutation(MutationRequest)`
- Daemon diagnostics expose auth/build metadata through `GetDaemonInfo`:
  - `auth_mode`
  - `build_id_source` (`git`, `override`, `fallback`, `xcode-derived`, `unknown`)
  - `build_dirty`

## Runtime Behavior
- Event-driven first: battery/sleep/wake events come from `powerkit-go` streaming.
- Battery updates are coalesced/debounced to avoid redundant recomputation.
- A slower watchdog fallback periodically recomputes state.
- Hardware control operations are wrapped with bounded timeouts.
- Shutdown is context-driven and waits (bounded) for background goroutines.

## Features
- Charge limit (60-100) with per-user/system precedence.
- Force discharge.
- Prevent display/system sleep assertions.
- Optional MagSafe LED policy control (if supported).
- Optional disable-charging-before-sleep policy.
- Low Power Mode read/toggle.
- Live battery and adapter telemetry in the app.

## Configuration
Preferences are persisted as plist files.

- System daemon preferences:
  - `/Library/Preferences/com.neutronstar.powergrid.daemon.plist`
  - `ChargeLimit` (int, 60-100)

- Per-user preferences:
  - `~/Library/Preferences/com.neutronstar.powergrid.plist`
  - `ChargeLimit` (int, 60-100)
  - `ControlMagsafeLED` (bool)
  - `DisableChargingBeforeSleep` (bool)

## Build Prerequisites
- macOS (Apple Silicon target)
- Xcode + Command Line Tools
- XcodeGen (`xcodegen`)
- Go toolchain
- Protobuf toolchain available in `PATH`:
  - `protoc`
  - `protoc-gen-go`
  - `protoc-gen-go-grpc`
  - `protoc-gen-swift`
  - `protoc-gen-grpc-swift-2`
- Optional lint tool:
  - `golangci-lint`

## Build and Verify
From `powergrid/`:

- Generate Xcode project from source-of-truth spec:
  - `make xcodegen`
- Verify generated project is up to date:
  - `make xcodegen-check`

- Generate RPC code:
  - `make proto`
- Verify generated code is current:
  - `make proto-check`
- Run Go tests:
  - `make test`
- Run vet:
  - `make vet`
- Run lint:
  - `make lint`
- Run verify suite:
  - `make verify`
- Build unsigned app:
  - `make build`
- Build dev-signed app (free cert supported):
  - `make devsigned`

## Notes on Generated Code
Generated protobuf/gRPC code is produced into `generated/` and copied into the Swift app RPC folder by `make proto`.
Do not hand-edit generated files.

## Signing Notes
- Deterministic signing resolution is handled by `scripts/resolve-signing.sh`.
- Supported env overrides:
  - `SIGNING_IDENTITY`
  - `DEVELOPMENT_TEAM`
- Local signing overrides can be kept in:
  - `cmd/powergrid-app/PowerGrid/Config/Signing.local.xcconfig`
  - see `cmd/powergrid-app/PowerGrid/Config/Signing.local.xcconfig.example`

## Compatibility Policy
PowerGrid uses a two-layer contract:
- Layer 1 (primary): protocol compatibility via daemon-reported API semver (`api_major`, `api_minor`) from `GetDaemonInfo`.
- Layer 2 (secondary): BuildID + sidecar metadata for upgrade UX and diagnostics.

Semver gate rules:
- `api_major` mismatch: hard incompatible (app blocks mutating actions and shows install/upgrade path).
- `api_minor` below app minimum: incompatible/degraded path per app policy.
- `api_minor` at or above minimum (same major): compatible.

BuildID semantics (non-blocking for compatibility):
- clean BuildID mismatch: show "upgrade available".
- dirty/fallback/xcode-derived BuildIDs: warning/diagnostic path only.
- missing embedded BuildID sidecar: warn once; continue using semver gate.

## Xcode Sandbox Notes
- Script sandboxing remains enabled.
- `scripts/build-go.sh` is sandbox-safe by design in Xcode mode:
  - no `git` usage in Xcode mode,
  - deterministic `xcode-derived` BuildID,
  - outputs written to `${DERIVED_FILE_DIR}/powergrid-go`.
- Artifact staging into app resources is handled by Xcode script phases with declared `inputFiles`/`outputFiles` from `project.yml`.

Quick troubleshooting checklist:
- Run `make xcodegen` after changing `project.yml`.
- Ensure app bundle resources contain:
  - `powergrid-daemon`
  - `powergrid-helper`
  - `powergrid-daemon.buildid`
  - `com.neutronstar.powergrid.daemon.plist`
- If upgrade prompts look wrong, check daemon info first (`api_major`/`api_minor`) before BuildID comparisons.

## Logging
Daemon logs use macOS unified logging subsystem `com.neutronstar.powergrid.daemon`.

Example:
```bash
log stream --predicate 'subsystem == "com.neutronstar.powergrid.daemon"'
```

## Related Project
PowerGrid uses `powerkit-go` for low-level macOS power telemetry/control APIs.
