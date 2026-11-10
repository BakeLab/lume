import Foundation

/// Orchestrates unattended macOS installation
@MainActor
final class UnattendedInstaller {
    /// Run unattended setup on a VM by patching the installed macOS disk offline.
    func install(
        vm: VM,
        config: UnattendedConfig,
        vncPort: Int = 0,
        noDisplay: Bool = false,
        debug: Bool = false,
        debugDir: String? = nil
    ) async throws {
        Logger.info("Starting offline unattended installation", metadata: [
            "vm": vm.name,
            "configBootCommandCount": "\(config.bootCommands.count)",
            "postSshCommandCount": "\(config.postSshCommands?.count ?? 0)",
            "verifyVncPort": "\(vncPort)",
            "compatNoDisplayFlag": "\(noDisplay)",
            "compatDebugFlag": "\(debug)",
            "compatDebugDir": debugDir ?? "default"
        ])

        try await materializeFirstBootState(vm: vm, vncPort: vncPort)

        let patcher = MacOSOfflineSetupPatcher()
        try patcher.patch(vm: vm, guestUser: config.guestUser)

        try await verifyBoot(vm: vm, config: config, vncPort: vncPort)
    }

    private func materializeFirstBootState(vm: VM, vncPort: Int) async throws {
        Logger.info("Starting VM once to materialize first-boot state before offline patch", metadata: [
            "vm": vm.name
        ])

        var vmStartError: Error?
        let vmTask = Task {
            do {
                try await vm.run(
                    displayMode: .none,
                    sharedDirectories: [],
                    mount: nil,
                    vncPort: vncPort,
                    recoveryMode: false,
                    usbMassStoragePaths: []
                )
            } catch {
                vmStartError = error
                throw error
            }
        }

        try await Task.sleep(nanoseconds: 2_000_000_000)

        if let error = vmStartError {
            Logger.error("VM failed to start during first-boot materialization", metadata: [
                "error": error.localizedDescription
            ])
            throw error
        }

        do {
            let vmIP = try await waitForIPAddress(vm: vm, timeoutSeconds: 120)
            Logger.info("First-boot state materialized enough for offline patch", metadata: [
                "vm": vm.name,
                "ip": vmIP
            ])
        } catch {
            try? await vm.stop()
            await waitForVMTask(vmTask)
            throw error
        }

        try await Task.sleep(nanoseconds: 10_000_000_000)

        Logger.info("Stopping VM before offline patch", metadata: ["vm": vm.name])
        try? await vm.stop()
        await waitForVMTask(vmTask)
    }

    private func verifyBoot(vm: VM, config: UnattendedConfig, vncPort: Int) async throws {
        Logger.info("Starting VM to verify offline unattended setup boot", metadata: [
            "vm": vm.name
        ])

        var vmStartError: Error?
        let vmTask = Task {
            var attempts = 0
            let maxAttempts = 3
            while attempts < maxAttempts {
                do {
                    try await vm.run(
                        displayMode: .none,
                        sharedDirectories: [],
                        mount: nil,
                        vncPort: vncPort,
                        recoveryMode: false,
                        usbMassStoragePaths: []
                    )
                    return
                } catch {
                    let errorDescription = error.localizedDescription
                    if errorDescription.contains("auxiliary storage") || errorDescription.contains("Failed to lock") {
                        attempts += 1
                        if attempts < maxAttempts {
                            Logger.info("VM start failed due to auxiliary storage lock, retrying", metadata: [
                                "attempt": "\(attempts)/\(maxAttempts)",
                                "waitTime": "5s"
                            ])
                            try await Task.sleep(nanoseconds: 5_000_000_000)  // Wait 5 seconds before retry
                            continue
                        }
                    }
                    vmStartError = error
                    throw error
                }
            }
        }

        try await Task.sleep(nanoseconds: 2_000_000_000)

        if let error = vmStartError {
            Logger.error("VM failed to start", metadata: ["error": error.localizedDescription])
            throw error
        }

        do {
            let vmIP = try await waitForIPAddress(vm: vm, timeoutSeconds: 300)
            Logger.info("Offline setup guest booted and received a DHCP lease", metadata: [
                "vm": vm.name,
                "ip": vmIP
            ])

            if let postCommands = config.postSshCommands, !postCommands.isEmpty {
                Logger.info("Running explicitly configured post-SSH commands", metadata: ["count": "\(postCommands.count)"])
                try await PostSshCommandRunner().run(
                    commands: postCommands,
                    vmIP: vmIP,
                    user: config.guestUser,
                    password: "lume"
                )
                Logger.info("Post-SSH commands completed")
            }

            Logger.info("Offline unattended setup verified - stopping VM")
            try? await vm.stop()
            await waitForVMTask(vmTask)
            Logger.info("VM stopped", metadata: ["name": vm.name])
        } catch {
            Logger.error("Offline unattended setup boot verification failed", metadata: [
                "error": error.localizedDescription
            ])
            try? await vm.stop()
            await waitForVMTask(vmTask)
            Logger.info("VM stopped after failure", metadata: ["name": vm.name])
            throw error
        }
    }

    /// Wait for VM.run to finish its lifecycle cleanup before callers inspect,
    /// patch, or delete the VM's disk. stop() powers the guest off; awaiting the
    /// task releases the Virtualization.framework objects that still own it.
    func waitForVMTask(_ task: Task<Void, Error>) async {
        if case .failure(let error) = await task.result,
           !(error is CancellationError)
        {
            Logger.debug("VM lifecycle task ended with an error during shutdown", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    private func waitForIPAddress(vm: VM, timeoutSeconds: Int) async throws -> String {
        guard let macAddress = vm.vmDirContext.config.macAddress else {
            throw UnattendedError.vmIPAddressUnavailable("VM MAC address not available")
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let ip = DHCPLeaseParser.getIPAddress(forMAC: macAddress) {
                Logger.info("Found VM IP for offline setup verification", metadata: [
                    "vm": vm.name,
                    "ip": ip
                ])
                return ip
            }

            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        throw UnattendedError.vmIPAddressUnavailable("No DHCP lease after \(timeoutSeconds)s")
    }
}
