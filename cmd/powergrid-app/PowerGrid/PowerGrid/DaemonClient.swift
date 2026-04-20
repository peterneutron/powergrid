//
//  DaemonClient.swift
//  PowerGrid
//
//
//
// File: DaemonClient.swift

import Foundation
import UserNotifications
import ServiceManagement
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import NIOPosix

enum ForceDischargeMode: String, Equatable {
    case off
    case on
    case auto
}

enum BuildClassification {
    case clean
    case dirty
    case fallback
    case unknown
}

struct UserIntent: Equatable {
    var chargeLimit: Int = 100
    var preferredChargeLimit: Int = 80
    var preventDisplaySleep: Bool = false
    var preventSystemSleep: Bool = false
    var controlMagsafeLED: Bool = false
    var disableChargingBeforeSleep: Bool = true
    var forceDischargeMode: ForceDischargeMode = .off
    var menuBarDisplayStyle: MenuBarDisplayStyle = .iconAndText
    var lowPowerNotificationsEnabled: Bool = true
    var showBatteryDetails: Bool = false
}
    
    @MainActor
    class DaemonClient: ObservableObject {
        @Published var connectionState: ConnectionState = .disconnected
        @Published var installerState: InstallerState = .unknown
        
        @Published private(set) var status: Rpc_StatusResponse?
        @Published var userIntent = UserIntent() {
            didSet {
                if userIntent.menuBarDisplayStyle != oldValue.menuBarDisplayStyle {
                    preferences.setMenuBarDisplayStyle(userIntent.menuBarDisplayStyle)
                    log("Saved menu bar display style: \(userIntent.menuBarDisplayStyle.rawValue)")
                }
                if userIntent.preferredChargeLimit != oldValue.preferredChargeLimit,
                   (60...99).contains(userIntent.preferredChargeLimit) {
                    preferences.setPreferredChargeLimit(userIntent.preferredChargeLimit)
                    log("Saved preferred charge limit: \(userIntent.preferredChargeLimit)%")
                }
                if userIntent.lowPowerNotificationsEnabled != oldValue.lowPowerNotificationsEnabled {
                    preferences.setLowPowerNotificationsEnabled(userIntent.lowPowerNotificationsEnabled)
                    log("Saved low power notifications: \(userIntent.lowPowerNotificationsEnabled)")
                }
                if userIntent.showBatteryDetails != oldValue.showBatteryDetails {
                    preferences.setShowBatteryDetails(userIntent.showBatteryDetails)
                    log("Saved showBatteryDetails: \(userIntent.showBatteryDetails)")
                }
            }
        }
        
        enum InstallerState: Equatable {
            case unknown
            case notInstalled
            case installing
            case uninstalling
            case installed
            case upgradeAvailable
            case incompatibleDaemon(String)
            case failed(String)
        }
        
        enum ConnectionState {
            case connected
            case disconnected
            case connecting
        }
        
        private var client: Rpc_PowerGrid.Client<HTTP2ClientTransport.Posix>?
        private var transport: HTTP2ClientTransport.Posix?
        private var rawGRPCClient: GRPCClient<HTTP2ClientTransport.Posix>?
        private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private var appliedStartupSafety = false
        private var prevStatus: Rpc_StatusResponse?
        private var prevIntent: UserIntent?
        private let rules = RulesEngine()
        private var autoArmed = false // Auto is engaged (Auto selected AND FD active)
        @Published private(set) var embeddedDaemonBuildID: String?
        @Published private(set) var installedDaemonBuildID: String?
        @Published private(set) var daemonAuthMode: String?
        @Published private(set) var daemonMagsafeLedSupported: Bool = false
        @Published private(set) var daemonBuildIDSource: String?
        @Published private(set) var daemonBuildDirty: Bool = false
        @Published private(set) var daemonAPIMajor: UInt32 = 0
        @Published private(set) var daemonAPIMinor: UInt32 = 0
        @Published private(set) var daemonCapabilities: [String] = []
        @Published private(set) var runAtLoginEnabled: Bool = false
        private var skipUpgradeThisSession = false
        private let preferences = AppPreferences.shared
        private var didStart = false
        private var isPollingStatus = false
        private var connectionGeneration: UInt64 = 0

        // App<->daemon compatibility contract.
        private let expectedAPIMajor: UInt32 = 1
        private let minimumAPIMinor: UInt32 = 0
        
        init() {
            var initialIntent = UserIntent()

            if let style = preferences.menuBarDisplayStyle() {
                initialIntent.menuBarDisplayStyle = style
                log("Loaded menu bar display style: \(style.rawValue)")
            }
            if let savedPref = preferences.preferredChargeLimit(),
               (60...99).contains(savedPref) {
                initialIntent.preferredChargeLimit = savedPref
                log("Loaded preferred charge limit: \(savedPref)%")
            }
            if let showBatteryDetails = preferences.showBatteryDetails() {
                initialIntent.showBatteryDetails = showBatteryDetails
            }
            if let notificationsEnabled = preferences.lowPowerNotificationsEnabled() {
                initialIntent.lowPowerNotificationsEnabled = notificationsEnabled
            } else {
                preferences.setLowPowerNotificationsEnabled(true)
            }
            self.userIntent = initialIntent
            refreshRunAtLoginStatus()
        }
        
        deinit {
            rawGRPCClient?.beginGracefulShutdown()
            try? group.syncShutdownGracefully()
        }
        
        func connect() {
            if connectionState == .connecting {
                return
            }

            rawGRPCClient?.beginGracefulShutdown()
            rawGRPCClient = nil
            client = nil
            transport = nil
            connectionGeneration &+= 1
            let generation = connectionGeneration
            connectionState = .connecting
            
            do {
                let newTransport = try HTTP2ClientTransport.Posix(
                    target: .unixDomainSocket(path: "/var/run/powergrid.sock"),
                    transportSecurity: .plaintext,
                    eventLoopGroup: self.group
                )
                self.transport = newTransport
                let grpcClient = GRPCClient(transport: newTransport)
                self.rawGRPCClient = grpcClient
                self.client = Rpc_PowerGrid.Client(wrapping: grpcClient)
                
                Task.detached {
                    do {
                        try await grpcClient.runConnections()
                        await MainActor.run {
                            guard self.connectionGeneration == generation else { return }
                            self.connectionState = .disconnected
                        }
                    } catch {
                        print("gRPC client connection manager threw an error: \(error)")
                        await MainActor.run {
                            guard self.connectionGeneration == generation else { return }
                            self.connectionState = .disconnected
                        }
                    }
                }
            } catch {
                print("Failed to initialize gRPC transport: \(error)")
                self.connectionState = .disconnected
            }
        }

        func start() async {
            guard !didStart else { return }
            didStart = true
            await pollStatus(forceReconnect: true)
        }

        func pollStatus(forceReconnect: Bool = false) async {
            guard !isPollingStatus else { return }
            isPollingStatus = true
            defer { isPollingStatus = false }

            if forceReconnect || self.client == nil || connectionState == .disconnected {
                connect()
            }

            await fetchStatus()
        }
        
        func fetchStatus() async {
            guard let client = self.client else {
                connectionState = .disconnected
                return
            }
            
            do {
                // On first fetch, perform daemon version check once
                if self.embeddedDaemonBuildID == nil {
                    await computeEmbeddedBuildID()
                    do {
                        let ver = try await client.getVersion(Rpc_Empty())
                        self.installedDaemonBuildID = ver.buildID
                        await refreshDaemonInfo(client)
                        _ = self.evaluateCompatibility()
                        self.applyUpgradePolicy()
                    } catch {
                        // Older daemon without GetVersion RPC: treat as upgrade available
                        if let rpcError = error as? GRPCCore.RPCError, rpcError.code == .unimplemented {
                            self.installedDaemonBuildID = nil
                            self.daemonBuildIDSource = nil
                            self.daemonBuildDirty = false
                            self.daemonAPIMajor = 0
                            self.daemonAPIMinor = 0
                            self.daemonCapabilities = []
                            if self.embeddedDaemonBuildID != nil {
                                self.installerState = .upgradeAvailable
                            }
                        } else {
                            // Leave as is; we won't force upgrade on other errors
                            self.installedDaemonBuildID = nil
                            self.daemonBuildIDSource = nil
                            self.daemonBuildDirty = false
                            self.daemonAPIMajor = 0
                            self.daemonAPIMinor = 0
                            self.daemonCapabilities = []
                        }
                    }
                    _ = self.evaluateCompatibility()
                    self.applyUpgradePolicy()
                }

                let response = try await client.getStatus(Rpc_Empty())
                self.status = response
                // Snapshot previous intent at the start of this tick for rules evaluation
                let previousIntentForThisTick = self.userIntent

                // Safety on launch: do not carry forced discharge across app restarts.
                if !appliedStartupSafety {
                    appliedStartupSafety = true
                    if response.forceDischargeActive {
                        Task { await self.setPowerFeature(feature: .forceDischarge, enable: false) }
                    }
                }

                // Determine Auto cutoff: use active user limit (<100) or preferred limit if Off (100)
                let activeLimit = Int(response.chargeLimit)
                let preferred = self.userIntent.preferredChargeLimit
                let autoCutoffRaw = (activeLimit < 100 ? activeLimit : preferred)
                let autoCutoff = min(max(autoCutoffRaw, 60), 99)

                // Track whether Auto is actively engaged (selected + FD active)
                let autoEngagedNow = (self.userIntent.forceDischargeMode == .auto) && response.forceDischargeActive
                if autoEngagedNow { self.autoArmed = true }

                let newFDMode: ForceDischargeMode = {
                    if self.userIntent.forceDischargeMode == .auto {
                        // If Auto was selected and forced discharge is no longer active
                        // and we're at/below the cutoff, reflect Off in UI.
                        if !response.forceDischargeActive && Int(response.currentCharge) <= autoCutoff {
                            return .off
                        }
                        return .auto
                    }
                    return response.forceDischargeActive ? .on : .off
                }()

                let intentFromServer = UserIntent(
                    chargeLimit: Int(response.chargeLimit),
                    preferredChargeLimit: (response.chargeLimit < 100 ? Int(response.chargeLimit) : self.userIntent.preferredChargeLimit),
                    preventDisplaySleep: response.preventDisplaySleepActive,
                    preventSystemSleep: response.preventSystemSleepActive,
                    controlMagsafeLED: response.magsafeLedControlActive,
                    disableChargingBeforeSleep: response.disableChargingBeforeSleepActive,
                    forceDischargeMode: newFDMode,
                    menuBarDisplayStyle: self.userIntent.menuBarDisplayStyle,
                    lowPowerNotificationsEnabled: self.userIntent.lowPowerNotificationsEnabled,
                    showBatteryDetails: self.userIntent.showBatteryDetails
                )
                
                if self.userIntent != intentFromServer {
                    self.userIntent = intentFromServer
                    log("Synchronized UI intent with daemon status.")
                }
                // Always update prevIntent for this evaluation tick so rules have accurate history
                self.prevIntent = previousIntentForThisTick

                // Evaluate rules and apply actions
                let ctx = RuleContext(
                    previousStatus: self.prevStatus,
                    currentStatus: response,
                    previousIntent: previousIntentForThisTick,
                    currentIntent: self.userIntent
                )
                let actions = self.rules.evaluate(ctx)
                for action in actions {
                    switch action {
                    case .disableForceDischargeAndNotify(let limit):
                        guard self.userIntent.forceDischargeMode == .auto else { break }
                        await self.setPowerFeature(feature: .forceDischarge, enable: false)
                        await NotificationsService.shared.post(title: "Force Discharge Disabled",
                                                               body: "Reached limit (\(limit)%). Re-enabled adapter.")
                    case .notifyLowPower(let threshold):
                        let includeAction = response.lowPowerModeAvailable && !(response.lowPowerModeEnabled)
                        await NotificationsService.shared.postLowPowerAlert(threshold: threshold, includeEnableAction: includeAction)
                    }
                }
                self.prevStatus = response

                if connectionState != .connected {
                    connectionState = .connected
                    if installerState != .upgradeAvailable && !isIncompatibleInstallerState(installerState) {
                        installerState = .installed
                    }
                }
            } catch {
                if let rpcError = error as? GRPCCore.RPCError {
                    if rpcError.code == .unavailable {
                        print("Connection is unavailable or closed.")
                    } else {
                        print("A gRPC error occurred: \(rpcError.message) (Code: \(rpcError.code))")
                    }
                } else {
                    print("An unknown error occurred: \(error)")
                }
                
                self.status = nil
                self.connectionState = .disconnected
                if self.installerState != .installing {
                    installerState = .notInstalled
                }
            }
        }
        
        private func computeEmbeddedBuildID() async {
            if let path = Bundle.main.path(forResource: "powergrid-daemon", ofType: "buildid") {
                do {
                    var id = try String(contentsOfFile: path, encoding: .utf8)
                    id = id.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.embeddedDaemonBuildID = id.isEmpty ? nil : id
                } catch {
                    print("Failed to read embedded daemon BuildID: \(error)")
                }
            } else {
                print("Embedded daemon BuildID file not found in bundle resources.")
            }
        }

        private func refreshDaemonInfo(_ client: Rpc_PowerGrid.Client<HTTP2ClientTransport.Posix>) async {
            do {
                let info = try await client.getDaemonInfo(Rpc_Empty())
                self.installedDaemonBuildID = info.buildID
                self.daemonAuthMode = info.authMode
                self.daemonMagsafeLedSupported = info.magsafeLedSupported
                self.daemonBuildIDSource = info.buildIDSource.isEmpty ? nil : info.buildIDSource
                self.daemonBuildDirty = info.buildDirty
                self.daemonAPIMajor = info.apiMajor
                self.daemonAPIMinor = info.apiMinor
                self.daemonCapabilities = info.capabilities
            } catch {
                if let rpcError = error as? GRPCCore.RPCError, rpcError.code == .unimplemented {
                    self.daemonAuthMode = nil
                    self.daemonBuildIDSource = nil
                    self.daemonBuildDirty = false
                    self.daemonAPIMajor = 0
                    self.daemonAPIMinor = 0
                    self.daemonCapabilities = []
                }
            }
        }

        private func evaluateCompatibility() -> Bool {
            // Legacy daemon without API fields: keep compatibility, rely on upgrade hinting.
            if daemonAPIMajor == 0 && daemonAPIMinor == 0 {
                return true
            }
            if daemonAPIMajor != expectedAPIMajor {
                installerState = .incompatibleDaemon(
                    "Daemon API v\(daemonAPIMajor).\(daemonAPIMinor) is incompatible with app API v\(expectedAPIMajor).x."
                )
                return false
            }
            if daemonAPIMinor < minimumAPIMinor {
                installerState = .incompatibleDaemon(
                    "Daemon API v\(daemonAPIMajor).\(daemonAPIMinor) is older than required v\(expectedAPIMajor).\(minimumAPIMinor)."
                )
                return false
            }
            return true
        }

        private func isIncompatibleInstallerState(_ state: InstallerState) -> Bool {
            if case .incompatibleDaemon = state {
                return true
            }
            return false
        }

        private func classifyEmbeddedBuild() -> BuildClassification {
            guard let id = embeddedDaemonBuildID, !id.isEmpty else {
                return .unknown
            }
            if id.hasSuffix("-dirty") { return .dirty }
            if id.hasSuffix("-fallback") { return .fallback }
            return .clean
        }

        private func classifyInstalledBuild() -> BuildClassification {
            guard let id = installedDaemonBuildID, !id.isEmpty else {
                return .unknown
            }
            if daemonBuildDirty || id.hasSuffix("-dirty") { return .dirty }
            if daemonBuildIDSource == "fallback" || id.hasSuffix("-fallback") { return .fallback }
            return .clean
        }

        private func applyUpgradePolicy() {
            if skipUpgradeThisSession {
                return
            }
            if isIncompatibleInstallerState(installerState) {
                return
            }

            let embeddedClass = classifyEmbeddedBuild()
            let installedClass = classifyInstalledBuild()

            if embeddedClass == .dirty {
                installerState = .upgradeAvailable
                return
            }

            if embeddedClass == .clean, installedClass == .clean,
               let local = embeddedDaemonBuildID, let remote = installedDaemonBuildID, local != remote {
                installerState = .upgradeAvailable
                return
            }

            if embeddedClass == .fallback || installedClass == .fallback {
                // Fallback IDs are not strict upgrade blockers; keep current state.
                return
            }
        }
        
        func setLimit(_ newLimit: Int) async {
            log("Setting charge limit to \(newLimit)%")
            guard let client = self.client else { return }
            guard evaluateCompatibility() else { return }
            
            var request = Rpc_MutationRequest()
            request.operation = .setChargeLimit
            request.limit = Int32(newLimit)
            
            do {
                _ = try await client.applyMutation(request)
            } catch {
                if let rpcError = error as? GRPCCore.RPCError {
                    switch rpcError.code {
                    case .permissionDenied:
                        self.installerState = .failed("Permission denied: active console user authorization is required.")
                    case .invalidArgument:
                        self.installerState = .failed("Invalid request: \(rpcError.message)")
                    default:
                        self.installerState = .failed("Daemon mutation failed: \(rpcError.message)")
                    }
                }
                print("Error setting limit: \(error)")
            }
            
            if newLimit < 100 {
                self.userIntent.preferredChargeLimit = newLimit
            }

            await fetchStatus()
        }
        
        func setPowerFeature(feature: Rpc_PowerFeature, enable: Bool) async {
            log("Setting feature \(feature) to \(enable)")
            guard let client = self.client else { return }
            guard evaluateCompatibility() else { return }
            var req = Rpc_MutationRequest()
            req.operation = .setPowerFeature
            req.feature = feature
            req.enable = enable
            do {
                _ = try await client.applyMutation(req)
            } catch {
                if let rpcError = error as? GRPCCore.RPCError {
                    switch rpcError.code {
                    case .permissionDenied:
                        self.installerState = .failed("Permission denied: active console user authorization is required.")
                    case .invalidArgument:
                        self.installerState = .failed("Invalid request: \(rpcError.message)")
                    default:
                        self.installerState = .failed("Daemon mutation failed: \(rpcError.message)")
                    }
                }
                print("Error setting power feature: \(error)")
            }
            
            await fetchStatus()
        }
        
        func installDaemon() async {
            self.installerState = .installing
            
            guard let helperPath = Bundle.main.path(forResource: "powergrid-helper", ofType: nil) else {
                self.installerState = .failed("Helper tool not found in app bundle.")
                return
            }
            
            guard let resourcesPath = Bundle.main.resourcePath else {
                self.installerState = .failed("App bundle resources directory not found.")
                return
            }
            
            let command = "do shell script \"\\\"\(helperPath)\\\" install \\\"\(resourcesPath)\\\"\" with administrator privileges"
            
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: command)
            
            let success = await Task.detached {
                return script?.executeAndReturnError(&errorDict) != nil
            }.value
            
            if success {
                self.installerState = .installed
                log("Daemon installed successfully. Attempting to connect...")
                try? await Task.sleep(for: .seconds(2))
                self.connect()
                await self.fetchStatus()
                await self.updateVersionIDsAfterInstall()
            } else {
                if let errorInfo = errorDict {
                    let errorMessage = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "An unknown AppleScript error occurred."
                    self.installerState = .failed(errorMessage)
                    log("Daemon installation failed: \(errorMessage)")
                } else {
                    self.installerState = .failed("An unknown error occurred during installation.")
                    log("Daemon installation failed.")
                }
            }
        }

        private func updateVersionIDsAfterInstall() async {
            // Ensure embedded ID is available
            if self.embeddedDaemonBuildID == nil {
                await computeEmbeddedBuildID()
            }
            guard let client = self.client else { return }
            let maxAttempts = 5
            for attempt in 1...maxAttempts {
                do {
                    let ver = try await client.getVersion(Rpc_Empty())
                    self.installedDaemonBuildID = ver.buildID
                    await refreshDaemonInfo(client)
                    _ = evaluateCompatibility()
                    self.applyUpgradePolicy()
                    if self.installerState != .upgradeAvailable && !isIncompatibleInstallerState(self.installerState) {
                        self.installerState = .installed
                    }
                    return
                } catch {
                    if attempt == maxAttempts {
                        print("Post-install GetVersion failed after \(maxAttempts) attempts: \(error)")
                        return
                    }
                    let delayNanos = UInt64(250_000_000 * attempt)
                    try? await Task.sleep(nanoseconds: delayNanos)
                }
            }
        }

        // Allow user to skip upgrade prompts for this app session (e.g., dirty dev builds)
        func setSkipUpgradeForSession() {
            self.skipUpgradeThisSession = true
            // If we're currently showing the installer/upgrade view, switch to installed state
            if self.connectionState == .connected {
                self.installerState = .installed
            } else {
                // We may not be connected yet; still move out of upgrade gate
                self.installerState = .installed
            }
        }
        
        func uninstallDaemon() async {
            self.installerState = .uninstalling
            
            guard let helperPath = Bundle.main.path(forResource: "powergrid-helper", ofType: nil) else {
                self.installerState = .failed("Helper tool not found in app bundle.")
                return
            }
            
            let command = "do shell script \"\\\"\(helperPath)\\\" uninstall\" with administrator privileges"
            
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: command)
            
            let success = await Task.detached {
                return script?.executeAndReturnError(&errorDict) != nil
            }.value
            
            if success {
                log("Daemon uninstalled successfully.")
                self.rawGRPCClient?.beginGracefulShutdown()
                self.connectionState = .disconnected
                self.status = nil
                self.installerState = .notInstalled
            } else {
                if let errorInfo = errorDict {
                    let errorMessage = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "An unknown AppleScript error occurred."
                    self.installerState = .failed(errorMessage)
                    log("Daemon uninstallation failed: \(errorMessage)")
                } else {
                    self.installerState = .failed("An unknown error occurred during uninstallation.")
                    log("Daemon uninstallation failed.")
                }
            }
        }
        
        private func log(_ message: String) {
            print("[DaemonClient] \(message)")
        }

        func setMenuBarDisplayStyle(_ style: MenuBarDisplayStyle) {
            guard userIntent.menuBarDisplayStyle != style else { return }

            userIntent.menuBarDisplayStyle = style
        }

        func setPreferredChargeLimit(_ limit: Int) {
            guard (60...99).contains(limit) else { return }
            userIntent.preferredChargeLimit = limit
        }

        func refreshRunAtLoginStatus() {
            guard #available(macOS 13.0, *) else {
                self.runAtLoginEnabled = false
                return
            }
            self.runAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }

        func setRunAtLogin(_ enabled: Bool) async {
            guard #available(macOS 13.0, *) else {
                return
            }

            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try await SMAppService.mainApp.unregister()
                }
            } catch {
                log("Failed to set Run at Login to \(enabled): \(error)")
            }
            refreshRunAtLoginStatus()
        }

        // Notifications are handled via NotificationsService
    }
