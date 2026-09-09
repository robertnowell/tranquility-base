import Foundation

/// The one line that says which build this is and when it arrived.
public enum VersionStamp {
    /// "Version 0.3.1127 · installed Sep 9, 1:29 PM". The build appears in
    /// parentheses only when the version string does not already end in it.
    public static func line(short: String, build: String, installedAt: Date?,
                            now: Date = Date(), locale: Locale = .current) -> String {
        var text = "Version \(short)"
        if !short.hasSuffix(".\(build)") && short != build {
            text += " (\(build))"
        }
        if let installedAt {
            text += " \u{00B7} installed \(installedText(installedAt, now: now, locale: locale))"
        }
        return text
    }

    /// When the running bundle landed on disk. Sparkle's install and a
    /// drag-install both set the bundle's modification date at that moment;
    /// nothing in normal use touches it afterwards.
    public static func installedAt(bundle: Bundle = .main) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: bundle.bundleURL.path)
        return attrs?[.modificationDate] as? Date
    }

    /// "1:29 PM" today, "Sep 9, 1:29 PM" otherwise, in the user's locale.
    static func installedText(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
        formatter.setLocalizedDateFormatFromTemplate(sameDay ? "jmm" : "MMMd jmm")
        return (sameDay ? "today " : "") + formatter.string(from: date)
    }
}
