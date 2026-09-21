import AppKit
import TranquilityCore

/// The one door for anything modal.
///
/// Ruled 19 Sep: anything that interrupts a person also reaches Slack, and
/// nobody sees the same alert ten times in a row. The panel's failure cards
/// already obey both through `Failures.report`; the app's `NSAlert`s did not,
/// which is how five dialogs could be shown and leave no record anywhere but
/// the screen. So every `NSAlert` in the app goes through here (a bare
/// `NSAlert()` outside this file is a lint failure, `scripts/check-alerts.sh`):
///
///   1. The alert is RECORDED, every time, as a Failure of the caller's kind
///      (`.notice` when it is only an interruption). The text is the app's own
///      words, never the user's, so it rides the product stream unredacted.
///   2. The alert is SHOWN unless the same `key` was shown inside
///      `AlertGate.window`. The gate's history is kept in defaults, so a
///      repeat from a fresh process is still a repeat.
///
/// The gate is for alerts the app raises on its own (a permission walk at
/// every launch, an updater that cannot start). An alert that answers a
/// click (a close refused, a key prompt from the menu) passes `gated: false`:
/// a person who asks twice is answered twice, and withholding it would read
/// as a dead button. A withheld alert answers `nil`, and the caller treats
/// that as the person having pressed the last (dismiss) button: nothing a
/// withheld alert would have asked can be assumed answered.
@MainActor
enum Alerts {
    private static let defaultsKey = "TBAlertsLastShown"
    private static var gate = AlertGate(lastShown: storedHistory())

    /// Run a modal, or withhold a repeat. Records either way.
    @discardableResult
    static func runModal(_ alert: NSAlert, key: String, kind: FailureKind = .notice,
                         gated: Bool = true,
                         file: StaticString = #fileID, line: UInt = #line) -> NSApplication.ModalResponse? {
        guard admit(alert, key: key, kind: kind, gated: gated, file: file, line: line) else { return nil }
        return alert.runModal()
    }

    /// Attach a sheet, or withhold a repeat. Returns whether it was shown.
    @discardableResult
    static func beginSheet(_ alert: NSAlert, on window: NSWindow, key: String,
                           kind: FailureKind = .notice, gated: Bool = true,
                           file: StaticString = #fileID, line: UInt = #line,
                           completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }) -> Bool {
        guard admit(alert, key: key, kind: kind, gated: gated, file: file, line: line) else { return false }
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in completion(response) }
        }
        return true
    }

    private static func admit(_ alert: NSAlert, key: String, kind: FailureKind, gated: Bool,
                              file: StaticString, line: UInt) -> Bool {
        let body = alert.informativeText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let reason = "alert [\(key)]: \(alert.messageText). \(body)"
        guard gated else {
            Failures.report(kind, reason: reason, card: alert.messageText, file: file, line: line)
            return true
        }
        switch gate.admit(key) {
        case .show:
            Failures.report(kind, reason: reason, card: alert.messageText, file: file, line: line)
            persist()
            return true
        case .withheld(let secondsAgo):
            Failures.report(kind, reason: reason + " (withheld: shown \(secondsAgo)s ago)",
                            card: alert.messageText, file: file, line: line)
            Permissions.log("alert: withheld repeat of [\(key)], shown \(secondsAgo)s ago")
            return false
        }
    }

    // MARK: - History

    private static func storedHistory() -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Date]) ?? [:]
    }

    private static func persist() {
        UserDefaults.standard.set(gate.lastShown, forKey: defaultsKey)
    }
}
