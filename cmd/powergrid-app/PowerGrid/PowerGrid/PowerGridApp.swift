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
    @StateObject private var client = DaemonClient()
    
    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some Scene {
        MenuBarExtra {
            AppMenuView(client: client)
                .onReceive(timer) { _ in
                    guard client.connectionState == .connected else { return }
                    Task {
                        await client.fetchStatus()
                    }
                }
                
        } label: {
            MenuBarLabelView(client: client)
                .task {
                    client.connect()
                    await client.fetchStatus()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabelView: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
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
                switch client.connectionState {
                case .connected:
                    if let status = client.status {
                        switch client.userIntent.menuBarDisplayStyle {
                        case .iconAndText:
                            StatusTextLabel(status: status)
                            StatusIconLabel(status: status)
                        case .iconOnly:
                            StatusIconLabel(status: status)
                        case .textOnly:
                            StatusTextLabel(status: status)
                        }
                    } else {
                        Text("PG")
                        Image(systemName: "ellipsis")
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

private struct StatusTextLabel: View {
    let status: Rpc_StatusResponse
    var body: some View {
        Text("\(Int(status.currentCharge))%")
    }
}

private struct StatusIconLabel: View {
    let status: Rpc_StatusResponse

    private var primaryIconName: String {
        let charge     = Int(status.currentCharge)
        let limit      = Int(status.chargeLimit)
        let nearLimit  = charge >= max(limit - 1, 0)
        let trickleish = abs(status.batteryWattage) < 0.5
        let pausedAtLimit = status.isConnected && limit < 100 &&
                            ( nearLimit
                              || (!status.isCharging && charge >= limit)
                              || (nearLimit && trickleish) )

        return pausedAtLimit
            ? "shield.lefthalf.filled"
            : (status.isCharging ? "bolt.fill" : "bolt.slash.fill")
    }

    var body: some View {
        Image(systemName: primaryIconName)
    }
}

struct AppMenuView: View {
    @ObservedObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch client.installerState {
            case .unknown:
                ProgressView { Text("Checking daemon status...") }
            
            case .installing:
                ProgressView { Text("Installing daemon...") }
            
            case .uninstalling:
                ProgressView { Text("Uninstalling daemon...") }
                
            case .notInstalled, .failed:
                InstallationView(client: client)
                
            case .installed:
                if client.connectionState == .connected, let status = client.status {
                    MainControlsView(client: client, status: status)
                } else {
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
        .frame(width: 320)
    }
}

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


struct MainControlsView: View {
    @ObservedObject var client: DaemonClient
    let status: Rpc_StatusResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(status: status)
            Divider()
            ControlsView(client: client)
            Divider()
            
            QuickActionsView(client: client)
            FooterActionsView(client: client)
        }
    }
}

struct HeaderView: View {
    let status: Rpc_StatusResponse
    
    private var computedStatusText: String {
        if status.isConnected && status.isCharging && status.currentCharge > status.chargeLimit && status.chargeLimit < 100 {
            return "404 - Limiter not found!"
        }

        if status.isConnected && !status.isCharging && status.currentCharge >= status.chargeLimit && status.chargeLimit < 100 {
            return "Paused at \(status.chargeLimit)%"
        }
  
        if status.isCharging {
            return "Charging to \(status.chargeLimit)%"
        }
  
        if status.isConnected && status.currentCharge >= 99 {
            return "Fully Charged"
        }
        
        return "Not Charging"
    }
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("PowerGrid").font(.title).bold()
            Spacer()
            HStack(spacing: 4) {
                Text("")
                Text("\(status.currentCharge)%")
                    .foregroundColor(chargeColor())
                    .monospacedDigit()
            }
            .font(.title3).bold()
        }
        
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("\(computedStatusText)")
                
                Spacer()
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "cross.circle.fill")
                        Text("\(status.healthByMax)%")
                            .monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                        Text("\(status.cycleCount)")
                            .monospacedDigit()
                    }
                }
            }
            
            Divider().padding(.vertical, 2)
            
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    let adapterText = status.isConnected
                    ? "Connected"
                    : "Disconnected"
                    Grid(alignment: .leading, horizontalSpacing: 4) {
                        GridRow {
                            Text("Adapter:")
                            Text("\(adapterText)")
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(status.isConnected ? "(\(Int(status.adapterMaxWatts)) W)" : "").foregroundColor(.primary)
                        }
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
                                Text("Current:")
                                Text(formatSigned(status.adapterInputAmperage))
                                    .monospacedDigit()
                                    .foregroundColor(status.adapterInputAmperage >= 0 ? .green : .red)
                                    .gridColumnAlignment(.trailing)
                                Text("A").foregroundColor(.primary)
                            }
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
    @ObservedObject var client: DaemonClient
    
    private var chargeLimitLabelText: String {
        if client.userIntent.chargeLimit >= 100 {
            return "Limit: Off"
        } else {
            return "Limit: \(client.userIntent.chargeLimit)%"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(chargeLimitLabelText)
                Spacer()
            }
            Slider(value: chargeLimitBinding(), in: 60...100, step: 10) {
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
    private func chargeLimitBinding() -> Binding<Double> {
        Binding<Double>(
            get: { Double(client.userIntent.chargeLimit) },
            set: { client.userIntent.chargeLimit = Int($0) }
        )
    }
}

struct PowerMetricsView: View {
    let status: Rpc_StatusResponse

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6) {
            GridRow {
                Text("System:")
                Text(formatWattage(status.systemWattage, showSign: false))
                    .monospacedDigit()
                    .gridColumnAlignment(.trailing)
                Text("W").foregroundColor(.primary)
            }

            GridRow {
                Text("Adapter:")
                Text(formatWattage(status.adapterWattage, showSign: true))
                    .monospacedDigit()
                    .foregroundColor(.green)
                    .gridColumnAlignment(.trailing)
                Text("W").foregroundColor(.primary)
            }

            GridRow {
                Text("Battery:")
                Text(formatWattage(status.batteryWattage, showSign: true))
                    .monospacedDigit()
                    .foregroundColor(status.batteryWattage >= 0 ? .green : .red)
                    .gridColumnAlignment(.trailing)
                Text("W").foregroundColor(.primary)
            }
        }
    }

    private func formatWattage(_ value: Float, showSign: Bool) -> String {
        let formatString = showSign ? "%+.1f" : "%.1f"
        return String(format: formatString, value)
    }
}

