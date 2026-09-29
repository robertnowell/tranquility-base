import AppKit
import TranquilityCore

/// Keystrokes the panel could not deliver, written down before they are lost.
///
/// Ruled 29 Sep 2026, after a typed message never reached its agent and nothing
/// anywhere could say what it had been. Robert: "we cannot ever fucking lose
/// user input ever ever ever... i can't believe fucking user input was lost
/// even from our fucking logs."
///
/// He is right about both halves, and the second is the one that made the first
/// unfixable. The panel drops a key that arrives with no typed line editing —
/// it was meant for another window and there is nowhere to forward it, which is
/// a real constraint — but it logged only `paste: key 11`, a KEYCODE. A keycode
/// cannot be read back as text, cannot be pasted, and cannot even tell you
/// whether what you lost was a sentence or a stray tap of the space bar.
///
/// Nothing else catches it either: the store's first record of a reply is made
/// by `submitTypedReply`, which is already past the point where these die. So a
/// keystroke discarded here existed nowhere at all.
///
/// This does not make the key arrive. It makes the loss legible: the character
/// itself, the time, and what held the keyboard instead, appended to a file
/// that survives the process. Recovery is then a `cat`, not a reconstruction.
enum DroppedInput {

    /// Where dropped keystrokes accumulate. Beside the queue database rather
    /// than in the log, because the log rotates and this is user data.
    static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("dropped-input.log")
    }

    /// Record one keystroke the panel is about to discard.
    ///
    /// `characters` is what the key WOULD have typed, which is the only form
    /// worth keeping — a keycode is not text. Nil for a key that produces none
    /// (an arrow, a modifier alone); those are noted too, because a run of them
    /// is the shape of somebody navigating a field that is not listening.
    static func record(_ characters: String?, keyCode: UInt16, responder: String) {
        let typed = characters ?? ""
        let shown = typed.isEmpty ? "(no character)" : typed.debugDescription
        Permissions.log("paste: DROPPED KEY \(shown) (keyCode \(keyCode), "
            + "first responder \(responder)); releasing — recorded in dropped-input.log")

        // Appended, never rewritten: a second dropped key must not cost the
        // first. Failure to write is logged and swallowed, because a keystroke
        // already being lost is not improved by a crash.
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)\t\(keyCode)\t\(typed)\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = url
        do {
            if FileManager.default.fileExists(atPath: path.path) {
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: path, options: .atomic)
            }
        } catch {
            Permissions.log("dropped-input: could not record it: \(error)")
        }
    }

    /// Everything dropped since the file was last cleared, newest last. The
    /// panel reads this to offer it back; a drill reads it to prove the write.
    static func all() -> [(at: String, keyCode: UInt16, characters: String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, let code = UInt16(parts[1]) else { return nil }
            return (at: parts[0], keyCode: code,
                    characters: parts.dropFirst(2).joined(separator: "\t"))
        }
    }
}
