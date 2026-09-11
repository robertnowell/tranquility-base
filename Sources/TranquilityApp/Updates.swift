import AppKit
import Foundation
import Sparkle
import TranquilityCore

/// The updater, and the one rule it has to obey: never interrupt.
///
/// Sparkle's whole job is to replace this app's bundle and relaunch the process.
/// Everything about that is fine except the timing, which is why the only code
/// here is about timing. `SUFeedURL` and `SUPublicEDKey` live in Info.plist
/// (written by `scripts/bundle.sh`, asserted by `scripts/audit-release.sh`)
/// because a feed URL chosen at runtime is a feed URL that can be wrong in a
/// shipped build with nothing to catch it.
///
/// A note for whoever wires the subscription backend later: do NOT move this feed
/// behind an authenticated endpoint. The update path is how a broken client gets
/// repaired, and coupling it to login, billing, or an API deploy means an outage
/// blocks the fix for that outage. The feed stays public and signed.
@MainActor
final class Updates: NSObject {

    /// What the panel is doing, and how much is unfinished in the queue.
    ///
    /// Closures rather than a reference to `AppDelegate` so this file cannot grow
    /// a second opinion about app state: it can ask the two questions it is
    /// allowed to ask and nothing else.
    private let panelState: @MainActor () -> PanelState
    private let inFlightUtterances: @MainActor () -> Int
    private let log: (String) -> Void

    private var controller: SPUStandardUpdaterController?
    private var postponeTimer: Timer?
    /// Sparkle's "go ahead" block, parked while we wait. Held on the object
    /// rather than captured by the timer: the timer's block is `@Sendable`, and
    /// a non-Sendable closure cannot cross into it under Swift 6.
    private var pendingInstall: (() -> Void)?
    /// The idle streak between polls, and the last reason logged so a
    /// twenty-minute read-back is one line, not a hundred and twenty.
    private var gate = UpdateReadiness.InstallGate()
    private var lastReportedBlock: UpdateReadiness.Block?

    /// Identity configuration, not a compile-time Dev branch. The published
    /// app exercises this exact implementation; local and TEST identities must
    /// never replace themselves from the production feed.
    let isEnabled = AppIdentity.updatesEnabled

    init(
        panelState: @escaping @MainActor () -> PanelState,
        inFlightUtterances: @escaping @MainActor () -> Int,
        log: @escaping (String) -> Void
    ) {
        self.panelState = panelState
        self.inFlightUtterances = inFlightUtterances
        self.log = log
        super.init()
    }

    /// Start checking.
    ///
    /// `startingUpdater: true` begins the scheduled cycle. Since 7 Sep the
    /// bundle carries `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`
    /// (ruled: updates land as soon as possible), so there is no permission
    /// prompt: Sparkle checks at launch and every 24 hours, downloads in the
    /// background, and installs when this delegate says nothing is in
    /// motion, or on quit. Every stage is logged and recorded as
    /// `update_cycle`, because nobody had ever seen the dialog and the log
    /// could not say whether a check had happened at all.
    func start() {
        guard isEnabled else {
            log("updates: disabled for \(AppIdentity.channel.rawValue) identity")
            return
        }
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        log("updates: feed \(feed ?? "<absent>")")
        // Hourly, not daily (ruled 09 Sep). The plist carries the same value
        // for a fresh install; this line is for the copies already out there,
        // whose Sparkle defaults were written on first launch under the old
        // key and would otherwise keep the old cadence for their lifetime.
        // Sparkle persists it, so this is idempotent.
        if let updater = controller?.updater,
           updater.updateCheckInterval != UpdateReadiness.checkInterval {
            updater.updateCheckInterval = UpdateReadiness.checkInterval
            log("updates: check interval set to \(Int(UpdateReadiness.checkInterval / 60)) min")
        }
        // A check at EVERY launch, not only when the daily clock says so.
        // Sparkle's scheduled check fires at last-check plus a day, and a
        // launch inside that day does not check at all: the 7 Sep drill
        // installed the 0.3.1106 release, launched it with 0.3.1110 on the
        // appcast, and watched it sit for ten minutes without asking,
        // because the dev bundle had checked at 17:50. Ruled the same day:
        // updates land as soon as possible, so a launch asks. Background,
        // so nothing is shown unless there is something to install; a few
        // seconds in, so the panel's first paint is never behind a fetch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let updater = self.controller?.updater else { return }
            guard updater.canCheckForUpdates else {
                self.log("updates: launch check skipped, a session is already in progress")
                return
            }
            self.log("updates: launch check")
            Track.record("update_checked", ["via": "launch"])
            updater.checkForUpdatesInBackground()
        }
    }

    /// The menu action. Always available, always allowed, even while busy: asking
    /// is not installing, and a person who opens the menu and picks this wants an
    /// answer now.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller else {
            NSSound.beep()
            log("updates: no updater to check with")
            return
        }
        Track.record("update_checked", ["via": "menu"])
        controller.checkForUpdates(sender)
    }

    /// Whether the menu item should be clickable, so it greys out rather than
    /// beeping while a check is already running.
    var canCheck: Bool { isEnabled && (controller?.updater.canCheckForUpdates ?? false) }
}

extension Updates: @preconcurrency SPUUpdaterDelegate {

