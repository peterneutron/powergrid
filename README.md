# PowerGrid

A macOS power management testbed: a root daemon plus example apps that monitor and control charging using the PowerKit-Go library. PowerGrid resolves effective charge limits per user, applies safety actions on state changes, and exposes a gRPC API for UIs.

> ⚠️ Attention: Testbed Project
> 
> PowerGrid is an experimental testbed, not a polished product. Interfaces and behaviors may change. If you need a production-ready solution, consider established alternatives listed below. We’ll keep this section updated as we evaluate options.

## Features

- Console-user awareness: detects the active GUI user via `/dev/console` without cgo.
- Per-user charge limits: effective limit = user override > system default > built-in default (80%).
- Daemon-owned config store: JSON under `/Library/Application Support/com.neutronstar.powergrid/`.
- Safety-first transitions: on user changes and wake/sleep, clears app-local assertions and ensures adapter is on before re-evaluating charging.
- Event-driven logic: integrates PowerKit-Go’s IOKit event stream and SMC controls.
- gRPC service: Unix domain socket at `/var/run/powergrid.sock` for UI clients (e.g., `powergrid-app`).
- Structured logging: macOS unified logging via subsystem `com.neutronstar.powergrid.daemon`.

## Repository Layout

- `cmd/`
  - `powergrid-daemon`: root-only daemon exposing the gRPC API and managing charging.
  - `powergrid-app`: example UI app (for development/testing).
  - `powergrid-helper`: auxiliary binary (reserved for future use).
- `internal/`
  - `consoleuser`: console user resolver (Username, UID, HomeDir) using `/dev/console`.
  - `config`: daemon store + legacy defaults readers; effective limit computation.
  - `oslogger`: wrapper over macOS unified logging.
- `generated/go`: gRPC generated code from `proto/`.
- `proto/`: service and message definitions.
- `scripts/`: build and proto generation scripts.

## Config Storage (Daemon-Owned)

Primary configuration is stored by the daemon under:
- Base directory: `/Library/Application Support/com.neutronstar.powergrid/`
- Files:
  - `system.json` — system default charge limit, created at first run if missing.
  - `users/<uid>.json` — per-user overrides, persisted when a console user calls SetChargeLimit.

JSON schema:
```json
{ "charge_limit": 80 }
```
- Limits are clamped to 40–100.
- Effective limit resolution: user > system > default(80).
- Legacy fallback: if a store value is absent (0), the daemon can read legacy plists via `defaults` as a fallback, but new writes go to the daemon store only.

## Running (Development)

- Build all (Go):
```bash
cd powergrid && go build ./...
```
- Run the daemon (requires root):
```bash
cd powergrid
sudo -E go run ./cmd/powergrid-daemon
```
- Run the example app:
```bash
cd powergrid
go run ./cmd/powergrid-app
```
- Generate protobufs (when editing .proto):
```bash
cd powergrid && ./scripts/gen_proto.sh
```

Notes:
- On first daemon start, `system.json` is created with the built-in default (80%) if missing; it is not overwritten thereafter.
- SetChargeLimit persists per-user limits when a console user is present. If no user is logged in, the daemon applies the built-in default (80%) in-memory without persisting.

## gRPC API

- Socket: `/var/run/powergrid.sock`
- Service: see `proto/` definitions and generated code in `generated/go`.
- Key RPCs:
  - `GetStatus`: consolidated status for UI (charge, adapter, flags, etc.).
  - `SetChargeLimit(limit)`: validates 40–100; persists per-user when a console user is present; otherwise applies daemon default.
  - `SetPowerFeature`: toggles app-local assertions and adapter state (display/system sleep prevention, force discharge).

## Logging & Observability

- Subsystem: `com.neutronstar.powergrid.daemon`
- View in Console.app, or via `log stream --predicate 'subsystem == "com.neutronstar.powergrid.daemon"'`.
- Logs include effective limit application and source (user/system/default).

## Security & Privileges

- The daemon must run as root to control SMC charging and adapter state.
- Configuration files under `/Library/Application Support/com.neutronstar.powergrid/` are owned by root; UIs interact via gRPC rather than direct file writes.
- No secrets are stored; `.env` (if used) lives under `powergrid/` for local development only.

## Development & Testing

- Build:
```bash
cd powergrid && go build ./...
```
- Tests:
```bash
cd powergrid && go test ./...
```
- Coverage example:
```bash
cd powergrid && go test ./... -coverprofile=cover.out && go tool cover -html=cover.out
```

## Roadmap

- Expose console user and effective-limit source to UIs.
- Optional admin path to manage `system.json` via RPC/CLI.
- Per-user “safety reset” flags for GUI notifications.
- Hardening: ownership/permissions tuning, richer error reporting, and backoff on failures.

## Alternatives

> Placeholder — We will list and link established alternatives here for users seeking a production-ready tool. Suggestions welcome.

## Acknowledgments

- Built atop [PowerKit-Go](https://github.com/peterneutron/powerkit-go) for IOKit/SMC access and event streaming.

