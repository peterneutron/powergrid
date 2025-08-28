//
//  DaemonClient.swift
//  PowerGrid
//
//
//
// File: DaemonClient.swift

import Foundation
import UserNotifications
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import NIOPosix

enum ForceDischargeMode: String, Equatable {
    case off
    case on
    case auto
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
}
    
    @MainActor
    class DaemonClient: ObservableObject {
        @Published var connectionState: ConnectionState = .disconnected
        @Published var installerState: InstallerState = .unknown
        
        @Published private(set) var status: Rpc_StatusResponse?
        @Published var userIntent = UserIntent() {
            didSet {
                if userIntent.menuBarDisplayStyle != oldValue.menuBarDisplayStyle {
                    UserDefaults.standard.set(userIntent.menuBarDisplayStyle.rawValue, forKey: "menuBarDisplayStyle")
                    log("Saved menu bar display style: \(userIntent.menuBarDisplayStyle.rawValue)")
                }
                if userIntent.lowPowerNotificationsEnabled != oldValue.lowPowerNotificationsEnabled {
                    UserDefaults.standard.set(userIntent.lowPowerNotificationsEnabled, forKey: "lowPowerNotificationsEnabled")
                    log("Saved low power notifications: \(userIntent.lowPowerNotificationsEnabled)")
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
        private var notifiedBelow20 = false
        private var notifiedBelow10 = false
        @Published private(set) var embeddedDaemonBuildID: String?
        @Published private(set) var installedDaemonBuildID: String?
        private var skipUpgradeThisSession = false
        
        init() {
            if let savedValue = UserDefaults.standard.string(forKey: "menuBarDisplayStyle"),
               let style = MenuBarDisplayStyle(rawValue: savedValue) {
                self.userIntent.menuBarDisplayStyle = style
                log("Loaded menu bar display style: \(style.rawValue)")
            }
            if let savedPref = UserDefaults.standard.object(forKey: "preferredChargeLimit") as? Int,
               (60...99).contains(savedPref) {
                self.userIntent.preferredChargeLimit = savedPref
                log("Loaded preferred charge limit: \(savedPref)%")
            }
            if UserDefaults.standard.object(forKey: "lowPowerNotificationsEnabled") != nil {
                self.userIntent.lowPowerNotificationsEnabled = UserDefaults.standard.bool(forKey: "lowPowerNotificationsEnabled")
            } else {
                self.userIntent.lowPowerNotificationsEnabled = true
                UserDefaults.standard.set(true, forKey: "lowPowerNotificationsEnabled")
            }
            
            connect()
        }
        
        deinit {
            rawGRPCClient?.beginGracefulShutdown()
            try? group.syncShutdownGracefully()
        }
        
        func connect() {
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
                            self.connectionState = .disconnected
                        }
                    } catch {
                        print("gRPC client connection manager threw an error: \(error)")
                        await MainActor.run {
                            self.connectionState = .disconnected
                        }
                    }
                }
            } catch {
                print("Failed to initialize gRPC transport: \(error)")
                self.connectionState = .disconnected
            }
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
                    } catch {
                        // Older daemon without GetVersion RPC: treat as upgrade available
                        if let rpcError = error as? GRPCCore.RPCError, rpcError.code == .unimplemented {
                            self.installedDaemonBuildID = nil
                            if self.embeddedDaemonBuildID != nil {
                                self.installerState = .upgradeAvailable
                            }
                        } else {
                            // Leave as is; we won't force upgrade on other errors
                            self.installedDaemonBuildID = nil
                        }
                    }
                    // If embedded build is a dev/dirty build, prompt upgrade regardless, unless skipped
                    if let local = self.embeddedDaemonBuildID, local.hasSuffix("-dirty"), !self.skipUpgradeThisSession {
                        self.installerState = .upgradeAvailable
                    } else if let local = self.embeddedDaemonBuildID, let remote = self.installedDaemonBuildID, local != remote, !self.skipUpgradeThisSession {
                        self.installerState = .upgradeAvailable
                    }
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
                    lowPowerNotificationsEnabled: self.userIntent.lowPowerNotificationsEnabled
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
                        let charge = Int(response.currentCharge)
                        if threshold == 20 {
                            if !self.notifiedBelow20 && charge <= 20 {
                                self.notifiedBelow20 = true
                                let includeAction = !(response.lowPowerModeEnabled)
                                await NotificationsService.shared.postLowPowerAlert(threshold: 20, includeEnableAction: includeAction)
                            }
                        } else if threshold == 10 {
                            if !self.notifiedBelow10 && charge <= 10 {
                                self.notifiedBelow10 = true
                                let includeAction = !(response.lowPowerModeEnabled)
                                await NotificationsService.shared.postLowPowerAlert(threshold: 10, includeEnableAction: includeAction)
                            }
                        }
                    }
                }
                self.prevStatus = response
                // Reset debouncers with hysteresis
                let currentCharge = Int(response.currentCharge)
                if currentCharge >= 22 { self.notifiedBelow20 = false }
                if currentCharge >= 12 { self.notifiedBelow10 = false }

                if connectionState != .connected {
                    connectionState = .connected
                    if installerState != .upgradeAvailable { installerState = .installed }
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
        
        func setLimit(_ newLimit: Int) async {
            log("Setting charge limit to \(newLimit)%")
            guard let client = self.client else { return }
            
            var request = Rpc_SetChargeLimitRequest()
            request.limit = Int32(newLimit)
            
            do {
                _ = try await client.setChargeLimit(request)
            } catch {
                print("Error setting limit: \(error)")
            }
            
            if newLimit < 100 {
                self.userIntent.preferredChargeLimit = newLimit
                UserDefaults.standard.set(newLimit, forKey: "preferredChargeLimit")
                log("Saved preferred charge limit: \(newLimit)%")
            }

            await fetchStatus()
        }
        
        func setPowerFeature(feature: Rpc_PowerFeature, enable: Bool) async {
            log("Setting feature \(feature) to \(enable)")
            guard let client = self.client else { return }
            var req = Rpc_SetPowerFeatureRequest()
            req.feature = feature
            req.enable = enable
            do {
                _ = try await client.setPowerFeature(req)
            } catch {
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
            do {
                let ver = try await client.getVersion(Rpc_Empty())
                self.installedDaemonBuildID = ver.buildID
                if let local = self.embeddedDaemonBuildID, local == ver.buildID {
                    self.installerState = .installed
                } else {
                    self.installerState = .upgradeAvailable
                }
            } catch {
                // If version RPC still fails, leave IDs as-is; user can try again later
                print("Post-install GetVersion failed: \(error)")
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

        // Notifications are handled via NotificationsService
    }
