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
    /// `startingUpdater: true` begins the scheduled cycle: Sparkle asks permission
    /// on the SECOND launch (deliberately not suppressed with
    /// `SUEnableAutomaticChecks`, because an app that already asks for the
    /// microphone, Accessibility and Apple Events should not also start phoning
    /// out unannounced), then checks every 24 hours.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        log("updates: feed \(feed ?? "<absent>")")
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
        controller.checkForUpdates(sender)
    }

    /// Whether the menu item should be clickable, so it greys out rather than
    /// beeping while a check is already running.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
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

    /// Same rule for the quit-time install path, which is the one most people will
    /// actually hit: Sparkle stages the update and applies it as the app exits.
    /// Even then a dispatch can still be in flight, so the same question is asked.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        guard let block = currentBlock() else { return false }
        log("updates: quit-time install postponed (\(block.rawValue))")
        waitUntilIdle(then: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("updates: found \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Sparkle reports "no update found" through this path too. It is not a
        // failure and must not read like one in the log.
        let quiet = (error as NSError).code == Int(SUError.noUpdateError.rawValue)
        let text = quiet
            ? "updates: already current"
            : "updates: check failed, \(error.localizedDescription)"
        log(text)
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
        postponeTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateReadiness.recheckInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.currentBlock() == nil else { return }
                self.postponeTimer?.invalidate()
                self.postponeTimer = nil
                let go = self.pendingInstall
                self.pendingInstall = nil
                self.log("updates: idle now, installing")
                go?()
            }
        }
    }
}
