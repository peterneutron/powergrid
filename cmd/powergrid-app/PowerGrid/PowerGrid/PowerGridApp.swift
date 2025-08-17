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
                        // Compute “paused” first (1% hysteresis + low-trickle detection)
                        let charge     = Int(status.currentCharge)
                        let limit      = Int(status.chargeLimit)
                        let nearLimit  = charge >= max(limit - 1, 0)            // avoid flicker around edge
                        let trickleish = abs(status.batteryWattage) < 0.5       // maintenance trickle
                        let pausedAtLimit = status.isConnected && limit < 100 &&
                                            ( nearLimit
                                              || (!status.isCharging && charge >= limit)
                                              || (nearLimit && trickleish) )

                        // Choose one primary icon based on that state
                        let primaryIcon = pausedAtLimit
                            ? "shield.lefthalf.filled"
                            : (status.isCharging ? "bolt.fill" : "bolt.slash.fill")

                        Text("\(status.currentCharge)%")
                        Image(systemName: primaryIcon)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(status: status)
            Divider()
            ControlsView(client: client)
            Divider()
            
            // --- NEW LAYOUT ---
            // 1. Add our new Quick Actions grid.
            QuickActionsView(client: client)
            
            // 2. Add our new side-by-side footer.
            FooterActionsView(client: client)
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
    // We now observe the whole client to access userIntent.
    @ObservedObject var client: DaemonClient
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                // Read directly from the user's intent.
                Text("Charge Limit: \(client.userIntent.chargeLimit)%")
                Spacer()
                // The offBinding now correctly uses the client's intent.
                Toggle(isOn: offBinding()) { Text("Off:") }
                    .toggleStyle(.checkbox)
            }
            // This Slider now uses a custom binding to bridge the Double/Int gap
            // and read/write directly to the userIntent.
            Slider(value: chargeLimitBinding(), in: 60...100, step: 5) {
                // onEditingChanged is used to send the RPC call ONLY when the user is done.
            } onEditingChanged: { isEditing in
                if !isEditing {
                    Task {
                        await client.setLimit(client.userIntent.chargeLimit)
                    }
                }
            }
        }
    }
}

extension ControlsView {
    // This helper creates a Binding<Double> from our client's userIntent.chargeLimit (Int).
    private func chargeLimitBinding() -> Binding<Double> {
        Binding<Double>(
            get: { Double(client.userIntent.chargeLimit) },
            set: { client.userIntent.chargeLimit = Int($0) }
        )
    }
    
    // The logic here is now simpler, as it just manipulates the userIntent.
    // The RPC call is handled separately by the Slider's onEditingChanged.
    func offBinding() -> Binding<Bool> {
        Binding<Bool>(
            get: { client.userIntent.chargeLimit >= 100 },
            set: { isChecked in
                let newLimit = isChecked ? 100 : 80
                client.userIntent.chargeLimit = newLimit
                // Immediately send the update when the checkbox is used.
                Task {
                    await client.setLimit(newLimit)
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

// A new view to hold the grid of Quick Action buttons.
struct QuickActionsView: View {
    @ObservedObject var client: DaemonClient
    
    // For now, we use dummy @State variables to make the buttons interactive.
    // Later, these will be replaced with bindings to your client.userIntent.
    @State private var forceDischarge = false
    @State private var preventDisplaySleep = false
    @State private var preventSystemSleep = false
    @State private var ecoMode = false // A good placeholder for a fourth action

    var body: some View {
        // A flexible grid that automatically spaces the 4 buttons.
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 16) {
            QuickActionButton(systemImage: "battery.100.bolt.slash", title: "Discharge", isOn: $forceDischarge)
            QuickActionButton(systemImage: "display", title: "Display", isOn: $preventDisplaySleep)
            QuickActionButton(systemImage: "powersleep", title: "Sleep", isOn: $preventSystemSleep)
            QuickActionButton(systemImage: "leaf.fill", title: "Eco Mode", isOn: $ecoMode)
        }
        .padding(.vertical, 4) // Adds a little vertical breathing room.
    }
}

// A new footer that arranges the Advanced Options and Quit button side-by-side.
struct FooterActionsView: View {
    @ObservedObject var client: DaemonClient
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.bottom, 8)

            HStack {
                Menu("Advanced Options") {
                    // All the previous options from FooterView go here.
                    Toggle("Prevent Display Sleep", isOn: $client.userIntent.preventDisplaySleep)
                        .onChange(of: client.userIntent.preventDisplaySleep) { _, newValue in
                            Task { await client.setPowerFeature(feature: .preventDisplaySleep, enable: newValue) }
                        }
                    
                    VStack(alignment: .leading) {
                        Toggle("Prevent System Sleep", isOn: $client.userIntent.preventSystemSleep)
                            .disabled(client.userIntent.preventDisplaySleep)
                            .onChange(of: client.userIntent.preventSystemSleep) { _, newValue in
                                Task { await client.setPowerFeature(feature: .preventSystemSleep, enable: newValue) }
                            }
                        if client.userIntent.preventDisplaySleep {
                            Text("Display sleep prevention implies system sleep prevention.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    
                    Toggle("Force Discharge", isOn: $client.userIntent.forceDischarge)
                        .onChange(of: client.userIntent.forceDischarge) { _, newValue in
                            Task { await client.setPowerFeature(feature: .forceDischarge, enable: newValue) }
                        }
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        Task.detached(priority: .userInitiated) {
                            await client.uninstallDaemon()
                            await MainActor.run { NSApplication.shared.terminate(nil) }
                        }
                    } label: {
                        Text("Uninstall Daemon").foregroundColor(.red)
                    }
                    
                    Button("View Daemon Logs in Console...") {
                        guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else { return }
                        let config = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.openApplication(at: consoleURL, configuration: config)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: .infinity, alignment: .leading) // This makes it take up the 2/3 space.

                Button("Quit") {
                    Task { await MainActor.run { NSApplication.shared.terminate(nil) } }
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
