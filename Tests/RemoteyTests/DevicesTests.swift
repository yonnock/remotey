import XCTest
@testable import Remotey

extension Devices {
    /// A store in a folder of its own, so no test reads or writes the agent's.
    static func temporary(now: @escaping () -> Date = Date.init) -> Devices {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-devices-\(UUID().uuidString)")
        return Devices(file: folder.appendingPathComponent("devices"), now: now)
    }
}

final class DevicesTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appendingPathComponent("devices") }

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-devices-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The file alone opens nothing: whoever reads it has hashes, and a hash is no key.
    func testTheFileKeepsOnlyAHashOfTheKeyAndIsTheOwnersAlone() throws {
        let devices = Devices(file: file)
        let (device, key) = try devices.add(name: "iPhone", login: "someone@example.com")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains(key))
        XCTAssertTrue(text.contains(device.keyHash))
        XCTAssertEqual(devices.device(key: key), device)
        XCTAssertNil(devices.device(key: device.keyHash), "the hash from the file is not a key")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["devices"], "nothing written on the way")
    }

    func testDevicesAndSwitchesOutliveARestart() throws {
        let devices = Devices(file: file)
        XCTAssertTrue(devices.acceptsToken, "on at first: the phone paired the old way keeps working")
        XCTAssertFalse(devices.paused)
        let first = try devices.add(name: "iPhone", login: nil).device
        let second = try devices.add(name: "iPhone", login: nil).device
        XCTAssertEqual(second.name, "iPhone 2")
        try devices.rename(first.id, to: "  Arbeit  ")
        try devices.setAcceptsToken(false)
        try devices.setPaused(true)
        devices.noteMoved()
        let again = Devices(file: file)
        XCTAssertEqual(again.all.map(\.name), ["Arbeit", "iPhone 2"])
        XCTAssertFalse(again.acceptsToken)
        XCTAssertTrue(again.paused)
        XCTAssertTrue(again.moved)
        try again.revoke(first.id)
        XCTAssertEqual(Devices(file: file).all.map(\.id), [second.id])
        try again.revokeAll()
        XCTAssertTrue(Devices(file: file).all.isEmpty)
        XCTAssertThrowsError(try again.rename(second.id, to: " "))
    }

    /// A file that cannot be read may be one in which the token was switched off: it stays off.
    func testAFileThatCannotBeReadKeepsTheTokenOut() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let devices = Devices(file: file)
        XCTAssertFalse(devices.acceptsToken)
        XCTAssertTrue(devices.all.isEmpty)
    }

    /// A device that could not be saved does not exist: it would be gone after a restart.
    func testADeviceThatCannotBeSavedIsNotAdded() throws {
        let devices = Devices(file: file)
        _ = try devices.add(name: "iPhone", login: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try devices.add(name: "iPad", login: nil))
        XCTAssertEqual(devices.all.count, 1)
    }
}
