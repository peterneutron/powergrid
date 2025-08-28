//
//  PowerGridApp.swift
//  PowerGrid
//
//
//
// File: PowerGridApp.swift

import SwiftUI
import UserNotifications

@main
struct PowerGridApp: App {
    @StateObject private var client = DaemonClient()
    private let notificationHandler = NotificationActionHandler()
    
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
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    await NotificationsService.shared.registerLowPowerCategory()
                    notificationHandler.client = client
                    UNUserNotificationCenter.current().delegate = notificationHandler
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
            case .upgradeAvailable:
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
        let adapterPresent = Int(status.adapterMaxWatts) > 0
        if status.forceDischargeActive && adapterPresent {
            return "exclamationmark.triangle.fill"
        }
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
                
            case .notInstalled, .failed, .upgradeAvailable:
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
            Text(client.installerState == .upgradeAvailable ? "PowerGrid Daemon Upgrade Available" : "PowerGrid Daemon Required")
                .font(.title2).bold()
            
            Text(client.installerState == .upgradeAvailable
                 ? (client.embeddedDaemonBuildID?.hasSuffix("-dirty") == true
                    ? "Dev build detected (dirty). You can upgrade now or skip to use the installed daemon."
                    : "A newer daemon is bundled with this app. Upgrade to keep features in sync.")
                 : "To manage your Mac's charging, PowerGrid needs to install a small helper daemon that runs in the background as root.")
                .font(.callout)
            
            if case .failed(let errorMessage) = client.installerState {
                Text("Installation Failed: \(errorMessage)")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            Button(client.installerState == .upgradeAvailable ? "Upgrade Daemon" : "Install Daemon") {
                Task {
                    await client.installDaemon()
                }
            }
            .buttonStyle(.borderedProminent)
            
            if client.installerState == .upgradeAvailable && (client.embeddedDaemonBuildID?.hasSuffix("-dirty") == true) {
                Button("Skip for now") {
                    // Session-only skip: continue with existing daemon
                    client.setSkipUpgradeForSession()
                }
                .buttonStyle(.bordered)
            }
            
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
            // Compute the Auto cutoff (user limit when <100, else preferred; clamped 60–99)
            let userLimit = (client.userIntent.chargeLimit < 100) ? client.userIntent.chargeLimit : client.userIntent.preferredChargeLimit
            let autoCutoff = min(max(userLimit, 60), 99)

            HeaderView(
                status: status,
                displayStyle: client.userIntent.menuBarDisplayStyle,
                forceDischargeMode: client.userIntent.forceDischargeMode,
                autoCutoff: autoCutoff,
                userIntent: client.userIntent
            )
            Divider()
            ControlsView(client: client)
            Divider()
            
            QuickActionsView(client: client, status: status)
            FooterActionsView(client: client)
        }
    }
}

struct HeaderView: View {
    let status: Rpc_StatusResponse
    let displayStyle: MenuBarDisplayStyle
    let forceDischargeMode: ForceDischargeMode
    let autoCutoff: Int
    let userIntent: UserIntent
    
