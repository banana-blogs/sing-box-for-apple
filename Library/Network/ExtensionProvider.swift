import Foundation
import Libbox
import NetworkExtension

open class ExtensionProvider: NEPacketTunnelProvider {
    public var username: String? = nil
    private var commandServer: LibboxCommandServer!
    private var boxService: LibboxBoxService!
    private var ignoreDeviceSleep = false
    private var systemProxyAvailable = false
    private var systemProxyEnabled = false
    private var platformInterface: ExtensionPlatformInterface!

    override open func startTunnel(options _: [String: NSObject]?) async throws {
        LibboxClearServiceError()

        if let username {
            var error: NSError?
            LibboxSetupWithUsername(FilePath.sharedDirectory.relativePath, FilePath.workingDirectory.relativePath, FilePath.cacheDirectory.relativePath, username, &error)
            if let error {
                writeFatalError("(packet-tunnel) error: setup service: \(error.localizedDescription)")
                return
            }
        } else {
            var isTVOS = false
            #if os(tvOS)
                isTVOS = true
            #endif
            LibboxSetup(FilePath.sharedDirectory.relativePath, FilePath.workingDirectory.relativePath, FilePath.cacheDirectory.relativePath, isTVOS)
        }

        var error: NSError?
        LibboxRedirectStderr(FilePath.cacheDirectory.appendingPathComponent("stderr.log").relativePath, &error)
        if let error {
            writeError("(packet-tunnel) redirect stderr error: \(error.localizedDescription)")
        }

        await LibboxSetMemoryLimit(!SharedPreferences.disableMemoryLimit.get())
        ignoreDeviceSleep = await SharedPreferences.ignoreDeviceSleep.get()

        if platformInterface == nil {
            platformInterface = ExtensionPlatformInterface(self)
        }
        commandServer = try await LibboxNewCommandServer(platformInterface, Int32(SharedPreferences.maxLogLines.get()))
        do {
            try commandServer.start()
        } catch {
            writeFatalError("(packet-tunnel): log server start error: \(error.localizedDescription)")
            return
        }
        writeMessage("(packet-tunnel) log server started")
        await startService()
    }

    func writeMessage(_ message: String) {
        if let commandServer {
            commandServer.writeMessage(message)
        } else {
            NSLog(message)
        }
    }

    func writeError(_ message: String) {
        writeMessage(message)
        var error: NSError?
        LibboxWriteServiceError(message, &error)
    }

    public func writeFatalError(_ message: String) {
        #if DEBUG
            NSLog(message)
        #endif
        writeError(message)
        cancelTunnelWithError(NSError(domain: message, code: 0))
    }

    private func startService() async {
        let profile: Profile?
        do {
            profile = try await ProfileManager.get(Int64(SharedPreferences.selectedProfileID.get()))
        } catch {
            writeFatalError("(packet-tunnel) error: missing default profile: \(error.localizedDescription)")
            return
        }
        guard let profile else {
            writeFatalError("(packet-tunnel) error: missing default profile")
            return
        }
        let configContent: String
        do {
            configContent = try await profile.read()
        } catch {
            writeFatalError("(packet-tunnel) error: read config file \(profile.path): \(error.localizedDescription)")
            return
        }
        var error: NSError?
        let service = LibboxNewService(configContent, platformInterface, &error)
        if let error {
            writeError("(packet-tunnel) error: create service: \(error.localizedDescription)")
            return
        }
        guard let service else {
            return
        }
        commandServer.setService(service)
        do {
            try service.start()
        } catch {
            commandServer.setService(nil)
            writeError("(packet-tunnel) error: start service: \(error.localizedDescription)")
            return
        }
        boxService = service
        #if os(macOS)
            await SharedPreferences.startedByUser.set(true)
        #endif
    }

    private func stopService() {
        if let service = boxService {
            do {
                try service.close()
            } catch {
                writeError("(packet-tunnel) error: stop service: \(error.localizedDescription)")
            }
            boxService = nil
            commandServer.setService(nil)
        }
        if let platformInterface {
            platformInterface.reset()
        }
    }

    func reloadService() async {
        writeMessage("(packet-tunnel) reloading service")
        reasserting = true
        defer {
            reasserting = false
        }
        stopService()
        await startService()
    }

    override open func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            try? server.close()
            commandServer = nil
        }
        #if os(macOS)
            if reason == .userInitiated {
                await SharedPreferences.startedByUser.set(reason == .userInitiated)
            }
        #endif
    }

    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        messageData
    }

    override open func sleep() async {
        if ignoreDeviceSleep {
            return
        }
        if let boxService {
            boxService.sleep()
        }
    }

    override open func wake() {
        if ignoreDeviceSleep {
            return
        }
        if let boxService {
            boxService.wake()
        }
    }
}
