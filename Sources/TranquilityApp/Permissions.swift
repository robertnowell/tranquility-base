import AppKit
import AVFoundation
import Speech
import CoreGraphics
import CoreServices
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
        /// Apple Events — what GO TO AGENT needs to open a terminal window.
        ///
        /// Absent from this model until 26 Aug, which is how it broke GO TO
        /// AGENT completely for two hours with no row, no state, no Grant
        /// button and nothing but an AppleScript error number on a card. macOS
        /// asks for it exactly once, at the first Apple event, and never asks
        /// again — so a user who declines that prompt, or whose permissions
        /// were reset, has no route back the app ever mentions.
        case automation

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            case .inputMonitoring: return "Input Monitoring"
            case .accessibility: return "Accessibility"
            case .automation: return "Automation"
            }
        }

        var why: String {
            switch self {
            case .microphone: return "to record your spoken reply"
            // Says what it carries, not when it might help. It is the floor of
            // the recovery chain — the one provider that can never be
            // unavailable — so without it a stalled cloud vendor means a reply
            // that never arrives at all.
            case .speechRecognition: return "so a reply still arrives when a transcription service stalls"
            case .inputMonitoring: return "to notice the hotkeys while you're in another app (measured: Accessibility alone does NOT do this)"
            case .accessibility: return "so dictation can type at your cursor"
            case .automation: return "so Go to Agent can open an agent's terminal window"
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
        /// Required means required. There is no third tier.
        ///
        /// Ruled 07 Aug — "it's either required or it's not, make them both
        /// required or get rid of one" — and applied then to Input Monitoring.
        /// Two permissions kept living outside that rule anyway, wearing
        /// "(fallback)" and "(optional)", and Robert struck the hedge on 26
        /// Aug: *"what the fuck are the two fallback things, do we need them or
        /// not? If we need them then mark them just as required, don't hedge."*
        ///
        /// Both are needed, and both reversals cite a measurement rather than
        /// an argument, as a reversal here has to.
        ///
        /// SPEECH RECOGNITION is not a nicety, it is the FLOOR of the recovery
        /// chain — `RecoveryChain`'s own words: "on-device last because it can
        /// never be unavailable". Earned 19 Aug: a 2m46s reply sat behind a
        /// silently stalled cloud upload whose turn was up to six minutes away,
        /// and the user gave up at 68 seconds. Without this permission the
        /// chain has no floor, so a stalled vendor means a reply that simply
        /// does not arrive. That is the app's core promise failing quietly.
        ///
        /// AUTOMATION is what GO TO AGENT is. Measured expensively on 26 Aug:
        /// because it sat outside this list it had no row, no state, no route
        /// and no Grant button, so when it was revoked the feature died in
        /// silence for two hours and the app's only comment was an AppleScript
        /// error number. A permission the app will not admit to needing is a
        /// permission nobody can grant.
        ///
        /// The 10 Aug objection is answered rather than ignored. Requiring
        /// Speech Recognition then put the onboarding window up at every launch
        /// on a machine where it had never been asked — but that was a
        /// checklist that could not ask, and the checklist can ask now, for
        /// every kind here including Automation, whose prompt this app is the
        /// only thing that can trigger. The cost of requiring is one more row
        /// to grant once. The cost of hedging was tonight.
        var isRequired: Bool { true }

        var settingsURL: String {
            let base = "x-apple.systempreferences:com.apple.preference.security?"
            switch self {
            case .microphone: return base + "Privacy_Microphone"
            case .speechRecognition: return base + "Privacy_SpeechRecognition"
            case .inputMonitoring: return base + "Privacy_ListenEvent"
            case .accessibility: return base + "Privacy_Accessibility"
            // No anchor, deliberately. `Privacy_Automation` appears in the
            // community tables but is unverified on current macOS, a batch of
            // these anchors broke outright in the Ventura System Settings
            // rewrite, and Automation's pane is a dynamically built list of
            // app-to-app pairs that users report finding empty. The general
            // Privacy & Security pane always opens, and the row's own text
            // says where to go next. A door that always works beats a shortcut
            // that sometimes does.
            case .automation: return "x-apple.systempreferences:com.apple.preference.security"
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

    /// One formatter, built once. Allocating a fresh `ISO8601DateFormatter` per
    /// line was the single biggest cost of a `log()` call, and `log()` rides hot
    /// paths: through an announcement it ran twice per spoken word, on the main
    /// thread, at roughly 14 lines a second (issue 15).
    ///
    /// It is only ever touched on `logQueue`, which is serial, so no
    /// thread-safety claim about the class is needed or made — the timestamp is
    /// captured on the CALLER's thread and only the formatting happens here.
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Milliseconds, because whole seconds hid a bug for a day: six ⌃ taps
        // logged at 21:48:44–49 could not show that the intended pairs were
        // ~1s apart against a 450ms pairing window — the log could bound the
        // gap, never state it. Gesture forensics live below one second.
        // (check-selftests.sh compares by whole-second string prefix, so
        // fractional digits only order lines inside the second they belong to.)
        f.formatOptions.insert(.withFractionalSeconds)
        return f
    }()

    /// Every write to app.log, in order, off whichever thread called `log`.
    ///
    /// Serial, so lines cannot interleave and the file descriptor is only ever
    /// opened from one thread. `.utility` because a log line is never what the
    /// user is waiting for.
    private nonisolated static let logQueue =
        DispatchQueue(label: "base.tranquility.permissions.log", qos: .utility)

    /// True once the support directory has been created. Only read and written
    /// on `logQueue`, which is what makes a bare `var` correct here: the
    /// `createDirectory` call was a syscall on every single line.
    private nonisolated(unsafe) static var logDirectoryReady = false

    /// Append one line to app.log.
    ///
    /// The caller pays a `Date()`, a string interpolation and an enqueue. It
    /// never pays a syscall. That is the whole point: this ran on the main
    /// thread twice per spoken word, and a main-run-loop block past ~1s trips
    /// the event-tap watchdog and silently swallows a keystroke (issue 15 — ⌃⌃
    /// pressed mid-announcement, no acknowledgement, no refusal, no trace).
    ///
    /// The COST of going asynchronous, stated rather than discovered later: a
    /// hard crash loses whatever is still queued. The queue drains continuously
    /// and the window is milliseconds, but it is not zero, and the log's other
    /// job is explaining crashes. `flushLog()` is the barrier for the paths that
    /// can afford to wait — termination, and the end of the self-test slate.
    nonisolated static func log(_ message: String) {
        // Stamped HERE, so the timestamp says when the thing HAPPENED rather
        // than when the writer got round to it. Everything after this point is
        // bookkeeping and belongs off the caller's thread.
        let stamp = Date()
        logQueue.async { writeLine(stamp: stamp, message: message) }
    }

    /// Block until everything queued so far is on disk.
    ///
    /// `sync` on a serial queue is a barrier: it cannot return until the work
    /// already enqueued has run. For termination and for the self-test slate,
    /// where a line that never reaches the file reads exactly like a drill that
    /// never ran.
    nonisolated static func flushLog() {
        logQueue.sync {}
    }

    /// The write half, always on `logQueue`.
    private nonisolated static func writeLine(stamp: Date, message: String) {
        // The pid rides every line: thirteen launches wrote to this one file
        // on 12 Aug (relaunches + worktree drill builds), and every
        // log-derived statistic silently mixed instances. With the tag, one
        // grep separates them — and the mic acceptance run can measure
        // exactly the process it deployed.
        let line = "\(iso.string(from: stamp)) \(pidTag)  \(message)\n"
        // `QueueStore.supportDirectory`, not a second hardcoded copy of the
        // same path: the isolated test build (`VOICE_DISPATCH_SUPPORT_DIR`,
        // scripts/bundle-test.sh) needs its own log file too, or its
        // activity keeps landing in the real app's app.log regardless of
        // how isolated everything else is (found live, 26 Aug).
        let url = QueueStore.supportDirectory.appendingPathComponent("app.log")
        if !logDirectoryReady {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            logDirectoryReady = true
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        // O_APPEND leaves the offset at end-of-file after the write, so the size
        // comes free — no stat on the hot path.
        let size = lseek(fd, 0, SEEK_CUR)
        close(fd)
        if size > logSizeLimit {
            roll(url)
            // The directory survives a roll, but re-asserting it is free on the
            // next line and costs nothing to be sure of.
            logDirectoryReady = false
        }
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
        // The build, in the log, at every launch. Crash reports carry it too
        // now (scripts/bundle.sh), but the log is what an investigation reads
        // first, and on 27 Aug it could say only WHEN a build died, never
        // WHICH — attribution came from timestamps matched against the deploy
        // ledger, for a fact the bundle was already carrying.
        let info = bundle.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        log("bundleID=\(bundle.bundleIdentifier ?? "nil") path=\(bundle.bundlePath) "
            + "version=\(short) build=\(build)")
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
        /// We asked for a restart, the restart happened, and it still is not
        /// working. A different situation from `pendingRestart` and it needs a
        /// different sentence, because telling someone to restart a second time
        /// is telling them to do the thing that just failed.
        case stale
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

    /// Bridges to `HotkeyMonitor.start()`, wired from main.swift the same
    /// way `listeningProbe` is. Found live, 26 Aug: `CGRequestListenEventAccess()`
    /// alone (the call `request(.inputMonitoring)` below already made) did
    /// not reliably register the app in the Input Monitoring pane at
    /// all, on a genuinely fresh build. Clicked Grant, no system prompt, the
    /// app never appeared in the list, and Settings opened to a pane with
    /// nothing to toggle. `CGEvent.tapCreate` (what `HotkeyMonitor.start()`
    /// actually calls) is the mechanism `AppDelegate+Grid.swift`'s own
    /// launch-time gate exists around precisely because it is what really
    /// registers and prompts; this hook lets that same real attempt run
    /// from the checklist's Grant button too, still only on a user click,
    /// never automatically.
    @MainActor static var startListening: (() -> Void)?

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

    /// The live answer, before memory is applied. `state(_:)` is the one to call.
    private static func rawState(_ kind: Kind) -> State {
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
        case .automation:
            // Silent by contract: `askUserIfNeeded: false` never prompts and
            // never registers the app. It also cannot tell "never asked" from
            // "denied" — macOS returns one code for both — so this row asks the
            // clock exactly the way `.accessibility` above does.
            //
            // And a grant made in System Settings is invisible to a process
            // already running: the check keeps reading not-permitted until
            // relaunch. That is the same restart gap the checklist already ends
            // on, which is why `.pendingRestart` is the honest answer once the
            // grace period has passed rather than a wrong `.denied`.
            if automationStatus() == noErr { return .active }
            guard let asked = automationAskedAt else { return .notAsked }
            return Date().timeIntervalSince(asked) > liveGrantGrace
                ? .pendingRestart : .notAsked
        }
    }

    /// Whether this app may drive Terminal, asked without asking the user.
    ///
    /// Terminal is the target because it is the one this app automates — GO TO
    /// AGENT opens a window there. `procNotFound`, when Terminal is not
    /// running, is genuinely "cannot tell" and reads as not-yet-granted rather
    /// than denied: an app that has never been able to check must not accuse
    /// the user of refusing something.
    private static func automationStatus() -> OSStatus {
        guard var target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
            .aeDesc?.pointee
        else { return OSStatus(procNotFound) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, /* askUserIfNeeded: */ false)
    }

    /// When `request(.automation)` last put the system dialog up. Same reason
    /// as `accessibilityAskedAt`: the state it distinguishes is a clock, not a
    /// flag macOS will ever hand us.
    @MainActor private static var automationAskedAt: Date?

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

    /// The live answer, plus the one thing the live answer cannot know: whether
    /// we already asked this user to restart and they already did it.
    ///
    /// Without that, both restart-needing rows loop, and they loop differently.
    /// Input Monitoring sits at `pendingRestart` forever, repeating "restart to
    /// use it" to someone who just did. Accessibility and Automation are worse:
    /// their clock was an in-memory `static var`, so the restart we asked for
    /// destroyed the evidence that we asked, and the row fell back to "needs
    /// action" on the next launch. The same unchanged reality read as two
    /// different instructions, alternating, forever.
    ///
    /// Ruled 28 Aug, and the ruling is the important part: "a quit in order to
    /// escape an infinite retry is not a solution, the solution is to resolve
    /// the infinite retry." So the ask is written to disk, and a restart that
    /// did not take is a THIRD state with its own sentence, rather than a
    /// second helping of the first one.
    static func state(_ kind: Kind) -> State {
        if let forced = previewStates?[kind] { return forced }
        let raw = rawState(kind)
        let askedBeforeThisProcess = (restartAskedAt(kind).map { $0 < launchedAt }) ?? false

        switch raw {
        case .active:
            // Recovered. Forget the ask so a future problem is not read through
            // the lens of an old one.
            clearRestartAsked(kind)
            return .active
        case .pendingRestart:
            if askedBeforeThisProcess { return .stale }
            noteRestartAsked(kind)
            return .pendingRestart
        case .notAsked:
            // The oscillation, and ONLY for the two rows that have it.
            //
            // `accessibility` and `automation` fall back to notAsked after a
            // restart because their in-process clock is gone, so a row we told
            // to restart reads as untouched. That is the case worth promoting.
            //
            // `inputMonitoring` is deliberately excluded, and the reason landed
            // on main the same day: macOS disables a tap whose callback is too
            // slow (`HotkeyMonitor.deafWindows`), so this row can read
            // pendingRestart for a second through no fault of the permission,
            // which writes a restart note. `.active` clears that note as soon as
            // the tap returns, so the transient heals itself. But its notAsked
            // means preflight said no, which is a real revocation, and calling
            // that "restarted, still not working" would send someone to the
            // minus button over a permission they simply need to grant.
            guard kind == .accessibility || kind == .automation else { return .notAsked }
            return askedBeforeThisProcess ? .stale : .notAsked
        case .denied, .restricted, .stale:
            return raw
        }
    }

    /// The restart we asked for, remembered ACROSS the restart.
    ///
    /// On disk rather than in memory, which is the whole point: the event we
    /// need to remember is the one that ends the process holding the memory.
    private static func restartKey(_ kind: Kind) -> String {
        "permissions.restartAskedAt.\(kind)"
    }
    private static func restartAskedAt(_ kind: Kind) -> Date? {
        UserDefaults.standard.object(forKey: restartKey(kind)) as? Date
    }
    private static func noteRestartAsked(_ kind: Kind) {
        guard restartAskedAt(kind) == nil else { return }
        UserDefaults.standard.set(Date(), forKey: restartKey(kind))
        log("permissions: noted a restart is needed for \(kind)")
    }
    private static func clearRestartAsked(_ kind: Kind) {
        guard restartAskedAt(kind) != nil else { return }
        UserDefaults.standard.removeObject(forKey: restartKey(kind))
        log("permissions: \(kind) is active, clearing the restart note")
    }

    /// Stamped when this process first asks about permissions. An ask recorded
    /// before this is an ask from a previous launch, which is exactly the
    /// question "have they restarted since we asked" reduces to.
    nonisolated static let launchedAt = Date()

    /// Rows where the restart happened and changed nothing. These are the ones
    /// that must NOT be offered another restart.
    static var stale: [Kind] { Kind.allCases.filter { state($0) == .stale } }

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
        case .automation:
            return automationStatus() == noErr
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
        
        case .automation:
            switch state(.automation) {
            case .active: return "granted"
            case .pendingRestart: return "granted, restart to use it"
            // macOS returns one code for never-asked and denied, so this row
            // does not pretend to know which. Both are answered the same way:
            // press Grant, which prompts if it can and opens Settings if it
            // cannot.
            default: return "not granted. Click Grant, then Privacy & Security → Automation"
            }
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
            // Prompts the first time and lists the app thereafter. Safe to
            // call repeatedly: it returns the current state once already
            // decided.
            let granted = CGRequestListenEventAccess()
            // See `startListening`'s own doc comment: that call alone was
            // not enough to register the app on this machine. The real
            // tap-creation attempt is safe to run here too, since it is
            // still reached only from a user's own Grant click, and
            // `HotkeyMonitor.start()` already no-ops harmlessly when the
            // tap cannot be created.
            if !granted { startListening?() }
            return granted
        case .accessibility:
            FocusedInput.requestTrustOnce()
            // Start the clock. If the grant does not reach this process before
            // the grace period is up, the checklist switches from "click Grant"
            // to "restart to finish" on its own.
            if accessibilityAskedAt == nil { accessibilityAskedAt = Date() }
            return isGranted(kind)
        
        case .automation:
            // The only call that can put the Automation prompt on screen —
            // macOS asks at the first Apple event and never again, so this IS
            // the ask. Off the main actor because it blocks while the dialog
            // is up.
            automationAskedAt = Date()
            return await Task.detached { () -> Bool in
                guard var target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
                    .aeDesc?.pointee
                else { return false }
                defer { AEDisposeDesc(&target) }
                return AEDeterminePermissionToAutomateTarget(
                    &target, typeWildCard, typeWildCard, /* askUserIfNeeded: */ true) == noErr
            }.value
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
