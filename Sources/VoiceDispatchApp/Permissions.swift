import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import VoiceDispatchCore

/// Permission state and, more importantly, how to actually get it granted.
///
/// The first version showed two failure rows and left the user stranded — worse,
/// the app never appeared in the Input Monitoring pane at all, because macOS only
/// lists an app there once it has called `CGRequestListenEventAccess()`. Creating a
/// tap and having it fail is silent: no prompt, no listing, nothing to toggle.
@MainActor
struct Permissions {
    enum Kind: CaseIterable {
        case microphone
        case inputMonitoring
        case automation
        case accessibility

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .inputMonitoring: return "Input Monitoring"
            case .automation: return "Automation (Terminal)"
            case .accessibility: return "Accessibility"
            }
        }

        var why: String {
            switch self {
            case .microphone: return "to record your spoken reply"
            case .inputMonitoring: return "an alternative to Accessibility for the hotkeys"
            case .automation: return "to type replies into the right Terminal tab"
            case .accessibility: return "to notice the hotkeys, and type dictation at your cursor"
            }
        }

        /// Neither gesture permission is independently required, because macOS accepts
        /// EITHER for a listen-only `CGEvent` tap — see `gesturesGranted`.
        ///
        /// This used to mark `inputMonitoring` required and `accessibility` optional,
        /// which was backwards in the way that matters: on a normal Mac nothing
        /// requests Input Monitoring — Wispr Flow, Raycast and every comparable tool
        /// appear under Accessibility and that pane sits empty — so onboarding blocked
        /// on the one permission the user could not grant while calling the one that
        /// actually works a nice-to-have.
        var isRequired: Bool {
            switch self {
            case .microphone, .automation: return true
            case .accessibility, .inputMonitoring: return false
            }
        }

        /// Ask for Accessibility, not Input Monitoring. Both satisfy the tap; only
        /// Accessibility also gives dictation-at-cursor, and only Accessibility is
        /// where users already expect to find tools like this.
        var isPreferredForGestures: Bool { self == .accessibility }

        var settingsURL: String {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone: return base + "Privacy_Microphone"
            case .inputMonitoring: return base + "Privacy_ListenEvent"
            case .automation: return base + "Privacy_Automation"
            case .accessibility: return base + "Privacy_Accessibility"
            }
        }
    }

    /// Can we send Apple Events to Terminal? Queried WITHOUT prompting, so the
    /// checklist can show truth before the user acts. procNotFound means Terminal
    /// is not running, which is indeterminate rather than denied.
    private static func automationStatus() -> OSStatus {
        guard let desc = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
            .aeDesc?.pointee else { return OSStatus(procNotFound) }
        var target = desc
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    /// Append-only diagnostic log.
    ///
    /// Permission failures are invisible from the outside — no prompt, no error, no
    /// listing — so guessing at them wastes the user's time. This records what was
    /// actually called and what it returned.
    /// `nonisolated` because the speech and dispatch paths log from background
    /// executors. `Permissions` is `@MainActor`, so an isolated `log` traps under
    /// Swift 6's executor check — a diagnostic that kills the process the moment
    /// it is called from the code you most need to diagnose.
    nonisolated static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceDispatch/app.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    static func logEnvironment() {
        let bundle = Bundle.main
        log("bundleID=\(bundle.bundleIdentifier ?? "nil") path=\(bundle.bundlePath)")
        log("micUsageDescription=\(bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil)")
        log("micStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) "
            + "(\(statusDescription(.microphone)))")
        log("inputMonitoring=\(CGPreflightListenEventAccess())")
        log("automation=\(statusDescription(.automation)) accessibility=\(AXIsProcessTrusted())")
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        case .automation:
            return automationStatus() == noErr
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// The raw state, surfaced in the UI.
    ///
    /// "Not granted" covers three situations that need completely different actions:
    /// never asked (a prompt will appear), denied (macOS will never prompt again and
    /// the pane is the only route), and restricted (policy — nothing the user can
    /// do). Collapsing them into one warning triangle is what made this confusing.
    static func statusDescription(_ kind: Kind) -> String {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return "granted"
            case .notDetermined: return "not asked yet. Click Grant"
            case .denied: return "denied earlier. Switch it on in Settings"
            case .restricted: return "restricted by policy"
            @unknown default: return "unknown"
            }
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? "granted" : "not granted. Click Grant"
        case .automation:
            switch automationStatus() {
            case noErr: return "granted"
            case OSStatus(procNotFound): return "open Terminal first, then click Grant"
            case -1744: return "not asked yet. Click Grant"   // errAEEventWouldRequireUserConsent
            default: return "denied earlier. Switch it on in Settings"
            }
        case .accessibility:
            return AXIsProcessTrusted() ? "granted"
                : "optional. Click Grant to type dictation at your cursor"
        }
    }

    /// Ask the system. This is the call that also *registers* the app in the
    /// relevant Settings pane, which is what makes manual granting possible at all.
    static func request(_ kind: Kind) async -> Bool {
        switch kind {
        case .microphone:
            // Always attempt the request. It is a no-op once decided, and calling it
            // is what registers the app in the Microphone pane — an app that has
            // never asked does not appear there at all, so there is nothing to
            // switch on, which is exactly the dead end this hit.
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted || isGranted(kind)
        case .inputMonitoring:
            // Prompts the first time and lists the app thereafter. Safe to call
            // repeatedly — it returns the current state once already decided.
            return CGRequestListenEventAccess()
        case .automation:
            // The consent prompt only appears when an actual Apple Event is sent,
            // so send the most harmless one Terminal understands.
            _ = AppleScript.run(script: "tell application \"Terminal\" to count windows")
            return isGranted(kind)
        case .accessibility:
            FocusedInput.requestTrustOnce()
            return isGranted(kind)
        }
    }

    static func openSettings(for kind: Kind) {
        guard let url = URL(string: kind.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    static var missing: [Kind] { Kind.allCases.filter { !isGranted($0) } }

    /// Whether the gestures can work at all.
    ///
    /// A listen-only `CGEvent` tap is authorised by Accessibility OR Input Monitoring.
    /// Treating them as two independent requirements produced the worst possible
    /// outcome: the checklist reported a permission as missing while the tap it gates
    /// was working, and demanded one the user had no way to grant.
    static var gesturesGranted: Bool {
        isGranted(.accessibility) || isGranted(.inputMonitoring)
    }

    /// The core loop's gate: microphone and Automation, plus one of the two gesture
    /// permissions. Without a gesture permission nothing can be triggered at all, so
    /// unlike the old model this genuinely does block — it just accepts either route.
    static var allGranted: Bool {
        Kind.allCases.filter(\.isRequired).allSatisfy { isGranted($0) } && gesturesGranted
    }
}

/// Walks the user through whatever is missing, one step at a time.
///
/// macOS never re-prompts after a denial, so past the first ask the only route is
/// System Settings — which means the honest flow is: try to prompt, and if that
/// does nothing, take them to the exact pane and say precisely what to click.
@MainActor
final class PermissionOnboarding {
    private var isShowing = false

    func runIfNeeded(onChange: @escaping @MainActor () -> Void) {
        guard !isShowing, !Permissions.allGranted else { return }
        isShowing = true
        Task { @MainActor in
            defer { isShowing = false }
            for kind in Permissions.missing where kind.isRequired {
                await walk(kind)
                onChange()
            }
            if Permissions.allGranted { await celebrate() }
        }
    }

    private func walk(_ kind: Permissions.Kind) async {
        // First: actually ask. This both prompts (when undetermined) and registers
        // the app in Settings (which is what was missing before).
        if await Permissions.request(kind) { return }

        // Still not granted — so either it was denied before, or the pane needs a
        // manual toggle. Either way, guidance beats an error row.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Voice Dispatch needs \(kind.title)"
        alert.informativeText = """
            \(kind.title) is needed \(kind.why).

            macOS won't ask again once a choice has been made, so this one has to be \
            switched on by hand:

            1. The \(kind.title) pane will open.
            2. Find "Voice Dispatch" in the list and switch it on.
            3. Come back here — it picks up the change within a couple of seconds.
            """
        alert.addButton(withTitle: "Open \(kind.title) Settings")
        alert.addButton(withTitle: "Skip for now")

        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openSettings(for: kind)
            await waitForGrant(kind)
        }
    }

    /// Poll while the user is in Settings so the app can confirm the moment it lands,
    /// rather than making them come back and wonder whether it took.
    private func waitForGrant(_ kind: Permissions.Kind, timeout: TimeInterval = 120) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Permissions.isGranted(kind) { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func celebrate() async {
        // Spoken, because working audio is the thing being confirmed. In the good
        // voice or not at all: this is the first thing the app ever says, and the
        // system voice is a worse introduction than silence.
        await GreetingCache.speak(
            "All set. Tap control option to hear what's waiting, hold to reply.")
    }
}
