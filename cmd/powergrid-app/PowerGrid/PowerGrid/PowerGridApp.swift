//
//  PowerGridApp.swift
//  PowerGrid
//
//
//
// File: PowerGridApp.swift
import SwiftUI

@main
struct PowerGridApp: App {
    // Creates a single, stable instance of our client for the app's lifecycle.
    @StateObject private var client = DaemonClient()
    
    // A timer to periodically refresh the status from the daemon.
    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some Scene {
        MenuBarExtra {
            // The view that appears when you click the menu bar icon.
            AppMenuView(client: client)
                // Fetch status whenever the timer fires, but only if connected.
                .onReceive(timer) { _ in
                    guard client.connectionState == .connected else { return }
                    Task {
                        await client.fetchStatus()
                    }
                }
                // Attempt to connect immediately on launch to determine installer state.
                
        } label: {
            // The view for the menu bar icon itself.
            MenuBarLabelView(client: client)
                .task {
                    client.connect()
                    await client.fetchStatus()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

// A dedicated view for the menu bar label.
struct MenuBarLabelView: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
        // Use an HStack for reliable layout of text and images in the menu bar.
        HStack(spacing: 2) {
            switch client.installerState {
            case .notInstalled, .failed:
                Text("PG")
                Image(systemName: "questionmark.circle")
            case .installing:
                Text("PG")
                Image(systemName: "arrow.triangle.2.circlepath")
            case .uninstalling:
                Text("PG")
                Image(systemName: "arrow.triangle.2.circlepath")
            case .installed:
                // Once installed, revert to showing connection status.
                switch client.connectionState {
                case .connected:
                    if let status = client.status {
                        let chargeIcon = status.isCharging ? "bolt.fill" : "bolt.slash.fill"
                        
                        Text("\(status.currentCharge)%")
                        Image(systemName: chargeIcon)
                        
                        if status.isConnected && !status.isCharging && status.currentCharge >= status.chargeLimit && status.chargeLimit < 100 {
                            // If we are paused at the limit, show the shield icon.
                            Image(systemName: "shield.lefthalf.filled")
                        }
                    } else {
                        Text("PG")
                        Image(systemName: "ellipsis") // Waiting for status
                    }
                case .disconnected:
                    Text("PG")
                    Image(systemName: "xmark.circle")
                case .connecting:
                    Text("PG")
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            case .unknown:
                Text("PG")
                Image(systemName: "hourglass")
            }
        }
    }
}

// The main view for the dropdown menu.
struct AppMenuView: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Switch the entire view based on the installer state.
            switch client.installerState {
            case .unknown:
                ProgressView { Text("Checking daemon status...") }
            
            case .installing:
                ProgressView { Text("Installing daemon...") }
            
            case .uninstalling:
                ProgressView { Text("Uninstalling daemon...") }
                
            case .notInstalled, .failed:
                // Show the dedicated installation view.
                InstallationView(client: client)
                
            case .installed:
                // When installed, show the main controls view.
                // We still need to handle connection state here.
                if client.connectionState == .connected, let status = client.status {
                    MainControlsView(client: client, status: status)
                } else {
                    // This covers the case where it's installed but the daemon isn't reachable.
                    VStack {
                        Text("PowerGrid Daemon Not Responding")
                            .font(.headline)
                            .padding(.bottom, 4)
                        Text("The helper daemon is installed but the app can't connect. It may be starting up, or may have been stopped manually.")
                            .font(.caption)
                        Button("Quit App") { NSApplication.shared.terminate(nil) }
                            .padding(.top)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320) // Give the menu a fixed width
    }
}

// --- Subviews for Readability ---

// NEW: A dedicated view for the installation UI.
struct InstallationView: View {
    @ObservedObject var client: DaemonClient
    
    var body: some View {
        VStack(spacing: 12) {
            Text("PowerGrid Daemon Required")
                .font(.title2).bold()
            
            Text("To manage your Mac's charging, PowerGrid needs to install a small helper daemon that runs in the background as root.")
                .font(.callout)
            
            if case .failed(let errorMessage) = client.installerState {
                Text("Installation Failed: \(errorMessage)")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            Button("Install Daemon") {
                Task {
                    await client.installDaemon()
                }
            }
            .buttonStyle(.borderedProminent)
            
            Divider()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}


// The original main view, now refactored.
struct MainControlsView: View {
    @ObservedObject var client: DaemonClient
    let status: Rpc_StatusResponse
    @State private var sliderValue: Double
    
    // Advanced options (now driven by daemon status flags)

    // Initialize the slider value from the daemon's actual status.
    init(client: DaemonClient, status: Rpc_StatusResponse) {
        self.client = client
        self.status = status
        _sliderValue = State(initialValue: Double(status.chargeLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(status: status)
            Divider()
            ControlsView(sliderValue: $sliderValue, client: client)
            Divider()
            FooterView(client: client, status: status)
        }
        .onAppear {
            // Re-sync the slider with the actual limit from the daemon whenever the view appears.
            self.sliderValue = Double(client.status?.chargeLimit ?? 80)
        }
    }
}


struct HeaderView: View {
    let status: Rpc_StatusResponse
    
    /// A computed property to determine the correct status text based on multiple conditions.
    private var computedStatusText: String {
        // PRIORITY 1 (NEW): The most specific edge case.
        // Are we connected and charging, but ALREADY ABOVE the limit?
        // This means we are waiting for the system to discharge to the new, lower limit.
        if status.isConnected && status.isCharging && status.currentCharge > status.chargeLimit && status.chargeLimit < 100 {
            return "404 - Limiter not found!"
        }
        
        // PRIORITY 2: Are we paused exactly at the limit?
        // This is the normal, stable "at limit" state.
        if status.isConnected && !status.isCharging && status.currentCharge >= status.chargeLimit && status.chargeLimit < 100 {
            return "Paused at \(status.chargeLimit)%"
        }
        
        // PRIORITY 3: Is the device actively charging towards the limit?
        // This is the standard "charging in progress" state.
        if status.isCharging {
            return "Charging to \(status.chargeLimit)%"
        }
        
        // PRIORITY 4: Is the device plugged in and effectively full?
        // This handles the case where the limit is 100% and we've reached it.
        if status.isConnected && status.currentCharge >= 99 {
            return "Fully Charged"
        }
        
        // PRIORITY 5 (Fallback): If none of the above, it's not charging (e.g., unplugged).
        return "Not Charging"
    }
    
    var body: some View {
        // Title left, Charge on the right (Health/Cycles moved below)
        HStack(alignment: .firstTextBaseline) {
            Text("PowerGrid").font(.title).bold()
            Spacer()
            HStack(spacing: 4) {
                Text("Charge:")
                Text("\(status.currentCharge)%")
                    .foregroundColor(chargeColor())
                    .monospacedDigit()
            }
            .font(.title3).bold()
        }
        
        // This VStack now contains the main status and our new HStacks.
        VStack(alignment: .leading, spacing: 8) {
            // First row of info
            HStack(alignment: .top) {
                // THE FIX: Use our new computed property here.
                Text("Status: \(computedStatusText)")
                
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Health: \(status.healthByMax)%")
                    Text("Cycles: \(status.cycleCount)")
                }
            }
            
            Divider().padding(.vertical, 2)
            
            // Second row: left shows adapter description + Voltage/Amperage (stacked), right keeps metrics.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    let adapterText = status.isConnected
                        ? (status.adapterDescription.isEmpty ? "Unknown Adapter" : status.adapterDescription)
                        : "Not connected"
                    Text("Adapter: \(adapterText)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Align values and unit symbols in a 3-column grid: Label | Value | Unit
                    Grid(alignment: .leading, horizontalSpacing: 6) {
                        GridRow {
                            Text("Voltage:")
                            Text(formatSigned(status.adapterInputVoltage))
                                .monospacedDigit()
                                .foregroundColor(status.adapterInputVoltage >= 0 ? .green : .red)
                                .gridColumnAlignment(.trailing)
                            Text("V").foregroundColor(.primary)
                        }
                        GridRow {
                            Text("Amperage:")
                            Text(formatSigned(status.adapterInputAmperage))
                                .monospacedDigit()
                                .foregroundColor(status.adapterInputAmperage >= 0 ? .green : .red)
                                .gridColumnAlignment(.trailing)
                            Text("A").foregroundColor(.primary)
                        }
                    }
                }

                Spacer()

                PowerMetricsView(status: status)
            }
        }
        .font(.caption)
    }

    private func formatSigned(_ value: Float) -> String {
        String(format: "%+.2f", value)
    }

    private func chargeColor() -> Color {
        let charge = Int(status.currentCharge)
        let limit = Int(status.chargeLimit)
        if charge <= 10 { return .red }
        if charge <= 20 { return .orange }
        if charge >= limit { return .green }
        return .primary
    }
}

struct ControlsView: View {
    @Binding var sliderValue: Double
    @ObservedObject var client: DaemonClient
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Charge Limit: \(Int(sliderValue))%")
                Spacer()
                Toggle(isOn: offBinding()) { Text("Off:") }
                    .toggleStyle(.checkbox)
            }
            Slider(value: $sliderValue, in: 60...100, step: 10) { isEditing in
                // This closure is called when the user finishes dragging the slider.
                if !isEditing {
                    // Call our helper function to handle the async task.
                    updateChargeLimit()
                }
            }
        }
    }
    
    // By moving the logic into a separate function, we help the Swift
    // compiler correctly resolve the call to the async 'setLimit' method.
    // This is the definitive fix for the errors you are seeing.
    private func updateChargeLimit() {
        Task {
            await client.setLimit(Int(sliderValue))
        }
    }
}

extension ControlsView {
    // True when slider is at 100%; setting adjusts slider and persists immediately.
    func offBinding() -> Binding<Bool> {
        Binding<Bool>(
            get: { Int(sliderValue) >= 100 },
            set: { newVal in
                Task {
                    if newVal {
                        sliderValue = 100
                        await client.setLimit(100)
                    } else {
                        let newLimit = 80
                        sliderValue = Double(newLimit)
                        await client.setLimit(newLimit)
                    }
                }
            }
        )
    }
}

// This new, dedicated view handles the display of all wattage metrics.
struct PowerMetricsView: View {
    let status: Rpc_StatusResponse

    var body: some View {
        // A Grid is the perfect tool for aligning columns of text.
        // Use three columns: Label | Value | Unit with tight spacing.
        Grid(alignment: .leading, horizontalSpacing: 6) {
            // Row 1: System Wattage
            GridRow {
                Text("System:")
                Text(formatWattage(status.systemWattage, showSign: false))
                    .monospacedDigit()
                    .gridColumnAlignment(.trailing)
                Text("W").foregroundColor(.primary)
            }

            // Row 2: Adapter Wattage
            GridRow {
                Text("Adapter:")
                Text(formatWattage(status.adapterWattage, showSign: true))
                    .monospacedDigit()
                    .foregroundColor(.green) // Color only the numeric value
                    .gridColumnAlignment(.trailing)
                Text("W").foregroundColor(.primary)
            }

            // Row 3: Battery Wattage
            GridRow {
                Text("Battery:")
                Text(formatWattage(status.batteryWattage, showSign: true))
                    .monospacedDigit()
                    .foregroundColor(status.batteryWattage >= 0 ? .green : .red) // Color only the numeric value
                    .gridColumnAlignment(.trailing)
                Text("W").foregroundColor(.primary)
            }
        }
    }

    /// Formats wattage value with optional sign and one decimal place (no unit).
    private func formatWattage(_ value: Float, showSign: Bool) -> String {
        let formatString = showSign ? "%+.1f" : "%.1f"
        return String(format: formatString, value)
    }
}

// Advanced options menu integrated with daemon features
struct FooterView: View {
    @ObservedObject var client: DaemonClient
    let status: Rpc_StatusResponse

    @State private var preventDisplaySleep: Bool
    @State private var preventSystemSleep: Bool
    @State private var forceDischarge: Bool

    init(client: DaemonClient, status: Rpc_StatusResponse) {
        self.client = client
        self.status = status
        _preventDisplaySleep = State(initialValue: status.preventDisplaySleepActive)
        _preventSystemSleep = State(initialValue: status.preventSystemSleepActive)
        // Reflect ground truth: checked when adapter is disabled
        _forceDischarge = State(initialValue: !status.smcAdapterEnabled)
    }

    var body: some View {
        Divider()
        Menu("Advanced Options") {
            Toggle("Prevent Display Sleep", isOn: $preventDisplaySleep)
                .onChange(of: preventDisplaySleep) { _, newValue in
                    Task { await client.setPowerFeature(feature: .preventDisplaySleep, enable: newValue) }
                }

            // Group the toggle and its helper text for clarity
            VStack(alignment: .leading) {
                Toggle("Prevent System Sleep", isOn: $preventSystemSleep)
                    .disabled(preventDisplaySleep) // This modifier is sufficient to grey out the view
                    .onChange(of: preventSystemSleep) { _, newValue in
                        Task { await client.setPowerFeature(feature: .preventSystemSleep, enable: newValue) }
                    }

                if preventDisplaySleep {
                    Text("Display sleep prevention implies system sleep prevention.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Force Discharge", isOn: $forceDischarge)
                .onChange(of: forceDischarge) { _, newValue in
                    Task { await client.setPowerFeature(feature: .forceDischarge, enable: newValue) }
                }

            Divider()
            
            // Add the Uninstall button with a detached task to ensure it runs.
            Button("Uninstall Daemon", role: .destructive) {
                Task.detached(priority: .userInitiated) {
                    await client.uninstallDaemon()
                    // Terminate the app on the main thread for safety.
                    await MainActor.run {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            
            Button("View Daemon Logs in Console...") {
                guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: consoleURL, configuration: configuration) { _, _ in }
            }
        }
        
        // Move the .onChange modifiers here, to the root view ---
        .onChange(of: client.status?.preventDisplaySleepActive) { _, newVal in
            preventDisplaySleep = newVal ?? false
        }
        .onChange(of: client.status?.preventSystemSleepActive) { _, newVal in
            preventSystemSleep = newVal ?? false
        }
        .onChange(of: client.status?.smcAdapterEnabled) { _, newVal in
            forceDischarge = !(newVal ?? true)
        }

        Divider()
        
        Button("Quit PowerGrid") { NSApplication.shared.terminate(nil) }
    }
}
