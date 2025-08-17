// File: DaemonClient.swift

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import NIOPosix

struct UserIntent: Equatable {
    // Default values
    var chargeLimit: Int = 80
    var preventDisplaySleep: Bool = false
    var preventSystemSleep: Bool = false
    var forceDischarge: Bool = false
    var menuBarDisplayStyle: MenuBarDisplayStyle = .iconAndText // Add the new property with a default
}

@MainActor
class DaemonClient: ObservableObject {
    //@Published var status: Rpc_StatusResponse?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var installerState: InstallerState = .unknown
    
    @Published private(set) var status: Rpc_StatusResponse?
    // 2. Add a didSet observer to userIntent to automatically save the setting.
    @Published var userIntent = UserIntent() {
        didSet {
            // This observer fires whenever userIntent is changed.
            // We check if the display style is what changed, and if so, save it.
            if userIntent.menuBarDisplayStyle != oldValue.menuBarDisplayStyle {
                UserDefaults.standard.set(userIntent.menuBarDisplayStyle.rawValue, forKey: AppSettings.menuBarDisplayStyleKey)
                log("Saved menu bar display style: \(userIntent.menuBarDisplayStyle.rawValue)")
            }
        }
    }
    
    enum InstallerState: Equatable {
        case unknown
        case notInstalled
        case installing
        case uninstalling
        case installed
        case failed(String)
    }
    
    enum ConnectionState {
        case connected
        case disconnected
        case connecting
    }
    
    // Use the exact types discovered in the documentation.
    private var client: Rpc_PowerGrid.Client<HTTP2ClientTransport.Posix>?
    private var transport: HTTP2ClientTransport.Posix?
    private var rawGRPCClient: GRPCClient<HTTP2ClientTransport.Posix>? // Store the raw client
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    
    init() {
        // Load the saved display style from UserDefaults.
        if let savedValue = UserDefaults.standard.string(forKey: AppSettings.menuBarDisplayStyleKey),
           let style = MenuBarDisplayStyle(rawValue: savedValue) {
            // If a value was found, apply it to our initial userIntent.
            self.userIntent.menuBarDisplayStyle = style
            log("Loaded menu bar display style: \(style.rawValue)")
        }
        
        // Now proceed with the connection.
        connect()
    }
    
    deinit {
        // As per docs, call beginGracefulShutdown() on the client.
        rawGRPCClient?.beginGracefulShutdown()
        try? group.syncShutdownGracefully()
    }
    
    func connect() {
        connectionState = .connecting
        
        do {
            // 1. Create the transport using the new API you found.
            let newTransport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: "/var/run/powergrid.sock"),
                transportSecurity: .plaintext, // Plaintext is correct for a local socket
                eventLoopGroup: self.group
            )
            self.transport = newTransport
            
            // 2. Store the raw client to manage its lifecycle.
            let grpcClient = GRPCClient(transport: newTransport)
            self.rawGRPCClient = grpcClient
            
            self.client = Rpc_PowerGrid.Client(wrapping: grpcClient)
            
            // 3. IMPORTANT: The transport must be run in a background task.
            Task.detached {
                do {
                    // THE KEY FIX #1: Call runConnections() on the raw client.
                    try await grpcClient.runConnections()
                    // If run() finishes, it means the connection closed.
                    await MainActor.run {
                        self.connectionState = .disconnected
                    }
                } catch {
                    // Handle errors from the running connection.
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
            let response = try await client.getStatus(Rpc_Empty())
            self.status = response
            
            // 4. CRITICAL FIX: Preserve the UI setting when updating state from the daemon.
            // Create an intent based on the daemon's response...
            let latestIntentFromServer = UserIntent(
                chargeLimit: Int(response.chargeLimit),
                preventDisplaySleep: response.preventDisplaySleepActive,
                preventSystemSleep: response.preventSystemSleepActive,
                forceDischarge: response.forceDischargeActive,
                // ...but PRESERVE the existing UI preference, which the daemon doesn't know about.
                menuBarDisplayStyle: self.userIntent.menuBarDisplayStyle
            )
                       
            // This logic now works perfectly. It compares the daemon-related state
            // and won't overwrite our UI preference.
            if self.userIntent != latestIntentFromServer {
                self.userIntent = latestIntentFromServer
            }
            
            if connectionState != .connected {
                connectionState = .connected
                installerState = .installed // Successfully connected, so it must be installed.
            }
        } catch {
            // 1. Cast directly to the main RPCError type.
            if let rpcError = error as? GRPCCore.RPCError {
                // 2. Check the error's 'code' property for connection issues.
                // .unavailable is the standard code for when the connection is down.
                if rpcError.code == .unavailable {
                    print("Connection is unavailable or closed.")
                } else {
                    // It's a different kind of gRPC error (e.g., "not found", "invalid argument").
                    print("A gRPC error occurred: \(rpcError.message) (Code: \(rpcError.code))")
                }
            } else {
                // It's not a gRPC error, but some other Swift error.
                print("An unknown error occurred: \(error)")
            }
            
            self.status = nil
            self.connectionState = .disconnected
            if self.installerState != .installing {
                installerState = .notInstalled
            }
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
        
        await fetchStatus()
    }

    // Toggle or set a power feature via RPC
    func setPowerFeature(feature: Rpc_PowerFeature, enable: Bool) async {
        log("Setting feature \(feature) to \(enable)")
        guard let client = self.client else { return }
        var req = Rpc_SetPowerFeatureRequest()
        req.feature = feature
        req.enable = enable
        do {
            _ = try await client.setPowerFeature(req)
            // Refresh status after change
        } catch {
            print("Error setting power feature: \(error)")
        }
        
        await fetchStatus()
    }
    
    // Function to install the daemon using the bundled helper.
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
        
        // The command needs to be quoted properly to handle spaces in paths.
        let command = "do shell script \"\\\"\(helperPath)\\\" install \\\"\(resourcesPath)\\\"\" with administrator privileges"
        
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: command)
        
        // Running the script is synchronous, so we run it in a detached task.
        let success = await Task.detached {
            return script?.executeAndReturnError(&errorDict) != nil
        }.value
        
        if success {
            self.installerState = .installed
            log("Daemon installed successfully. Attempting to connect...")
            // Give the daemon a moment to start up before connecting
            try? await Task.sleep(for: .seconds(2))
            self.connect()
            await self.fetchStatus()
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

    // Function to uninstall the daemon using the bundled helper.
    func uninstallDaemon() async {
        self.installerState = .uninstalling
        
        guard let helperPath = Bundle.main.path(forResource: "powergrid-helper", ofType: nil) else {
            self.installerState = .failed("Helper tool not found in app bundle.")
            return
        }
        
        // The command for uninstalling is simpler, it just needs the action verb.
        let command = "do shell script \"\\\"\(helperPath)\\\" uninstall\" with administrator privileges"
        
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: command)
        
        // Running the script is synchronous, so we run it in a detached task.
        let success = await Task.detached {
            return script?.executeAndReturnError(&errorDict) != nil
        }.value
        
        if success {
            log("Daemon uninstalled successfully.")
            // Clean up the connection state since the daemon is gone.
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
}
