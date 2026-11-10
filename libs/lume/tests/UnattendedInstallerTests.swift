import Foundation
import Testing

@testable import lume

@Test("legacy unattended SSH health checks are ignored")
func legacyUnattendedSSHHealthCheckIsIgnored() throws {
    let config = try UnattendedConfig.parse(yaml: """
        boot_wait: 0
        boot_commands: []
        health_check:
          type: ssh
          retries: 60
        """)

    #expect(config.bootCommands.isEmpty)
    #expect(config.postSshCommands == nil)
    #expect(config.guestUser == "lume")
}

@Test("unattended setup accepts an explicit guest account")
func unattendedGuestUserConfiguration() throws {
    let config = try UnattendedConfig.parse(yaml: """
        boot_commands: []
        guest_user: breadboard
        """)

    #expect(config.guestUser == "breadboard")
}

@MainActor
@Test("offline setup waits for the VM lifecycle to release its resources")
func offlineSetupWaitsForVMLifecycleCleanup() async {
    var lifecycleFinished = false
    let task = Task {
        try await Task.sleep(for: .milliseconds(30))
        lifecycleFinished = true
    }

    await UnattendedInstaller().waitForVMTask(task)

    #expect(lifecycleFinished)
}

@MainActor
@Test("offline setup grants its admin SSH access")
func offlineSetupAddsAdminToSSHAccessGroup() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lume-ssh-acl-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let groups = root.appendingPathComponent(
        "private/var/db/dslocal/nodes/Default/groups",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: true)

    let groupURL = groups.appendingPathComponent("com.apple.access_ssh.plist")
    let initialGroup: [String: [String]] = ["users": [], "groupmembers": []]
    let initialData = try PropertyListSerialization.data(
        fromPropertyList: initialGroup,
        format: .xml,
        options: 0
    )
    try initialData.write(to: groupURL)

    let user = MacOSOfflineSetupPatcher.GuestUser(
        username: "lume",
        realName: "lume",
        password: "lume",
        uid: "501",
        gid: "20"
    )
    let userUUID = "D9DB4889-CB20-4EF6-A2A4-08AA2B16037B"
    let patcher = MacOSOfflineSetupPatcher()

    try patcher.addUserToGroups(user, uuid: userUUID, mountPoint: root)
    try patcher.addUserToGroups(user, uuid: userUUID, mountPoint: root)

    let result = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: groupURL),
        options: [],
        format: nil
    ) as! [String: [String]]
    #expect(result["users"] == ["lume"])
    #expect(result["groupmembers"] == [userUUID])
}
