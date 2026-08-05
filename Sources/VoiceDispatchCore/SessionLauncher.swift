import Foundation

/// Spawn a fresh Claude session in a new Terminal window.
///
/// The dispatch loop is reactive by construction — sessions announce, the user
/// answers. This is the proactive half (ruled 05 Aug): "sometimes I want to
/// kick off an investigation." v1 is deliberately choiceless: always `claude`,
/// always `--dangerously-skip-permissions`, always the home directory. The two
/// knobs worth a UI (directory, agent command) arrive with the grid's
/// new-session affordance; adding options before the habit exists is furniture.
///
/// Lives in Core so `vdctl new` and the app's menu item are the same code path,
/// and because the only capability it needs — Terminal automation via
/// AppleScript — is already Core's (`AppleScript.run`, the dispatcher's own
/// transport). The Automation permission the app holds covers this identically:
/// same target app, same entitlement.
public enum SessionLauncher {

    /// Same shape as Coordinator.trace / QueueStore.trace: Core stays silent
    /// unless a host wires the log in.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    public static let defaultDirectory = NSHomeDirectory()
    public static let defaultCommand = "claude --dangerously-skip-permissions"

    /// Opens a new Terminal window in `directory` running `command`.
    /// Returns the shell-visible error on failure so callers can surface it.
    @discardableResult
    public static func launch(
        directory: String = defaultDirectory,
        command: String = defaultCommand
    ) -> Result<Void, ScriptError> {
        // `quoted form of` is AppleScript's own shell-quoting — the directory
        // never touches the shell unescaped.
        let script = """
            tell application "Terminal"
              activate
              do script "cd " & quoted form of "\(directory)" & " && \(command)"
            end tell
            """
        switch AppleScript.run(script: script) {
        case .success:
            Self.trace?("newSession: launched `\(command)` in \(directory)")
            return .success(())
        case .failure(let error):
            Self.trace?("newSession FAILED: \(error.message)")
            return .failure(error)
        }
    }
}
