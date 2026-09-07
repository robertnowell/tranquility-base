import Foundation
import XCTest
@testable import TranquilityCore

final class AppOwnershipLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-app-owner-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecondIdentityIsRefusedWhileFirstOwnsTheMachine() throws {
        let production = try AppOwnershipLock.acquire(
            in: directory, owner: "production", pid: 101)
        XCTAssertThrowsError(
            try AppOwnershipLock.acquire(in: directory, owner: "development", pid: 202)
        ) { error in
            XCTAssertEqual(error as? AppOwnershipLock.AcquireError,
                           .alreadyHeld("production pid=101"))
        }
        withExtendedLifetime(production) {}
    }

    func testKernelReleasesOwnershipWhenHolderCloses() throws {
        var production: AppOwnershipLock? = try AppOwnershipLock.acquire(
            in: directory, owner: "production", pid: 101)
        production = nil
        let development = try AppOwnershipLock.acquire(
            in: directory, owner: "development", pid: 202)
        XCTAssertEqual(try String(contentsOf: development.url, encoding: .utf8),
                       "development pid=202")
        withExtendedLifetime(production) {}
    }
}
