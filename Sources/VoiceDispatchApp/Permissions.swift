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

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var why: String {
            switch self {
            case .microphone: return "to record your spoken reply"
            case .inputMonitoring: return "to notice the ⌃⌥ hotkey while you're in another app"
            }
        }

        var settingsURL: String {
            switch self {
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
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
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
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
        }
    }

    static func openSettings(for kind: Kind) {
        guard let url = URL(string: kind.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    static var missing: [Kind] { Kind.allCases.filter { !isGranted($0) } }
    static var allGranted: Bool { missing.isEmpty }
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
            for kind in Permissions.missing {
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
        // Spoken, because that is the thing being confirmed.
        await SpeechChain(preferred: nil).speak(
            SpokenTextSanitizer().sanitize(
                "All set. Tap control option to hear what's waiting, hold to reply."))
    }
}
