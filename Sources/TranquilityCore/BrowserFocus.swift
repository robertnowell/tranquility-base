import Foundation

/// Open a page without making tab twenty-eight.
///
/// Twenty agents that each produce pages become twenty pages you open, and the
/// browser's default answer to "open this URL" is a new tab every single time —
/// `open` is a LaunchServices dispatch with no idea what is already on screen.
/// Left alone, a fleet of agents turns into a wall of identical favicons, which
/// is precisely the mess the hub exists to end. Opening the hub must not
/// recreate it.
///
/// The fix is Chrome-only on purpose. Chrome's scripting dictionary exposes tab
/// URLs and lets a window be raised and a tab selected; Safari's equivalent is
/// gated behind settings a script cannot set, and Arc's dictionary is organised
/// around Spaces rather than windows. Every tool that does this in the wild
/// (`better-opn`, `Focus-Tab`) reaches the same conclusion and falls back to a
/// plain open elsewhere. So does this.
///
/// Three ways it declines, all of them silent:
///   * Chrome is not running — `application "X" is running` is used precisely
///     because it does not launch anything to find out.
///   * The page is not open in any tab.
///   * Automation is denied (-1743). macOS stops prompting after the first
///     refusal, so this must never surface as a failure the user has to answer.
/// In all three the caller opens the URL the ordinary way, which is exactly the
/// behaviour that existed before this file.
public enum BrowserFocus {

    public enum Outcome: Equatable {
        /// An existing tab was raised. Nothing new was opened.
        case focused
        /// Nothing matched, or the browser could not be asked. The caller must
        /// fall back.
        case notFound
    }

    /// AppleScript string literals cannot carry a raw quote or backslash.
    /// A file URL can contain both.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Chrome reports `file:///Users/...`, and a URL built from a path matches
    /// that — but a page opened by hand may carry a trailing slash or an escaped
    /// space. Comparing on both the exact string and its percent-decoded form
    /// covers the cases seen without resorting to fuzzy matching, which would
    /// eventually focus the wrong tab.
    static func script(for url: URL, reloading: Bool = true) -> String {
        let exact = escaped(url.absoluteString)
        let decoded = escaped(url.absoluteString.removingPercentEncoding ?? url.absoluteString)
        return """
        if application "Google Chrome" is running then
          tell application "Google Chrome"
            set matched to false
            repeat with w from 1 to (count of windows)
              set urls to URL of tabs of window w
              repeat with t from 1 to (count of urls)
                set u to item t of urls
                if u is "\(exact)" or u is "\(decoded)" then
                  set index of window w to 1
                  set active tab index of window w to t
                  \(reloading ? "reload tab t of window w" : "")
                  set matched to true
                  exit repeat
                end if
              end repeat
              if matched then exit repeat
            end repeat
            if matched then activate
            return matched
          end tell
        else
          return false
        end if
        """
    }

    /// The hub app is one tab, not one tab per page.
    ///
    /// The exact-URL walk above is right for a file the app rewrote: the tab
    /// that has it is the tab to raise. The hub app is different. Its doors
    /// point at `/open?session=…&slug=…`, an address that answers with a
    /// redirect, so no tab ever carries it and the exact match never fires;
    /// every click made tab twenty-nine, which is what Robert saw on 10 Sep.
    /// Any tab already on the app IS the app, so the first one found is sent
    /// to the new address and raised. No reload: the navigation is the reload.
    ///
    /// Same three silent declines as above, and the same fallback.
    static func navigateScript(to url: URL, within base: URL) -> String {
        let target = escaped(url.absoluteString)
        let prefix = escaped(base.absoluteString.hasSuffix("/") ? base.absoluteString
                                                                : base.absoluteString + "/")
        return """
        if application "Google Chrome" is running then
          tell application "Google Chrome"
            set matched to false
            repeat with w from 1 to (count of windows)
              set urls to URL of tabs of window w
              repeat with t from 1 to (count of urls)
                set u to item t of urls
                if u starts with "\(prefix)" then
                  set index of window w to 1
                  set active tab index of window w to t
                  set URL of tab t of window w to "\(target)"
                  set matched to true
                  exit repeat
                end if
              end repeat
              if matched then exit repeat
            end repeat
            if matched then activate
            return matched
          end tell
        else
          return false
        end if
        """
    }

    /// Send the tab already on `base` to `url` and raise it, or report that
    /// there is no such tab. Never opens anything, never launches a browser.
    @discardableResult
    public static func navigateExistingTab(to url: URL, within base: URL,
                                           run: (String) -> Result<String, ScriptError>
                                               = { AppleScript.run(script: $0) }) -> Outcome {
        switch run(navigateScript(to: url, within: base)) {
        case .success(let output):
            return output.trimmingCharacters(in: .whitespaces) == "true" ? .focused : .notFound
        case .failure:
            return .notFound
        }
    }

    /// The door: a hub-app address reuses the app's tab; anything else raises
    /// its exact tab; and with no tab to raise, the caller opens it.
    @discardableResult
    public static func reveal(_ url: URL, app base: URL?, reloading: Bool = true,
                              run: (String) -> Result<String, ScriptError>
                                  = { AppleScript.run(script: $0) }) -> Outcome {
        if let base, url.absoluteString.hasPrefix(base.absoluteString) {
            return navigateExistingTab(to: url, within: base, run: run)
        }
        return focusExistingTab(url, reloading: reloading, run: run)
    }

    /// Raise an existing tab for this URL, or report that there wasn't one.
    /// Never opens anything, never launches a browser, never throws.
    ///
    /// **It reloads what it raises**, and that is the point of the door rather
    /// than a side effect of it. Reported 18 Aug: "when I open report, if the
    /// report has been updated since it was originally opened, then it
    /// obviously is out of date, but it opens the original tab." Raising the
    /// tab is the RIGHT half — a fleet of agents must not become a wall of
    /// identical favicons, which is this file's whole reason to exist — and
    /// showing yesterday's render of it is the wrong one.
    ///
    /// Not a heuristic on file dates, deliberately. `openHub` rewrites the page
    /// immediately before calling this, so "the tab is stale" is the normal
    /// case and not the exception; a freshness check would compute an answer
    /// that is almost always yes, and would be wrong in the one direction that
    /// matters — a door that shows an old page teaches you not to trust the
    /// door. The cost of being wrong the other way is a repaint of a page the
    /// click already asked for, and Chrome restores scroll position across it.
    ///
    /// `reloading: false` is real, not spare capacity: the repository door
    /// (docs/log/open-issues.md #24) uses it — a live GitHub page nobody here
    /// rewrote, where reloading would throw away whatever the user was
    /// reading, unlike the hub pages this app rewrites immediately before
    /// raising them.
    @discardableResult
    public static func focusExistingTab(_ url: URL,
                                        reloading: Bool = true,
                                        run: (String) -> Result<String, ScriptError>
                                            = { AppleScript.run(script: $0) }) -> Outcome {
        switch run(script(for: url, reloading: reloading)) {
        case .success(let output):
            return output.trimmingCharacters(in: .whitespaces) == "true" ? .focused : .notFound
        case .failure:
            // Denied, unscriptable, or Chrome went away mid-script. All three
            // mean the same thing to the caller.
            return .notFound
        }
    }
}
