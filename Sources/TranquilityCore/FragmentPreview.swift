import Foundation

/// What a tray chip shows for one staged fragment.
///
/// Presentation only: the tray carries no kind tag, so the chip infers from
/// the string. A quoted or bare absolute path keeps the compact filename chip
/// it has always had. Prose shows its first meaningful line, cut to `limit`
/// characters, and then says how much it is not showing: "+1,234 chars".
/// Ruled 7 Sep: a paste must be visibly on the card, but never the whole
/// thing; the remainder count is what tells you a paragraph came in and not
/// a sentence.
public enum FragmentPreview {
    public static let defaultLimit = 48

    public static func preview(_ fragment: String, limit: Int = defaultLimit) -> String {
        let firstLine = fragment.split(whereSeparator: \.isNewline).first
            .map(String.init) ?? fragment
        var candidate = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("\"") && candidate.hasSuffix("\"") && candidate.count >= 2 {
            candidate.removeFirst()
            candidate.removeLast()
            candidate = candidate.replacingOccurrences(of: "\\\"", with: "\"")
        }
        if candidate.hasPrefix("/") {
            return (candidate as NSString).lastPathComponent
        }
        let shown = String(candidate.prefix(limit))
        // Counted against the WHOLE fragment, not the first line: a short
        // first line over three more paragraphs is still mostly hidden.
        let hidden = fragment.trimmingCharacters(in: .whitespacesAndNewlines).count - shown.count
        guard hidden > 0 else { return shown }
        let cut = shown.count < candidate.count ? "\u{2026}" : ""
        return "\(shown)\(cut) +\(grouped(hidden)) chars"
    }

    /// 1234 → "1,234". Fixed grouping rather than a locale formatter so a
    /// drill asserting the text reads the same on every machine.
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out: [Character] = []
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(d)
        }
        return String(out)
    }
}
