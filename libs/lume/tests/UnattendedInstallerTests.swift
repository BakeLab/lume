import Foundation
import Testing

@testable import lume

@MainActor
@Test("guest finalization refreshes Recovery user metadata")
func guestFinalizationRefreshesPreboot() {
    let script = UnattendedInstaller.guestFinalizationScript

    #expect(script.contains("/usr/sbin/diskutil apfs updatePreboot / >/dev/null"))
    #expect(script.contains("/bin/launchctl enable system/com.openssh.sshd"))
    #expect(script.contains("MARKER_OWNER=%u:%g"))
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