    private var computedStatusText: String {
        let adapterPresent = Int(status.adapterMaxWatts) > 0
        if status.forceDischargeActive && adapterPresent {
            return forceDischargeMode == .auto ? "Forced Discharge to \(autoCutoff)%" : "Forced Discharge"
        }
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
        
        return "Discharging"
    }
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("PowerGrid").font(.title).bold()
            Spacer()
            HStack(spacing: 4) {
                Text("")
                if displayStyle == .iconOnly {
                    Text("\(status.currentCharge)%")
                        .foregroundColor(chargeColor())
                        .monospacedDigit()
                }
            }
            .font(.title3).bold()
        }
        
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("\(computedStatusText)")
                
                Spacer()
                HStack(spacing: 10) {
                    if let estimate = computeTimeEstimate(status: status, intent: userIntent) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.fill")
                            Text("\(estimate.formatted)")
                                .monospacedDigit()
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "cross.circle.fill")
                        Text("\(status.healthByMax)%")
                            .monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                        Text("\(status.cycleCount)")
                            .monospacedDigit()
                    }
                }
            }
        
            Divider().padding(.vertical, 2)
            
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    let adapterText: String = {
                        if status.forceDischargeActive {
                            return "Disabled"
                        }
                        return status.isConnected ? "Connected" : "Disconnected"
                    }()
                    Grid(alignment: .leading, horizontalSpacing: 4) {
                        GridRow {
                            Text("Adapter:")
                            Text("\(adapterText)")
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text((status.isConnected || status.forceDischargeActive) ? "(\(Int(status.adapterMaxWatts)) W)" : "")
                                .foregroundColor(.primary)
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
            
            if userIntent.showBatteryDetails {
                Divider().padding(.vertical, 2)
                BatteryDetailsView(status: status)
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

struct BatteryDetailsView: View {
    let status: Rpc_StatusResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                // Left column
                VStack(alignment: .leading, spacing: 4) {
                    Grid(alignment: .leading, horizontalSpacing: 4) {
                        GridRow {
                            Text("Battery:")
                            Text(status.batterySerialNumber.isEmpty ? "—" : status.batterySerialNumber)
                                .gridColumnAlignment(.trailing)
                            Text("")
                        }
                        Grid(alignment: .leading, horizontalSpacing: 6) {
                            GridRow {
                                Text("Voltage:")
                                let v = status.batteryVoltage
                                Text(v != 0 ? String(format: "%+.2f", v) : "—")
                                    .monospacedDigit()
                                    .foregroundColor(v >= 0 ? .green : .red)
                                    .gridColumnAlignment(.trailing)
                                Text("V").foregroundColor(.primary)
                            }
                            GridRow {
                                Text("Current:")
                                let a = status.batteryAmperage
                                Text(a != 0 ? String(format: "%+.2f", a) : "—")
                                    .monospacedDigit()
                                    .foregroundColor(a >= 0 ? .green : .red)
                                    .gridColumnAlignment(.trailing)
                                Text("A").foregroundColor(.primary)
                            }
                            GridRow {
                                Text("Temp:")
                                let t = status.batteryTemperatureC
                                Text(t != 0 ? String(format: "%.2f", t) : "—")
                                    .monospacedDigit()
                                    .gridColumnAlignment(.trailing)
                                Text("C").foregroundColor(.primary)
                            }
                        }
                    }
                }

                Spacer()

                // Right column
                VStack(alignment: .leading, spacing: 4) {
                    Grid(alignment: .leading, horizontalSpacing: 4) {
                        GridRow {
                            Text("D-Cap:")
                            Text(status.batteryDesignCapacity > 0 ? "\(status.batteryDesignCapacity)" : "—")
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text("mAh").foregroundColor(.primary)
                        }
                        GridRow {
                            Text("M-Cap:")
                            Text(status.batteryMaxCapacity > 0 ? "\(status.batteryMaxCapacity)" : "—")
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text("mAh").foregroundColor(.primary)
                        }
                        GridRow {
                            Text("N-Cap:")
                            Text(status.batteryNominalCapacity > 0 ? "\(status.batteryNominalCapacity)" : "—")
                                .monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text("mAh").foregroundColor(.primary)
                        }
                    }
                }
            }

            // Below the two columns: individual cells (single line) and drift
            Grid(alignment: .leading, horizontalSpacing: 4) {
                GridRow {
                    Text("Cells:")
                    let cellLine = status.batteryIndividualCellMillivolts.map { mv in
                        String(format: "%.3fV", Double(mv) / 1000.0)
                    }.joined(separator: " | ")
                    Text(cellLine.isEmpty ? "—" : cellLine)
                        .monospacedDigit()
                        .gridColumnAlignment(.leading)
                    Text("")
                }
                GridRow {
                    Text("Drift:")
                    let (label, color) = driftLabelAndColor(millivolts: status.batteryIndividualCellMillivolts)
                    let mvOpt = driftMilliVolts(millivolts: status.batteryIndividualCellMillivolts)
                    Text(mvOpt == nil ? label : "\(label) (\(mvOpt!) mV)")
                        .foregroundStyle(color)
                        .gridColumnAlignment(.leading)
                    Text("")
                }
            }
            .padding(.top, 6)
        }
    }
}

