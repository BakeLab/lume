import Foundation

/// Runs commands explicitly configured for unattended setup over SSH.
struct PostSshCommandRunner {
    func run(commands: [String], vmIP: String, user: String, password: String) async throws {
        Logger.info("Running post-SSH commands", metadata: [
            "host": vmIP,
            "user": user,
            "commandCount": "\(commands.count)"
        ])

        let sshClient = SSHClient(
            host: vmIP,
            port: 22,
            user: user,
            password: password
        )

        for (index, command) in commands.enumerated() {
            Logger.info("Executing SSH command", metadata: [
                "index": "\(index + 1)/\(commands.count)",
                "command": command.prefix(50).description
            ])

            let escapedPassword = password.replacingOccurrences(of: "'", with: "'\\''")
            let actualCommand: String
            if command.contains("sudo ") {
                actualCommand = command.replacingOccurrences(
                    of: "sudo ",
                    with: "echo '\(escapedPassword)' | sudo -S "
                )
            } else {
                actualCommand = command
            }

            do {
                let result = try await sshClient.executeWithFallback(command: actualCommand, timeout: 60)

                if result.exitCode != 0 {
                    Logger.info("SSH command returned non-zero exit code", metadata: [
                        "command": command.prefix(50).description,
                        "exitCode": "\(result.exitCode)",
                        "output": result.output.prefix(200).description
                    ])
                }
            } catch {
                Logger.info("SSH command failed", metadata: [
                    "command": command.prefix(50).description,
                    "error": error.localizedDescription
                ])
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        Logger.info("Post-SSH commands completed")
    }
}
