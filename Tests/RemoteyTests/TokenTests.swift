import XCTest
@testable import Remotey

final class TokenTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("token") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-token-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    func testARotatedTokenIsWhatTheNextStartLoads() throws {
        let first = Token.load(from: file)
        XCTAssertNil(first.failure)
        XCTAssertEqual(Token.load(from: file).token, first.token, "kept across starts")
        let rotated = try Token.rotate(at: file)
        XCTAssertNotEqual(rotated, first.token)
        XCTAssertEqual(Token.load(from: file).token, rotated)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Only the token is left in the folder, no file written on the way.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["token"])
    }

    /// Before, the failed write went unnoticed: the agent used the new token, and after a restart the old one again.
    func testAFailedWriteThrowsAndLeavesTheOldTokenInPlace() throws {
        let old = Token.load(from: file).token
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try Token.rotate(at: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(Token.load(from: file).token, old)
    }

    func testATokenThatCannotBeSavedStillWorksAndSaysSo() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let loaded = Token.load(from: file)
        XCTAssertNotNil(loaded.failure)
        XCTAssertGreaterThanOrEqual(loaded.token.count, 32)
    }
}
