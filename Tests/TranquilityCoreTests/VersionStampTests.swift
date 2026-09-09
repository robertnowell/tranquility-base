import Foundation
import Testing
@testable import TranquilityCore

/// The menu's version row: no redundant build, and the install time.
struct VersionStampTests {
    let en = Locale(identifier: "en_US")

    @Test func releaseVersionDoesNotRepeatItsBuild() {
        let line = VersionStamp.line(short: "0.3.1127", build: "1127", installedAt: nil, locale: en)
        #expect(line == "Version 0.3.1127")
    }

    @Test func localBuildStillShowsItsBuild() {
        let line = VersionStamp.line(short: "0.1.0+abc1234", build: "1130", installedAt: nil, locale: en)
        #expect(line == "Version 0.1.0+abc1234 (1130)")
    }

    /// Anchored at local noon so "an hour ago" is the same day in every
    /// timezone CI might run in; a fixed epoch straddled midnight in UTC.
    private var noonToday: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    @Test func installTimeTodayIsJustTheTime() {
        let now = noonToday
        let installed = now.addingTimeInterval(-3600)
        let line = VersionStamp.line(short: "0.3.1127", build: "1127", installedAt: installed, now: now, locale: en)
        #expect(line.hasPrefix("Version 0.3.1127 \u{00B7} installed today "))
        #expect(!line.contains(","))
    }

    @Test func installTimeAnotherDayCarriesTheDate() {
        let now = noonToday
        let installed = now.addingTimeInterval(-3 * 86400)
        let line = VersionStamp.line(short: "0.3.1127", build: "1127", installedAt: installed, now: now, locale: en)
        #expect(line.contains("installed "))
        #expect(!line.contains("today"))
        let month = DateFormatter()
        month.locale = en
        month.setLocalizedDateFormatFromTemplate("MMM")
        #expect(line.contains(month.string(from: installed)))
    }

    @Test func theRunningBundleHasAnInstallDate() {
        #expect(VersionStamp.installedAt() != nil)
    }
}
