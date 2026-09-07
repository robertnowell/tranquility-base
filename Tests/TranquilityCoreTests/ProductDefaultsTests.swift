import Foundation
import XCTest
@testable import TranquilityCore

final class ProductDefaultsTests: XCTestCase {
    func testMigrationCopiesMissingValuesAndNeverOverwritesSharedChoices() throws {
        let destinationName = "tb.defaults.destination.\(UUID().uuidString)"
        let destination = try XCTUnwrap(UserDefaults(suiteName: destinationName))
        defer {
            destination.removePersistentDomain(forName: destinationName)
        }

        destination.set("new voice", forKey: "systemVoiceIdentifier")

        ProductDefaults.migrate(
            keys: ["audioInputPreference", "systemVoiceIdentifier"],
            values: [
                "audioInputPreference": "systemDefault",
                "systemVoiceIdentifier": "old voice",
            ],
            to: destination)

        XCTAssertEqual(destination.string(forKey: "audioInputPreference"), "systemDefault")
        XCTAssertEqual(destination.string(forKey: "systemVoiceIdentifier"), "new voice")
    }
}
