import Foundation

/// The hands-free event stream the app keeps (`manager-events.jsonl`), which
/// the viewer (`tb-voice/server/tail.py`) follows. Since hf-14 it carries every
/// model call in full, so it has a ceiling by construction: past `limit` bytes
/// it becomes `manager-events.1.jsonl` (replacing the one before) when a
/// session opens it, and the viewer starts again on the new file.
public enum EventsLog {
    /// Thirty-two megabytes is days of hands-free, calls included.
    public static let limit = 32 * 1024 * 1024

    /// A handle at the end of `url`, rotating it first if it is over `limit`.
    public static func open(_ url: URL, limit: Int = EventsLog.limit) -> FileHandle? {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > limit {
            let old = url.deletingPathExtension().appendingPathExtension("1")
                .appendingPathExtension(url.pathExtension)
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }
}