    /// The whole reason this file exists.
    ///
    /// Returning `true` tells Sparkle to hold the relaunch and wait for us to call
    /// `installHandler`. We poll rather than subscribe because there is no single
    /// notification that means "everything finished"; the two things we care about
    /// live in different places (the panel and the queue) and
    /// `UpdateReadiness.block` is the one function that knows how to combine them.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let block = currentBlock() else { return false }
        log("updates: install postponed (\(block.rawValue))")
        waitUntilIdle(then: installHandler)
        return true
    }

    /// The path a background download actually takes, and the one this file
    /// got wrong for two days. Sparkle's contract: return `false` and it
    /// installs on quit, presenting the update itself only after its own
    /// long "impatient" interval; return `true` and it stalls the cycle until
    /// we invoke the handler, which installs and relaunches with no UI.
    ///
    /// Until 09 Sep this returned `false` whenever the app was idle at the
    /// moment the download finished, which meant an idle app never updated
    /// at all: the postpone-then-install path only ran when the app was
    /// busy. Robert's production app downloaded 0.3.1123 at 10:26 and was
    /// still on 0.3.1118 at noon, five releases behind, with the
    /// announcement card showing a hint line deleted two days earlier.
    ///
    /// Now every download takes the same road: always `true`, always through
    /// `waitUntilIdle`, which installs after twenty seconds of continuous
    /// idle (`UpdateReadiness.requiredIdlePolls`) and otherwise keeps
    /// waiting. Sparkle still installs on quit as the floor.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        if let block = currentBlock() {
            stage("install waiting", item, detail: block.rawValue)
        } else {
            stage("install waiting", item, detail: "idle, settling")
        }
        waitUntilIdle(then: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("updates: found \(item.displayVersionString)")
        Track.record("update_found", ["to_version": Track.token(from: item.displayVersionString)])
    }

    // Every stage of the cycle, said in the log and counted in the record.
    private func stage(_ name: String, _ item: SUAppcastItem? = nil, detail: String? = nil) {
        log("updates: \(name)" + (item.map { " \($0.displayVersionString)" } ?? "") + (detail.map { ", \($0)" } ?? ""))
        var props: [String: TrackValue] = ["stage": .token(name)]
        if let item { props["to_version"] = Track.token(from: item.displayVersionString) }
        if let detail { props["detail"] = Track.phrase(detail) }
        Track.record("update_cycle", props)
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        stage("appcast_loaded", detail: "\(appcast.items.count) items")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        stage("no_update")
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        let name: String
        switch choice {
        case .install: name = "install"
        case .skip: name = "skip"
        case .dismiss: name = "dismiss"
        @unknown default: name = "other"
        }
        stage("user_chose_\(name)", updateItem)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        stage("downloading", item)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        stage("downloaded", item)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        stage("download_failed", item, detail: error.localizedDescription)
        // The stage event's detail is truncated to a phrase; file the full
        // reason so a download that keeps failing is debuggable remotely.
        Failures.report(.updateFailed,
                        reason: "update download failed: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        stage("installing", item)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        stage("relaunching")
        Analytics.flush()
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        log("updates: next check in \(Int(delay / 60)) min")
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        stage("checks_not_scheduled")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports "no update found" through this path too. It is not a
        // failure and must not read like one in the log.
        let ns = error as NSError
        guard ns.code != Int(SUError.noUpdateError.rawValue) else {
            log("updates: already current")
            Track.record("update_check_result", ["result": "current"])
            return
        }
        // A real check failure. The reason used to reach app.log only, so a
        // client that could not update itself was an opaque count in telemetry
        // (11 Sep: this is exactly why a remote user stuck on an old build was
        // undebuggable). Carry the error text, domain and code, and file a
        // Failure so it reaches the alert stream too.
        let why = error.localizedDescription
        log("updates: check failed, \(why)")
        Track.record("update_check_result", [
            "result": "failed", "detail": .prose(why),
            "domain": Track.token(from: ns.domain), "code": .int(ns.code)])
        Failures.report(.updateFailed,
                        reason: "update check failed: \(why) [\(ns.domain) \(ns.code)]")
    }

    // MARK: - Waiting

    private func currentBlock() -> UpdateReadiness.Block? {
        UpdateReadiness.block(
            panel: panelState(), inFlightUtterances: inFlightUtterances())
    }

    /// Re-ask on a timer until nothing is in motion, then let the install run.
    ///
    /// The timer is retained on `self` and invalidated the moment it fires for
    /// real, so a second postponement cannot leave two of these racing to invoke
    /// the same handler twice.
    private func waitUntilIdle(then install: @escaping () -> Void) {
        postponeTimer?.invalidate()
        pendingInstall = install
        gate = UpdateReadiness.InstallGate()
        postponeTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateReadiness.recheckInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let block = self.currentBlock()
                guard self.gate.observe(block) else {
                    if let block, block != self.lastReportedBlock {
                        self.log("updates: still waiting (\(block.rawValue))")
                    }
                    self.lastReportedBlock = block
                    return
                }
                self.postponeTimer?.invalidate()
                self.postponeTimer = nil
                self.lastReportedBlock = nil
                let go = self.pendingInstall
                self.pendingInstall = nil
                self.log("updates: idle for \(Int(UpdateReadiness.recheckInterval) * UpdateReadiness.requiredIdlePolls)s, installing and relaunching")
                go?()
            }
        }
    }

}
