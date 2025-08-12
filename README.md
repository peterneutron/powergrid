# PowerGrid
<img width="688" height="760" alt="powergrid" src="https://github.com/user-attachments/assets/079dae0c-5cad-4221-86fd-d45b1ea450ee" />

PowerGrid is a macOS power management testbed composed of:
- A root daemon that monitors battery/adapter state and applies charge-limiting logic.
- A SwiftUI menu bar app that installs the daemon and provides controls and status.

> ⚠️ Experimental project
> 
> PowerGrid is a testbed, not a polished product. Interfaces and behaviors may change. If you need a production-ready tool, consider established alternatives.

## Components

- Daemon (`cmd/powergrid-daemon`):
  - Runs as root, exposes a gRPC API over a Unix socket at `/var/run/powergrid.sock`.
  - Applies effective charge limits (per-user override > system default > built-in default 80%).
  - Reacts to system events (sleep/wake/battery updates) via PowerKit-Go and SMC controls.
  - Tracks the active console user and persists per-user limits.
  - Writes daemon-owned config under `/Library/Application Support/com.neutronstar.powergrid/`.

- App (`cmd/powergrid-app/PowerGrid`):
  - macOS SwiftUI menu bar app that connects to the daemon and surfaces controls.
  - Installs the daemon via a bundled helper using AppleScript with admin privileges.
  - Shows live status and power metrics; lets you set the charge limit and toggle advanced options.

## App Features

- Menu bar status with icons for charge, charging state, and limiter active.
- Live status: current charge, charging/connected state, adapter description, health (%), cycle count.
- Power metrics: system, adapter, and battery wattage; adapter input voltage and amperage.
- Charge limit slider: 60–100% (step 10); 100% acts as “Off”.
- Advanced options:
  - Prevent Display Sleep (creates a display sleep assertion in-app).
  - Prevent System Sleep (creates a system sleep assertion; implied by display sleep).
  - Force Discharge (disables adapter power via SMC until toggled off).
- Installer flow if the daemon is missing, with progress and failure messages.

## Daemon Behavior

- Default charge limit: 80% (applied at first run and when no user is present).
- Safety-first transitions on user changes and sleep: clears assertions, ensures adapter is on, re-evaluates charging.
- Event-driven logic re-evaluates on battery updates and after wake.
- Unified logging to macOS Console (subsystem `com.neutronstar.powergrid.daemon`).

## Configuration Storage (Daemon-Owned)

Root-owned config lives under:
- Base: `/Library/Application Support/com.neutronstar.powergrid/`
- Files:
  - `system.json` — system default charge limit (created on first run if missing).
  - `users/<uid>.json` — per-user overrides written when a console user changes the limit.

JSON (simplified):
```json
{ "charge_limit": 80 }
```
- Limits are clamped to 60–100.
- Effective limit resolution: user > system > default(80).
- Legacy fallback: if a value is absent (0), the daemon can read legacy plists via `defaults`, but new writes go only to the daemon store.

## Installation (via App)

The app bundles a small helper (`cmd/powergrid-helper`) and uses AppleScript to run it with administrator privileges. The helper:
- Copies `powergrid-daemon` to `/usr/local/bin` (0755, root:wheel).
- Installs `com.neutronstar.powergrid.daemon.plist` to `/Library/LaunchDaemons` (0644, root:wheel).
- Unloads any existing service, then `launchctl load` the new plist.

The app detects install state and attempts to connect to `/var/run/powergrid.sock` after installation.

## Development

Prereqs: macOS, Xcode (for the Swift app), Go toolchain (for daemon/helper), and protoc plugins if editing `.proto`.

- Build daemon/helper (Go):
```bash
go build ./cmd/powergrid-daemon
go build ./cmd/powergrid-helper
```

- Run daemon directly (dev only; requires root):
```bash
sudo -E go run ./cmd/powergrid-daemon
```

- Build/run the app (Swift):
  - Open `cmd/powergrid-app/PowerGrid/PowerGrid.xcodeproj` in Xcode and run.
  - For installer testing, ensure the app bundle’s Resources include `powergrid-daemon` and `com.neutronstar.powergrid.daemon.plist`.

- Generate protobufs (after editing `proto/*.proto`):
```bash
./scripts/gen_proto.sh
```

Notes:
- On first daemon start, `system.json` is created with 80% if missing and not overwritten later.
- When no console user is present, SetChargeLimit does not persist and the daemon applies the built-in default in-memory.

## gRPC API

- Socket: `/var/run/powergrid.sock`
- See `proto/powergrid.proto` and generated code under `generated/go`.
- RPCs:
  - `GetStatus` — current charge, adapter details, health/cycles, power metrics, and feature flags.
  - `SetChargeLimit(limit)` — validates 60–100; persists per-user when a console user is present.
  - `SetPowerFeature` — toggles assertions and adapter power (display/system sleep, force discharge).

## Logging & Observability

- Subsystem: `com.neutronstar.powergrid.daemon`
- View: Console.app or `log stream --predicate 'subsystem == "com.neutronstar.powergrid.daemon"'`

## Security & Privileges

- The daemon must run as root to control charging/adapter via SMC.
- Config under `/Library/Application Support/com.neutronstar.powergrid/` is root-owned; UIs configure via gRPC.
- No secrets are stored in the repo; any local env is for development only.

## Roadmap

- Expose console user and effective-limit source to UIs.
- Admin RPC/CLI to manage `system.json` safely.
- Hardening: permissions, error reporting, and backoff on failures.

## Acknowledgments

- Built on [PowerKit-Go](https://github.com/peterneutron/powerkit-go) for IOKit/SMC access and event streaming.
