import Foundation
import XCTest
@testable import TranquilityCore

final class ProductDefaultsTests: XCTestCase {
    func testMigrationCopiesMissingValuesAndNeverOverwritesSharedChoices() throws {
        let sourceName = "tb.defaults.source.\(UUID().uuidString)"
        let destinationName = "tb.defaults.destination.\(UUID().uuidString)"
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceName))
        let destination = try XCTUnwrap(UserDefaults(suiteName: destinationName))
        defer {
            source.removePersistentDomain(forName: sourceName)
            destination.removePersistentDomain(forName: destinationName)
        }

        source.set("systemDefault", forKey: "audioInputPreference")
        source.set("old voice", forKey: "systemVoiceIdentifier")
        destination.set("new voice", forKey: "systemVoiceIdentifier")

        ProductDefaults.migrate(
            keys: ["audioInputPreference", "systemVoiceIdentifier"],
            from: source, to: destination)

        XCTAssertEqual(destination.string(forKey: "audioInputPreference"), "systemDefault")
        XCTAssertEqual(destination.string(forKey: "systemVoiceIdentifier"), "new voice")
    }
}
