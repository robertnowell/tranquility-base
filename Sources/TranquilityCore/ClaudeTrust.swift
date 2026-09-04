import Foundation

/// Pre-answering Claude Code's directory-trust dialog by writing the record it
/// would have written, instead of pressing keys at the screen that asks.
///
/// The dialog is a real consent, and TB has always treated it as one the user
/// gives by launching an agent in that directory ("user-commanded launch", the
/// phrase `TrustPromptWatcher` already logs). What changes here is only HOW
/// that consent is expressed. Until now it was expressed by finding the
/// accepting row on a rendered TUI menu, counting lines from a selection
/// glyph, and sending arrow keys — a bet on another team's UI that nobody
/// sanctions and that we lost on 3 Sep.
///
/// Anthropic documents this key as the remedy, verbatim: "trust it by hand:
/// set `projects["<path>"].hasTrustDialogAccepted` to `true` in
/// `~/.claude.json`" (code.claude.com/docs/en/permissions). Writing it is
/// strictly less inventive than pressing the key, and it cannot land on the
/// wrong row.
///
/// Deliberately NOT written: `hasCompletedOnboarding`, `theme`, or anything
/// about sign-in. Those are undocumented, community-reverse-engineered, and
/// current docs place `theme` in `settings.json` instead — so a write here
/// would be guessing at a schema we cannot read. They are also the two gates
/// (identity and preference) that either must stay with the human or should
/// be handled by the first-run checklist, not by a launcher.
public enum ClaudeTrust {

    /// Where the record lives. `CLAUDE_CONFIG_DIR` relocates the whole tree,
    /// and honouring it matters for more than tidiness: it is the mechanism
    /// that makes a first-run profile reproducible in a test, which is how
    /// this bug was finally caught.
    static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent(".claude.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
    }

    /// True when this directory is already trusted, so a caller can skip the
    /// write entirely. Separated because the common case is "already trusted"
    /// and the cheapest correct thing to do to a 350KB file another process
    /// is actively writing is not to touch it.
    public static func isTrusted(directory: String, at url: URL? = nil) -> Bool {
        guard let root = load(url ?? configURL),
              let projects = root["projects"] as? [String: Any],
              let entry = projects[directory] as? [String: Any]
        else { return false }
        return entry["hasTrustDialogAccepted"] as? Bool == true
    }

    /// Record trust for `directory`, returning whether anything was written.
    ///
    /// Read-modify-write on a file Claude Code also owns is a real race: a
    /// session running right now can write between our read and our write,
    /// and last writer wins on the whole document. Three things keep that
    /// acceptable rather than reckless. It only ever runs when the key is
    /// absent or false, so the steady state costs no write at all. It changes
    /// exactly one leaf and preserves every other key verbatim. And it writes
    /// through a temporary file and an atomic rename, so a crash mid-write
    /// cannot leave a truncated config where a working one was.
    ///
    /// It is still a race, and the honest mitigation is the narrow window
    /// rather than a lock we cannot take. Called once per launch, before the
    /// pane exists, which is the moment least likely to collide with the
    /// session we are about to start.
    @discardableResult
    public static func trust(directory: String, at url: URL? = nil) -> Bool {
        let url = url ?? configURL
        guard !isTrusted(directory: directory, at: url) else { return false }
        guard var root = load(url) else { return false }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[directory] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        projects[directory] = entry
        root["projects"] = projects
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".claude.json.tb-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    private static func load(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }
}
