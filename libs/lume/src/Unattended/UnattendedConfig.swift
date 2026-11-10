import Foundation
import Yams

/// Configuration for unattended macOS installation
struct UnattendedConfig: Codable, Sendable {
    /// Seconds to wait before starting automation after VM boots
    let bootWait: Int

    /// Compatibility boot commands. Offline setup ignores these.
    let bootCommands: [String]

    /// Optional commands to run via SSH after offline setup.
    /// These are more reliable than typing in Terminal via VNC
    let postSshCommands: [String]?

    /// Account created by offline setup. Defaults to `lume` for compatibility.
    let guestUser: String

    enum CodingKeys: String, CodingKey {
        case bootWait = "boot_wait"
        case bootCommands = "boot_commands"
        case postSshCommands = "post_ssh_commands"
        case guestUser = "guest_user"
    }

    init(
        bootWait: Int = 60,
        bootCommands: [String],
        postSshCommands: [String]? = nil,
        guestUser: String = "lume"
    ) {
        self.bootWait = bootWait
        self.bootCommands = bootCommands
        self.postSshCommands = postSshCommands
        self.guestUser = guestUser
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bootWait = try values.decodeIfPresent(Int.self, forKey: .bootWait) ?? 60
        bootCommands = try values.decodeIfPresent([String].self, forKey: .bootCommands) ?? []
        postSshCommands = try values.decodeIfPresent([String].self, forKey: .postSshCommands)
        guestUser = try values.decodeIfPresent(String.self, forKey: .guestUser) ?? "lume"
        guard guestUser.range(of: #"^[a-zA-Z][a-zA-Z0-9_-]*$"#, options: .regularExpression) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .guestUser,
                in: values,
                debugDescription: "guest_user must be a valid local account name"
            )
        }
    }

    /// Load configuration from a YAML file path or preset name
    /// If the path matches a known preset name (e.g., "tahoe", "enable-ssh"), loads the built-in preset
    /// Otherwise, treats it as a file path
    static func load(from pathOrPreset: String) throws -> UnattendedConfig {
        // Check if it's a preset name first
        if let presetConfig = try? loadPreset(name: pathOrPreset) {
            return presetConfig
        }

        // Otherwise treat it as a file path
        let expandedPath = (pathOrPreset as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let yamlString = try String(contentsOf: url, encoding: .utf8)
        return try parse(yaml: yamlString)
    }

    /// Load a built-in preset by name
    static func loadPreset(name: String) throws -> UnattendedConfig {
        guard let url = Bundle.lumeResources.url(
            forResource: name,
            withExtension: "yml",
            subdirectory: "unattended-presets"
        ) else {
            throw UnattendedConfigError.presetNotFound(name)
        }

        let yamlString = try String(contentsOf: url, encoding: .utf8)
        return try parse(yaml: yamlString)
    }

    /// Check if a name is a known preset
    static func isPreset(name: String) -> Bool {
        return Bundle.lumeResources.url(
            forResource: name,
            withExtension: "yml",
            subdirectory: "unattended-presets"
        ) != nil
    }

    /// List all available preset names
    static func availablePresets() -> [String] {
        guard let resourceURL = Bundle.lumeResources.url(forResource: "unattended-presets", withExtension: nil),
              let contents = try? FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)
        else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "yml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Parse configuration from a YAML string
    static func parse(yaml: String) throws -> UnattendedConfig {
        let decoder = YAMLDecoder()
        return try decoder.decode(UnattendedConfig.self, from: yaml)
    }
}

/// Errors related to unattended configuration
enum UnattendedConfigError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidYaml(String)
    case missingRequiredField(String)
    case presetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Unattended config file not found: \(path)"
        case .invalidYaml(let message):
            return "Invalid YAML in unattended config: \(message)"
        case .missingRequiredField(let field):
            return "Missing required field in unattended config: \(field)"
        case .presetNotFound(let name):
            let available = UnattendedConfig.availablePresets()
            if available.isEmpty {
                return "Unattended preset '\(name)' not found"
            }
            return "Unattended preset '\(name)' not found. Available presets: \(available.joined(separator: ", "))"
        }
    }
}
