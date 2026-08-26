import AppKit
import AVFoundation
import Speech
import CoreGraphics
import Foundation
import TranquilityCore

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
        case speechRecognition
        case inputMonitoring
        case accessibility

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            case .inputMonitoring: return "Input Monitoring"
            case .accessibility: return "Accessibility"
            }
        }

        var why: String {
            switch self {
            case .microphone: return "to record your spoken reply"
            case .speechRecognition: return "so transcription still works when the network is down"
            case .inputMonitoring: return "to notice the hotkeys while you're in another app (measured: Accessibility alone does NOT do this)"
            case .accessibility: return "so dictation can type at your cursor"
            }
        }

        /// The four that block. Ruled 07 Aug: "it's either required or it's not — make them
        /// both required or get rid of one." The first attempt got rid of Input
        /// Monitoring on the reasoning that a `.listenOnly` tap is authorised by
        /// either permission and Accessibility is needed anyway for typing at the
        /// cursor. The documentation agrees with that reasoning. It is wrong.
        ///
        /// MEASURED 08 Aug, on a purpose-built probe with its own bundle id (so
        /// it inherited nothing) while a second process posted a keystroke every
        /// 400ms so that "no events" could not mean "nobody typed":
        ///
        ///     accessibility=true  listenEventAccess=false
        ///     tapEnabled=false    eventsReceived=0
        ///
        /// Accessibility alone leaves the tap created but DISABLED and silent.
        /// Input Monitoring is what carries the gestures; Accessibility is what
        /// carries dictation-at-cursor. Both are load-bearing, so both are
        /// required, and neither may be quietly dropped again without repeating
        /// that experiment.
        /// Speech Recognition is the one that does NOT block.
        ///
        /// The other four gate the core loop: without them the app cannot hear
        /// you, cannot see the hotkey, cannot type into a tab. Without this one
        /// the app works — dictation still runs on the cloud provider, and the
        /// two features that need it degrade honestly and fast (the recovery
        /// chain skips the on-device provider; the courtesy check speaks rather
        /// than holding).
        ///
        /// It was briefly required on 10 Aug and that was wrong: `allGranted`
        /// went false on a machine where it had never been asked for, which put
        /// the onboarding window on screen at every launch of an app that starts
        /// from a login item. Asked for, visible, never blocking.
        var isRequired: Bool {
            switch self {
            case .speechRecognition: return false
            case .microphone, .inputMonitoring, .accessibility: return true
            }
        }

        var settingsURL: String {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone: return base + "Privacy_Microphone"
            case .speechRecognition: return base + "Privacy_SpeechRecognition"
            case .inputMonitoring: return base + "Privacy_ListenEvent"
            case .accessibility: return base + "Privacy_Accessibility"
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
    /// Disk ceiling for the log: this file plus one rolled predecessor, so the
    /// worst case on disk is twice this. Unbounded, it reached 2.3 GB in five
    /// days — see `Coordinator.reportNewlyGone` for the call site that did it.
    /// Fixing a chatty caller is the real repair; this is the backstop that keeps
    /// the next one from filling the volume before anyone notices.
    /// `nonisolated` for the same reason `log` is: the speech and dispatch paths
    /// write from background executors, and `Permissions` is `@MainActor`.
    private nonisolated static let logSizeLimit: off_t = 32 * 1024 * 1024
    private nonisolated static let rollLock = NSLock()

    /// Stamped once — the pid never changes and the formatter is not free.
    private nonisolated static let pidTag = "[\(ProcessInfo.processInfo.processIdentifier)]"

    nonisolated static func log(_ message: String) {
        // The pid rides every line: thirteen launches wrote to this one file
        // on 12 Aug (relaunches + worktree drill builds), and every
        // log-derived statistic silently mixed instances. With the tag, one
        // grep separates them — and the mic acceptance run can measure
        // exactly the process it deployed.
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(Self.pidTag)  \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceDispatch/app.log")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        // O_APPEND leaves the offset at end-of-file after the write, so the size
        // comes free — no stat on the hot path.
        let size = lseek(fd, 0, SEEK_CUR)
        close(fd)
        if size > logSizeLimit { roll(url) }
    }

    /// Rename the log aside and let the next write create a fresh one. Rename is
    /// atomic, so a concurrent writer either lands in the old file or the new one
    /// — never in a half-truncated file, which is what `truncate` would risk.
    private nonisolated static func roll(_ url: URL) {
        rollLock.lock()
        defer { rollLock.unlock() }
        // Re-check under the lock: several threads can pass the size test at once,
        // and without this the second one rolls the fresh file straight away.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        guard size > logSizeLimit else { return }
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    static func logEnvironment() {
        let bundle = Bundle.main
        log("bundleID=\(bundle.bundleIdentifier ?? "nil") path=\(bundle.bundlePath)")
        log("micUsageDescription=\(bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil)")
        // Speech status is logged but is NOT a gate — measured 10 Aug: the
        // recogniser transcribes with the status still at notDetermined, so
        // requiring it put an onboarding window in front of a permission the app
        // does not actually need.
        log("speechStatus=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        log("micStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) "
            + "(\(statusDescription(.microphone)))")
        log("inputMonitoring=\(CGPreflightListenEventAccess())")
        log("accessibility=\(AXIsProcessTrusted())")
        // The DERIVED states, not just the raw TCC answers. The gate opens on
        // `allActive`, which can differ from "granted" by a whole state
        // (`pendingRestart`), and the difference decides whether a returning
        // user sees a setup window they already finished. Logged at launch so
        // that question is a grep and never a guess.
        log("states " + Kind.allCases.map { "\($0.title.prefix(4))=\(state($0))" }
                .joined(separator: " ")
            + " allActive=\(allActive) progress=\(progress.done)/\(progress.total)")
    }

    /// What a permission actually IS right now, at the granularity the user
    /// has to act on.
    ///
    /// "Granted" was hiding a fifth state. macOS records the grant instantly,
    /// but a process that was already running when the grant landed cannot
    /// always USE it — Input Monitoring's event tap is created at launch, and
    /// `tapCreate` keeps returning nil until the app restarts. A checklist that
    /// only knows granted/not-granted paints that row green and then the
    /// hotkeys do not work, which is the worst of the two wrong answers.
    ///
    /// So `pendingRestart` is a state, and it is DERIVED rather than declared:
    /// TCC says yes, the live probe says no. No table anywhere lists which
    /// permissions need a restart, because such a table would be a guess that
    /// rots. The measurement is the answer.
    enum State: Equatable {
        case notAsked        // never asked — a prompt will appear
        case denied          // macOS will not ask again; Settings is the only route
        case restricted      // policy; nothing the user can do
        case pendingRestart  // granted, but this process cannot use it yet
        case active          // granted AND working right now
    }

    /// How the app asks "is the tap actually delivering?".
    ///
    /// Set once at launch by `AppDelegate`. `Permissions` is a static struct and
    /// has no route to the running `HotkeyMonitor`, and the alternative — having
    /// this file reach for the app delegate — would make a permission model
    /// depend on a window. Absent a probe the answer is `true`: never invent a
    /// restart prompt out of missing information.
    @MainActor static var listeningProbe: (() -> Bool)?

    /// Forced states, for rendering the checklist in situations this machine is
    /// not in. Preview and drills only — set by `--dump-onboarding`, never in a
    /// normal launch.
    ///
    /// It exists because the states that matter are the ones a developer machine
    /// cannot reach: every permission here has been granted for weeks, so the
    /// only view anyone ever sees of this window is four green dots and an
    /// enabled button. The half-done view — a dimmed row, an orange "restart to
    /// finish", a disabled Start — shipped unlooked-at for exactly that reason,
    /// which is the same shape as the crash that started all this: the path
    /// nobody can run is the path nobody checks.
    @MainActor static var previewStates: [Kind: State]?

    static func state(_ kind: Kind) -> State {
        if let forced = previewStates?[kind] { return forced }
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .active
            case .notDetermined: return .notAsked
            case .denied: return .denied
            case .restricted: return .restricted
            @unknown default: return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .active
            case .notDetermined: return .notAsked
            case .denied: return .denied
            case .restricted: return .restricted
            @unknown default: return .denied
            }
        case .inputMonitoring:
            // The one row where "recorded" and "usable" can disagree.
            guard CGPreflightListenEventAccess() else { return .notAsked }
            return (listeningProbe?() ?? true) ? .active : .pendingRestart
        case .accessibility:
            if AXIsProcessTrusted() { return .active }
            // Not trusted. That is EITHER never-granted or granted-and-this-
            // process-cannot-see-it, and preflight cannot tell them apart —
            // both read false.
            //
            // The repo holds both answers and they disagree. `waitForGrant`
            // polls for two minutes and the onboarding copy promises the dot
            // goes green "within a couple of seconds"; `reset-permissions.sh`
            // step 3 says relaunch, "AXIsProcessTrusted() is evaluated when the
            // process starts, so a running instance cannot see it". Rather than
            // pick a winner and hard-code it, ask the clock: if we asked and it
            // has not gone true within the grace period, the optimistic answer
            // has been falsified for this machine and this OS, and a restart is
            // the honest next instruction.
            //
            // This is also why there is no table of which permissions need a
            // restart. macOS changes; the measurement does not go stale.
            guard let asked = accessibilityAskedAt else { return .notAsked }
            return Date().timeIntervalSince(asked) > liveGrantGrace
                ? .pendingRestart : .notAsked
        }
    }

    /// When `request(.accessibility)` last put the system dialog up. See the
    /// `.accessibility` branch of `state(_:)` for why a timestamp and not a flag.
    @MainActor private static var accessibilityAskedAt: Date?

    /// How long a freshly-granted permission gets to show up in a running
    /// process before the checklist stops waiting and asks for a restart.
    ///
    /// Eight seconds because the optimistic claim in the onboarding copy is "a
    /// couple of seconds" and the polling loop it came from runs at 1Hz — so
    /// this is that promise plus room for a slow machine, not a number chosen
    /// to feel patient.
    private static let liveGrantGrace: TimeInterval = 8

    /// The gate: every REQUIRED permission granted AND usable in this process.
    /// Stronger than `allGranted`, which cannot see the restart gap.
    static var allActive: Bool {
        Kind.allCases.filter(\.isRequired).allSatisfy { state($0) == .active }
    }

    /// Anything granted that this process still cannot use. One restart clears
    /// all of them at once, which is why the checklist asks once at the end
    /// rather than after each grant.
    static var pendingRestart: [Kind] {
        Kind.allCases.filter { state($0) == .pendingRestart }
    }

    /// Progress across the whole list, required or not — "2 of 4 done".
    ///
    /// Read from live TCC state, never from stored progress, which is what
    /// makes it survive the restart the checklist itself asks for: the system
    /// remembers the grants, so a relaunched app opens already knowing how far
    /// the user got. There is nothing to persist and nothing to get out of sync.
    static var progress: (done: Int, total: Int) {
        (Kind.allCases.filter { state($0) == .active }.count, Kind.allCases.count)
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition:
            return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
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
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return "granted"
            case .notDetermined: return "not asked yet. Click Grant"
            case .denied: return "denied earlier. Switch it on in Settings"
            case .restricted: return "restricted by policy"
            @unknown default: return "unknown"
            }
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? "granted" : "not granted. Click Grant"
        case .accessibility:
            return AXIsProcessTrusted() ? "granted"
                : "not granted. Click Grant, dictation types at your cursor with it"
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
        case .speechRecognition:
            // Asked HERE and nowhere else.
            //
            // There is no implicit prompt: `recognitionTask` never triggers one,
            // and until something calls this the status sits at `notDetermined`
            // forever. Measured 10 Aug — the app had run for days with the usage
            // string in its Info.plist, the recogniser never once usable, and no
            // call site for this method anywhere in Sources/. One probe call
            // moved it straight to `.authorized`.
            //
            // And the courtesy check must never be the caller. Its whole purpose
            // is not interrupting; a check that opens with a permission dialog
            // has interrupted harder than the announcement it was being polite
            // about. Onboarding or not at all.
            //
            // `@Sendable` on the handler is LOAD-BEARING, not decoration.
            //
            // `Permissions` is `@MainActor`. In Swift 6 a closure literal that
            // is not `@Sendable` and is formed in an actor-isolated context
            // INHERITS that isolation, and ObjC block parameters import as
            // non-Sendable unless the header says otherwise — Speech's does
            // not. So without this keyword the compiler quietly makes this
            // handler main-actor code and writes a `swift_task_isCurrentExecutor`
            // check into its prologue. TCC delivers the reply on
            // `com.apple.root.default-qos` (measured; and the SDK header says
            // so outright: "The system does not guarantee the execution of this
            // block on your app's main dispatch queue"), the check fails, and
            // the process takes a SIGTRAP.
            //
            // That is not a hypothetical: it killed 0.1.0 on the first external
            // user's Mac, 25 Aug 2026, incident 51344D00, the moment they
            // pressed Grant. The compiler emitted no error, no warning and no
            // note — strict concurrency was fully on and had nothing to say.
            //
            // `@Sendable` opts the closure OUT of isolation inheritance, so no
            // check is emitted and none is needed: `resume(returning:)` is safe
            // from any thread by design. `speechCallbackDrill` holds this.
            _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    c.resume(returning: status)
                }
            }
            return isGranted(kind)
        case .inputMonitoring:
            // Prompts the first time and lists the app thereafter. Safe to call
            // repeatedly — it returns the current state once already decided.
            return CGRequestListenEventAccess()
        case .accessibility:
            FocusedInput.requestTrustOnce()
            // Start the clock. If the grant does not reach this process before
            // the grace period is up, the checklist switches from "click Grant"
            // to "restart to finish" on its own.
            if accessibilityAskedAt == nil { accessibilityAskedAt = Date() }
            return isGranted(kind)
        }
    }

    static func openSettings(for kind: Kind) {
        guard let url = URL(string: kind.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    static var missing: [Kind] { Kind.allCases.filter { !isGranted($0) } }
    /// The core loop's gate: required permissions only. Accessibility never blocks.
    static var allGranted: Bool {
        Kind.allCases.filter(\.isRequired).allSatisfy { isGranted($0) }
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
        alert.messageText = "Tranquility Base needs \(kind.title)"
        alert.informativeText = """
            \(kind.title) is needed \(kind.why).

            macOS won't ask again once a choice has been made, so this one has to be \
            switched on by hand:

            1. The \(kind.title) pane will open.
            2. Find "Tranquility Base" in the list and switch it on.
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