private func driftLabelAndColor(millivolts: [Int32]) -> (String, Color) {
    guard millivolts.count >= 2 else { return ("—", .secondary) }
    let ints = millivolts.map { Int($0) }
    guard let minV = ints.min(), let maxV = ints.max() else { return ("—", .secondary) }
    let drift = maxV - minV // mV
    if drift <= 10 { return ("Normal", .green) }
    if drift <= 30 { return ("Slight", .yellow) }
    return ("High", .red)
}

private func driftMilliVolts(millivolts: [Int32]) -> Int? {
    guard millivolts.count >= 2 else { return nil }
    let ints = millivolts.map { Int($0) }
    guard let minV = ints.min(), let maxV = ints.max() else { return nil }
    return maxV - minV
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
            set: {
                let value = Int($0)
                client.userIntent.chargeLimit = value
                if value < 100 {
                    client.userIntent.preferredChargeLimit = value
                    UserDefaults.standard.set(value, forKey: "preferredChargeLimit")
                }
            }
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
    let status: Rpc_StatusResponse
    
    var body: some View {
        let actionsCount = 4 // Update if actions added/removed dynamically
        let columnsCount = max(1, min(4, actionsCount))
        let columns = Array(repeating: GridItem(.flexible()), count: columnsCount)
        let adapterPresent = (Int(status.adapterMaxWatts) > 0)
        let userLimit = (client.userIntent.chargeLimit < 100) ? client.userIntent.chargeLimit : client.userIntent.preferredChargeLimit
        // Auto is only meaningful when current charge is ABOVE the cutoff;
        // disable/hide Auto at or below the user limit, or when no adapter.
        let autoAllowed = adapterPresent && (Int(status.currentCharge) > userLimit)

        LazyVGrid(columns: columns, spacing: 16) {
            MultiStateActionButton<ForceDischargeMode>(
                title: "Force Discharge",
                states: [
                    ActionState(value: .off,  imageName: "bolt.fill",                 tint: .red, help: "Charge normally"),
                    ActionState(value: .on,   imageName: "bolt.badge.xmark.fill",     tint: .red, help: "Force discharge"),
                    ActionState(value: .auto, imageName: "bolt.badge.automatic.fill", tint: .red, help: "Auto: Disable at \(userLimit)%")
                ],
                selection: $client.userIntent.forceDischargeMode,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { value in value != .off },
                onChange: { newMode in
                    Task {
                        switch newMode {
                        case .off:
                            await client.setPowerFeature(feature: .forceDischarge, enable: false)
                        case .on, .auto:
                            // Enable now; DaemonClient will auto-disable at/below user limit
                            await client.setPowerFeature(feature: .forceDischarge, enable: true)
                        }
                    }
                },
                shouldSkip: { value in value == .auto && !autoAllowed }
            )
            .disabled(!adapterPresent)
            .opacity(adapterPresent ? 1.0 : 0.45)
            .onAppear { handleAdapterPresence(adapterPresent: adapterPresent) }
            .onChange(of: status.adapterMaxWatts) { _, _ in handleAdapterPresence(adapterPresent: Int(status.adapterMaxWatts) > 0) }
            // Do not forcibly flip Auto off on charge changes here;
            // the RulesEngine handles disabling FD and the UI updates accordingly.

            MultiStateActionButton<Bool>(
                title: "Display Sleep",
                states: [
                    ActionState(value: false, imageName: "moon.fill",     tint: .green, help: "Allows display sleep"),
                    ActionState(value: true,  imageName: "sun.max.fill",  tint: .green, help: "Prevents display sleep")
                ],
                selection: $client.userIntent.preventDisplaySleep,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 },
                onChange: { isOn in
                    Task { await client.setPowerFeature(feature: .preventDisplaySleep, enable: isOn) }
                }
            )

            MultiStateActionButton<Bool>(
                title: "Limit",
                states: [
                    ActionState(
                        value: false,
                        imageName: "infinity",
                        tint: .green,
                        help: "No charging limit",
                        accessibilityLabel: "Limit Off"
                    ),
                    ActionState(
                        value: true,
                        imageName: "lock.fill",
                        tint: .green,
                        help: "Charging limited to \(client.userIntent.preferredChargeLimit)%",
                        accessibilityLabel: "Limit On (\(client.userIntent.preferredChargeLimit)%)"
                    )
                ],
                selection: limitBinding(),
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 },
                onChange: { isOn in
                    let newLimit = isOn ? client.userIntent.preferredChargeLimit : 100
                    Task { await client.setLimit(newLimit) }
                }
            )

            MultiStateActionButton<MenuBarDisplayStyle>(
                title: "Icons",
                states: [
                    ActionState(value: .iconAndText, imageName: "circle.grid.2x1.fill",          tint: .green,  help: "Menu bar (Icon + Text)"),
                    ActionState(value: .iconOnly,    imageName: "circle.grid.2x1.left.filled",   tint: .yellow, help: "Menu bar (Icon Only)"),
                    ActionState(value: .textOnly,    imageName: "circle.grid.2x1.right.filled",  tint: .red,    help: "Menu bar (Text Only)")
                ],
                selection: $client.userIntent.menuBarDisplayStyle,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { _ in true },
                onChange: { _ in }
            )
            .id(client.userIntent.menuBarDisplayStyle.rawValue)
        }
        .padding(.vertical, 4)
    }
    
    private func limitBinding() -> Binding<Bool> {
        Binding<Bool>(
            get: { client.userIntent.chargeLimit < 100 },
            set: { turnOn in
                let newLimit = turnOn ? client.userIntent.preferredChargeLimit : 100
                client.userIntent.chargeLimit = newLimit
            }
        )
    }
    
    private func handleAdapterPresence(adapterPresent: Bool) {
        // If adapter is removed while force discharge is active or selected, immediately reflect Off in UI
        // and request the daemon to disable forced discharge in the background.
        if !adapterPresent {
            if client.userIntent.forceDischargeMode != .off || (client.status?.forceDischargeActive == true) {
                Task { @MainActor in
                    client.userIntent.forceDischargeMode = .off
                }
                Task {
                    await client.setPowerFeature(feature: .forceDischarge, enable: false)
                }
            }
        }
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

                        Toggle("Control MagSafe LED", isOn: $client.userIntent.controlMagsafeLED)
                            .disabled(!(client.status?.magsafeLedSupported ?? false))
                            .onChange(of: client.userIntent.controlMagsafeLED) { _, newValue in
                                Task { await client.setPowerFeature(feature: .controlMagsafeLed, enable: newValue) }
                            }
                        if !(client.status?.magsafeLedSupported ?? false) {
                            Text("MagSafe LED control not supported on this hardware.")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Toggle("Disable Charging Before Sleep", isOn: $client.userIntent.disableChargingBeforeSleep)
                            .onChange(of: client.userIntent.disableChargingBeforeSleep) { _, newValue in
                                Task { await client.setPowerFeature(feature: .disableChargingBeforeSleep, enable: newValue) }
                            }

                        Toggle("Low Power Notifications", isOn: $client.userIntent.lowPowerNotificationsEnabled)

                        Toggle("Show Battery Details", isOn: $client.userIntent.showBatteryDetails)
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
                    // Developer submenu (only when running a dirty build)
                    if client.embeddedDaemonBuildID?.hasSuffix("-dirty") == true {
                        Menu("Developer") {
                            Text("Daemon IDs").font(.caption).foregroundStyle(.secondary)
                            if let embedded = client.embeddedDaemonBuildID {
                                Text("Embedded: \(shortID(embedded))")
                                    .foregroundStyle(.secondary)
                                    .help(embedded)
                            }
                            if let installed = client.installedDaemonBuildID {
                                Text("Installed: \(shortID(installed))")
                                    .foregroundStyle(.secondary)
                                    .help(installed)
                            }
                        }
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

// Shorten a hex ID for display (e.g., first 12 chars)
private func shortID(_ id: String?) -> String {
    guard let id = id, !id.isEmpty else { return "—" }
    if id.hasSuffix("-dirty") {
        let base = String(id.dropLast(6)) // remove "-dirty"
        return String(base.prefix(12)) + "-dirty"
    }
    return String(id.prefix(12))
}