struct QuickActionsView: View {
    @ObservedObject var client: DaemonClient
    
    var body: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 16) {
            QuickActionButton(
                imageOff: "bolt.fill",
                imageOn: "bolt.slash.fill",
                title: "Force Discharge",
                isOn: $client.userIntent.forceDischarge,
                activeTintColor: .red,
                helpText: client.userIntent.forceDischarge
                    ? "Force discharge"
                    : "Charge normally",
                showsCaption: false
            ) {
                Task {
                    await client.setPowerFeature(
                        feature: .forceDischarge,
                        enable: client.userIntent.forceDischarge
                    )
                }
            }
            
            QuickActionButton(
                imageOff: "moon.fill",
                imageOn: "sun.max.fill",
                title: "Display Sleep",
                isOn: $client.userIntent.preventDisplaySleep,
                activeTintColor: .green,
                helpText: client.userIntent.preventDisplaySleep
                    ? "Prevents display sleep"
                    : "Allows display sleep",
                showsCaption: false
            ) {
                Task {
                    await client.setPowerFeature(
                        feature: .preventDisplaySleep,
                        enable: client.userIntent.preventDisplaySleep
                    )
                }
            }
            
            QuickActionButton(
                imageOff: "infinity",
                imageOn: "lock.fill",
                title: "Limit",
                isOn: limitBinding(),
                activeTintColor: .green,
                helpText: client.userIntent.chargeLimit >= 100
                    ? "No charging limit"
                    : "Charging limited to \(client.userIntent.chargeLimit)%",
                showsCaption: false,
                action: nil,
            )
            
            QuickActionButton(
                imageOff: styleIconName(),
                imageOn: nil,
                title: "Icons",
                isOn: .constant(true),
                activeTintColor: styleButtonTintColor,
                helpText: "Menu bar (\(styleLabel()))",
                showsCaption: false,
                action: {
                    client.userIntent.menuBarDisplayStyle = client.userIntent.menuBarDisplayStyle.next()
                },
            )
            .id(client.userIntent.menuBarDisplayStyle.rawValue)
        }
        .padding(.vertical, 4)
    }
    
    private var styleButtonTintColor: Color {
        switch client.userIntent.menuBarDisplayStyle {
        case .iconAndText:
            return .green
        case .iconOnly:
            return .yellow
        case .textOnly:
            return .red
        }
    }

    
    private func styleLabel() -> String {
        switch client.userIntent.menuBarDisplayStyle {
        case .iconAndText: return "Icon + Text"
        case .iconOnly:    return "Icon Only"
        case .textOnly:    return "Text Only"
        }
    }
    
    private func styleIconName() -> String {
        switch client.userIntent.menuBarDisplayStyle {
        case .iconAndText: return "1.circle"
        case .iconOnly:    return "2.circle"
        case .textOnly:    return "3.circle"
        }
    }
    private func limitBinding() -> Binding<Bool> {
        Binding<Bool>(
            get: { client.userIntent.chargeLimit < 100 },
            set: { turnOn in
                let newLimit = turnOn ? 80 : 100
                client.userIntent.chargeLimit = newLimit
                Task { await client.setLimit(newLimit) }
            }
        )
    }
}

struct FooterActionsView: View {
    @ObservedObject var client: DaemonClient
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.bottom, 8)

            HStack {
                Menu("Advanced Options") {
                    //Toggle("Prevent Display Sleep", isOn: $client.userIntent.preventDisplaySleep)
                    //    .onChange(of: client.userIntent.preventDisplaySleep) { _, newValue in
                    //        Task { await client.setPowerFeature(feature: .preventDisplaySleep, enable: newValue) }
                    //    }
                    
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
                    
                    //Toggle("Force Discharge", isOn: $client.userIntent.forceDischarge)
                    //    .onChange(of: client.userIntent.forceDischarge) { _, newValue in
                    //        Task { await client.setPowerFeature(feature: .forceDischarge, enable: newValue) }
                    //    }
                    
                    Button("View Daemon Logs in Console") {
                        guard let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else { return }
                        let config = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.openApplication(at: consoleURL, configuration: config)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Quit") {
                    Task { await MainActor.run { NSApplication.shared.terminate(nil) } }
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
