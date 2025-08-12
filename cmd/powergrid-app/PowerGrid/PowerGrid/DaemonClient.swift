// File: DaemonClient.swift

import Foundation
import GRPCCore
//import GRPCNIOTransportHTTP2 // seems redundant as we already import HTTP"Posix below
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import NIOPosix

@MainActor
class DaemonClient: ObservableObject {
    @Published var status: Rpc_StatusResponse?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var installerState: InstallerState = .unknown
    
    enum InstallerState: Equatable {
        case unknown
        case notInstalled
        case installing
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
        guard let client = self.client else { return }
        var req = Rpc_SetPowerFeatureRequest()
        req.feature = feature
        req.enable = enable
        do {
            _ = try await client.setPowerFeature(req)
            // Refresh status after change
            await fetchStatus()
        } catch {
            print("Error setting power feature: \(error)")
        }
    }
    
    // NEW: Function to install the daemon using the bundled helper.
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
        let command = "do shell script \"\\\"\(helperPath)\\\" \\\"\(resourcesPath)\\\"\" with administrator privileges"
        
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
    
    private func log(_ message: String) {
        print("[DaemonClient] \(message)")
    }
}
