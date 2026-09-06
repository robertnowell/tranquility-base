import AppKit
import TranquilityCore

/// The app's half of the failure record: the environment probe, run off the
/// main thread, and the menu's way to see what has been recorded.
///
/// Ruled 6 Sep 2026. The record is built in Core (`Failures`); this file is
/// what only the app can know: its bundle, its permission states, where its
/// tmux resolved, and when to look again. The probe runs subprocesses
/// (`--version` on each harness binary), so it is detached and never on a
/// path a person is waiting on; the snapshot it produces is what every
/// later report reads, at no cost.
enum Diagnostics {
    /// Take (or retake) the environment snapshot. Once at startup, and again
    /// after a launch failure, since a harness that was just reinstalled is
    /// exactly the fact the next record should carry.
    @MainActor
    static func refreshEnvironment(reason: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["TBSourceCommit"] as? String
        let permissions = Dictionary(uniqueKeysWithValues:
            Permissions.Kind.allCases.map { ($0.title, "\(Permissions.state($0))") })
        let tmux = Tmux.resolvedBinaryPath
        Task.detached(priority: .utility) {
            let snap = EnvironmentProbe.snapshot(
                appVersion: version, appBuild: build, sourceCommit: commit,
                permissions: permissions, tmuxPath: tmux)
            Failures.environment = snap
            let harnesses = snap.harnesses.map {
                "\($0.id)=\($0.path ?? "missing") slices=\($0.slices.joined(separator: "+")) v=\($0.version ?? "?")"
            }.joined(separator: "; ")
            Permissions.log("env: \(reason): arch=\(snap.appArch) translated=\(snap.appTranslated) "
                + "commit=\(snap.sourceCommit?.prefix(7) ?? "?") macOS=\(snap.macOS) "
                + "tmux=\(snap.tmuxVersion ?? "?") \(harnesses)")
        }
    }

    /// The "what we send" view, before there is a "we send": the local file,
    /// shown in Finder. Opened with whatever handles it if something does.
    @MainActor
    static func revealFailureLog() {
        guard let url = Failures.storeURL else { return }
        Failures.flush()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
