import Foundation

/// What a pane's screen says, as facts telemetry may carry (leak pass, 24 Oct
/// 2026). The screen itself names directories, tab labels and whatever the
/// agent printed, so it never leaves the Mac: only how many lines it had and
/// which known prompt, if any, it matched.
public enum PaneScreen {
    /// The known prompts a launch can stop on, as a token.
    public static func kind(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "none" }
        if lower.contains("trust") { return "trust" }
        if lower.contains("update") { return "update" }
        if lower.contains("hook") { return "hooks" }
        if lower.contains("log in") || lower.contains("sign in") || lower.contains("login") { return "sign_in" }
        return "other"
    }

    /// Non-empty lines on the screen.
    public static func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// The properties a launch event carries about a screen.
    public static func facts(_ text: String) -> [String: TrackValue] {
        let k = kind(text)
        return ["screen_lines": .int(lineCount(text)), "screen_prompt": .token(k),
                "screen_matched": .bool(k != "none" && k != "other")]
    }
}
