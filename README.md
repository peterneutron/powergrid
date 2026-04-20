# PowerGrid
<img alt="Main View" src="assets/powergrid.png" />

PowerGrid is a macOS power management project built around a privileged daemon, a menu bar app, and a daemon-backed CLI.

## Scope

Use PowerGrid when you need:

- a persistent charge limit enforced by a root daemon
- force discharge and sleep-assertion controls
- Low Power Mode and optional MagSafe LED control
- a native menu bar app for live battery and adapter status
- a local CLI that talks to the daemon instead of bypassing it

## Components

- `powergrid-daemon`: root daemon that enforces power policy
- `PowerGrid.app`: SwiftUI menu bar app
- `powergridctl`: local CLI client for the daemon

## Build

```bash
make build
```

## Verify

```bash
make verify
```

Common local targets:

- `make xcodegen`
- `make proto`
- `make swift-test`
- `make build`

`make proto` will build and cache the pinned gRPC Swift generator automatically on first use.

## Docs

Keep the README short. Detailed material lives elsewhere:

- [Contract and Architecture](docs/contracts.md)
- [Release Process](docs/release.md)
- [Agent Instructions](AGENTS.md)

## Runtime Notes

- daemon socket: `/var/run/powergrid.sock`
- per-user preferences: `~/Library/Preferences/com.neutronstar.powergrid.plist`
- system daemon preferences: `/Library/Preferences/com.neutronstar.powergrid.daemon.plist`

## Safety

PowerGrid changes hardware power behavior through a privileged daemon. Treat mutations as system-level operations and prefer daemon-mediated control paths over direct tooling.
