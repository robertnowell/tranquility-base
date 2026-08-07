import Foundation

/// The last few things the app said, kept on disk so they can be listened to.
///
/// Robert, 06 Aug: the first syllable of a hail sounds clipped. With playback
/// running straight from an in-memory `Data`, there was no way to tell whether
/// the synthesized audio arrives clipped or whether the player eats its own
/// first frames — the only honest test is to open the file and hear it.
///
/// Bounded on purpose. `model-calls.jsonl` is the cautionary tale in this
/// project (unbounded, full session content); this keeps `limit` files and
/// prunes the rest on every write, so the directory has a ceiling by
/// construction rather than by a rotation task nobody wrote.
public enum SpokenAudioArchive {
    /// Twenty is a couple of minutes of announcements — enough to catch a
    /// "that one sounded clipped" after the fact, small enough to stay a
    /// diagnostic rather than a recording.
    static let limit = 20

    public static var directory: URL {
        QueueStore.supportDirectory.appendingPathComponent("spoken", isDirectory: true)
    }

    /// Write one spoken utterance, then prune to the newest `limit`.
    /// Best-effort throughout: a diagnostic must never break the voice.
    static func keep(_ audio: Data, label: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Sortable timestamp + a slug of what was said: the filename alone
        // tells you which announcement you are about to hear. Built by hand
        // rather than a shared formatter — a static formatter is not Sendable,
        // and this is called from the speech actor's context.
        let stamp = Self.stamp(Date())
        let slug = label.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(4).joined(separator: "-")
        let name = slug.isEmpty ? "\(stamp).mp3" : "\(stamp)-\(slug).mp3"
        try? audio.write(to: directory.appendingPathComponent(name))

        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }
        for stale in sorted.dropFirst(limit) { try? fm.removeItem(at: stale) }
    }

    /// `HHmmss` local time, colon-free so Finder shows the name as written.
    /// Date-free: twenty files never span a day.
    static func stamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
