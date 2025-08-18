# PowerGrid
<img alt="Main View" src="assets/powergrid.png" />

---

PowerGrid is a macOS power management tool composed of:
- A root daemon that monitors battery/adapter state and applies charge-limiting logic.
- A SwiftUI menu bar app that installs the daemon and provides controls and status.

> ⚠️ Experimental project
> 
> PowerGrid is a testbed, not a polished product. Interfaces and behaviors may change. If you need a production-ready tool, consider established alternatives. Some noteworthy ones are listed below.
>
> - [batt](https://github.com/charlie0129/batt)
> - [battery](https://github.com/actuallymentor/battery)


## Features

- Menu bar status with icons for charge, charging state, and limiter active.
- Control Center-Inspired Toggles: A grid of beautiful, macOS-style buttons provides immediate, one-click access to essential power management functions like Force Discharge and Prevent Display Sleep.
- Live status: current charge, adapter description, health (%), cycle count.
- Power metrics: system, adapter, and battery wattage; adapter input voltage and amperage.
- Charge limit slider from 60–100%.
- Advanced options: Prevent Display/System Sleep, Force Discharge.
- Installer flow to install/uninstall the helper daemon with administrator privileges.

## Getting Started: Building from Source

This project uses a `Makefile` to automate the build process.

#### 1. Prerequisites

- macOS with Xcode installed.
- Go toolchain.
- Homebrew for installing protobuf dependencies:
  ```bash
  brew install protobuf swift-protobuf grpc-swift
  ```

#### 2. One-Time Setup in Xcode

Before you can build from the command line, you need to configure code signing once in Xcode.

1.  Open `PowerGrid.xcodeproj` in Xcode.
2.  In the project navigator, select the "PowerGrid" project, then the "PowerGrid" target.
3.  Go to the **"Signing & Capabilities"** tab.
4.  From the **"Team"** dropdown, select your personal Apple ID. Xcode will automatically create a local development certificate for you.
5.  You can now close Xcode.

#### 3. Build the App

From the root of the project directory, run the main `make` command:

```bash
make
```
This command will:
- Generate the necessary gRPC Swift and Go code.
- Copy the Swift files into the Xcode project.
- Build and archive the application.
- Export a clean, runnable `PowerGrid.app` into a `./build` directory.

You can now run the app from the `./build` folder.

## Development Workflow

The `Makefile` provides several targets to streamline development:

- `make`: The default command. Creates a final, optimized `.app` bundle in the `./build` directory.
- `make proto`: Run this after editing `proto/powergrid.proto` to regenerate the gRPC code for both Swift and Go.
- `make clean`: Removes all build artifacts and generated code to start fresh.
- `sudo -E go run ./cmd/powergrid-daemon`: Run the daemon directly for debugging (requires root).

## How It Works

- **Daemon (`cmd/powergrid-daemon`):** Runs as root, exposing a gRPC API over a Unix socket at `/var/run/powergrid.sock`. It reacts to system power events, tracks the active user, and persists their charge limit preferences.
- **App (`PowerGrid.xcodeproj`):** A SwiftUI menu bar app that communicates with the daemon. It bundles a helper tool to manage the installation and uninstallation of the daemon and its `launchd` service.

## Configuration

The daemon stores its configuration under `/Library/Application Support/com.neutronstar.powergrid/`. It uses a user > system > default hierarchy to determine the effective charge limit.
- `system.json`: System-wide default charge limit.
- `users/<uid>.json`: Per-user overrides.

## Logging

All daemon activity is logged to the macOS Unified Logging system. You can view logs using Console.app or the command line:
```bash
log stream --predicate 'subsystem == "com.neutronstar.powergrid.daemon"'
```

## Acknowledgments

- Built on [PowerKit-Go](https://github.com/peterneutron/powerkit-go) for IOKit/SMC access and event streaming.
- Google Gemini and OpenAI GPT families of models and all the labs involved making these possible 🙏
