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
- Time estimates: Time to Full (while charging) or Time to Empty (while discharging), formatted hh:mm. Time to Full automatically scales to your active charge limit when <100% and hides when full/at limit/paused.
- Power metrics: system, adapter, and battery wattage; adapter input voltage and amperage.
- Charge limit slider from 60–100%.
- Power Assertions: Prevent Display/System Sleep.
- Force Discharge: Discharges even when an adapter is present; only selectable if an adapter is present.
- Force Discharge Automatic: Discharges to your limit, then auto-disables; only selectable above limit.
- Native Notifications: Alerts for key events (e.g., cutoff), single permission prompt.
- Low Power Notifications: Alerts at 20% and 10% while discharging; includes an action button to enable macOS Low Power Mode when off.
- Advanced Battery Details: When enabled in Advanced Options, shows additional battery information below the power metrics.
  - Serial Number, Design/Maximum/Nominal Capacity (mAh)
  - Battery Voltage (V), Battery Current (A), Temperature (°C)
  - Individual Cell Voltages (V) and a Drift indicator: Normal (green), Slight (yellow), High (red)
- Disable Charging Before Sleep: Configurable in Advanced Options and persisted per user by the daemon. When enabled, the daemon proactively disables charging on system sleep.
- MagSafe LED Control: When enabled in Advanced Options (and supported by hardware), the daemon reflects charging modes on the MagSafe LED.
  - Charging (limit off or below limit): Amber
  - Fully charged or at/above user limit: Green
  - Force Discharge: Off
  - Low battery (≤10%): Amber blinking
  - Safe default: when disabled or on startup, LED is returned to System control
- Developer submenu: In dirty builds, Advanced Options shows a "Developer" submenu with short forms of both BuildIDs and tooltips with full hashes.

## Getting Started: Building from Source

This project uses a `Makefile` to automate the build process.

#### 1. Prerequisites

- macOS with Xcode (26+ recommended) installed.
- Go toolchain.
- Homebrew for installing protobuf dependencies:
  ```bash
  brew install protobuf swift-protobuf protoc-gen-grpc-swift
  ```
- Clone the repository:
  ```bash
  git clone https://github.com/peterneutron/powergrid.git
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

Notes on version pairing and build artifacts:
- During the build, the daemon is compiled with an ldflags-stamped `BuildID` and a sidecar file `powergrid-daemon.buildid` is produced and bundled into the app. This avoids coupling hashes to code signing.
- The app compares its embedded `BuildID` to the daemon's `GetVersion` response on first connection to decide if an upgrade prompt is needed.

You can now run the app from the `./build` folder.

## Development Workflow

The `Makefile` provides several targets to streamline development:

- `make`: The default command. Creates a final, optimized `.app` bundle in the `./build` directory.
- `make proto`: Run this after editing `proto/powergrid.proto` to regenerate the gRPC code for both Swift and Go.
- `make clean`: Removes all build artifacts and generated code to start fresh.
- `sudo -E go run ./cmd/powergrid-daemon`: Run the daemon directly for debugging (requires root).


## Configuration

PowerGrid uses standard macOS preferences (CFPreferences / `defaults`) and a simple precedence: user > system > built‑in default.

- System (daemon): `/Library/Preferences/com.neutronstar.powergrid.daemon.plist`
  - `ChargeLimit` (int, 60–100): System charge limit used when no user is active or user has no override.

- Per‑user (daemon/app): `~/Library/Preferences/com.neutronstar.powergrid.plist`
  - `ChargeLimit` (int, 60–100): User override for effective charge limit.
  - `ControlMagsafeLED` (bool): When true (and supported), daemon controls MagSafe LED state.
  - `DisableChargingBeforeSleep` (bool, default true): When true, daemon proactively disables charging on system sleep.

- App UI (UserDefaults in the app domain):
  - `menuBarDisplayStyle`, `preferredChargeLimit`, `lowPowerNotificationsEnabled`, `showBatteryDetails`.
  - These are UI-only and do not affect the daemon directly (except via RPC calls when you change settings in the app).

Notes:
- Low Power Mode (macOS) is not persisted by PowerGrid; the daemon reads the current state via `pmset -g` and toggles it via `pmset -a` when requested.

## Logging

All daemon activity is logged to the macOS Unified Logging system. You can view logs using Console.app or the command line:
```bash
log stream --predicate 'subsystem == "com.neutronstar.powergrid.daemon"'
```

## Acknowledgments

- Built on [PowerKit-Go](https://github.com/peterneutron/powerkit-go) for IOKit/SMC access and event streaming.
- Google Gemini and OpenAI GPT families of models and all the labs involved making these possible 🙏
