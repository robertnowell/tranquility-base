import Foundation

/// Message fragments staged to ride the next voice reply, as a pure value type.
///
/// The tray is the whole of the drop feature's state: drop a file on the
/// panel and it stages here, bound to one session; a handoff can stage context
/// under a launch key; a voice reply to that session snapshots every staged
/// string into the outgoing message at capture
/// close; any outcome where the message did not land returns them to staged,
/// untouched. "Not sending never clobbers" (ruled 15 Aug) is not a guard
/// anywhere — it falls out of the snapshot: the voice flow never mutates
/// staged entries, so keeping them costs nothing.
///
/// Per-session on purpose (ruled over a single global tray): a fragment staged
/// for one agent must never ride a reply to another. That is not a UX bug,
/// it is a cross-project leak — a screenshot of one client's dashboard typed
/// into another client's transcript. Binding at stage time and reading only
/// the target session's entry makes the leak unrepresentable.
///
/// MicMachine's pattern: a value type tests copy freely, replaced atomically
/// by its holder under a lock. No AppKit, no side effects.
public struct AttachmentTray: Equatable, Sendable {
    /// Staged message fragments by session, in insertion order. A fragment is
    /// already the text that should be typed: a dropped file producer supplies
    /// a quoted path, while handoff and future paste producers supply prose.
    private var staged: [String: [String]] = [:]
    /// Fragments that left staged to ride one specific utterance. Keyed by the
    /// utterance id so a late outcome for a superseded reply can never clear
    /// (or restore) another reply's fragments — same generation discipline as
    /// MicMachine's opens.
    private var riding: [String: (session: String, fragments: [String])] = [:]

    public init() {}

    public static func == (a: AttachmentTray, b: AttachmentTray) -> Bool {
        a.staged == b.staged
            && a.riding.mapValues { [$0.session] + $0.fragments }
                == b.riding.mapValues { [$0.session] + $0.fragments }
    }

    /// Stage one send-ready string for a session. Returns false when the same
    /// string is already staged (a re-drop of one file is one chip, not two).
    @discardableResult
    public mutating func stage(_ fragment: String, session: String) -> Bool {
        guard !fragment.isEmpty,
              !(staged[session] ?? []).contains(fragment) else { return false }
        staged[session, default: []].append(fragment)
        return true
    }

    /// The chips: what would ride a reply to this session right now.
    public func staged(for session: String) -> [String] {
        staged[session] ?? []
    }

    /// One chip's ✕. Per-fragment rather than clear-all: with three staged,
    /// a cross that silently took the other two would be the same class of
    /// surprise as a send that carried something you had forgotten.
    public mutating func unstage(_ fragment: String, session: String) {
        guard var fragments = staged[session] else { return }
        fragments.removeAll { $0 == fragment }
        staged[session] = fragments.isEmpty ? nil : fragments
    }

    /// Discard everything staged for a session.
    public mutating func clearStaged(session: String) {
        staged[session] = nil
    }

    /// A launch registered: everything staged under its provisional key now
    /// belongs to the session it became. Appended after anything already
    /// staged for that session (nothing was, in practice — the id did not
    /// exist a moment ago), de-duplicated like a re-drop, and the provisional
    /// entry is gone so a stale target cannot stage against it twice. A key
    /// nothing was staged on is a no-op.
    public mutating func adopt(stagingKey: String, asSession session: String) {
        guard let fragments = staged.removeValue(forKey: stagingKey), !fragments.isEmpty else { return }
        let existing = staged[session] ?? []
        staged[session] = existing + fragments.filter { !existing.contains($0) }
    }

    /// A session left the roster; its chips die with it. Files on disk stay.
    public mutating func sessionEnded(_ session: String) {
        staged[session] = nil
        // Riding entries stay: their utterance's outcome still resolves them,
        // and a failed send's fragments returning to a dead session's staged set
        // is harmless — nothing can target it again.
    }

    /// Capture close: the staged fragments bind to this utterance and leave the
    /// tray. Idempotent per utterance — a second call for the same id (a
    /// retried compose) returns what is already riding rather than snapping
    /// up fragments staged since.
    public mutating func snapshot(session: String, utteranceId: String) -> [String] {
        if let already = riding[utteranceId] { return already.fragments }
        let fragments = staged[session] ?? []
        guard !fragments.isEmpty else { return [] }
        staged[session] = nil
        riding[utteranceId] = (session, fragments)
        return fragments
    }

    /// Move fragments staged during the undo window onto the utterance that is
    /// already waiting to send. Unlike `snapshot`, this deliberately absorbs
    /// newly staged strings on a later call: the user can still see and change
    /// the pending message until its countdown closes.
    public mutating func absorbStaged(session: String, utteranceId: String) -> [String] {
        let additions = staged[session] ?? []
        let existing = riding[utteranceId]
        guard existing == nil || existing?.session == session else {
            return existing?.fragments ?? []
        }
        guard !additions.isEmpty else { return existing?.fragments ?? [] }
        let before = existing?.fragments ?? []
        let combined = before + additions.filter { !before.contains($0) }
        staged[session] = nil
        riding[utteranceId] = (session, combined)
        return combined
    }

    /// What one utterance is carrying (compose-time read, no mutation).
    public func riding(utteranceId: String) -> [String] {
        riding[utteranceId]?.fragments ?? []
    }

    /// The outcome arrived. `landed: true` covers confirmed, queued, AND the
    /// ambiguous verification timeout — the transport's own doctrine
    /// (DispatchTransport.swift: "a duplicate injection is worse than a
    /// drop") decides the ambiguous case as cleared. `landed: false`
    /// (don't-send, deferred, failed) returns the fragments to staged, ahead of
    /// anything added since, so the retry carries what the original did.
    public mutating func resolve(utteranceId: String, landed: Bool) {
        guard let entry = riding.removeValue(forKey: utteranceId) else { return }
        if !landed {
            staged[entry.session] = entry.fragments + (staged[entry.session] ?? [])
                .filter { !entry.fragments.contains($0) }
        }
    }

    // MARK: - Message assembly

    /// A path as it appears inside the typed message. Always quoted: paths
    /// with spaces otherwise split mid-sentence in the prompt, and one
    /// unconditional rule beats a conditional one nobody can predict.
    /// Embedded quotes are escaped rather than trusted absent.
    public static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The one place staged fragments and transcript become a message. Every
    /// fragment precedes the user's explicit words, in insertion order.
    /// Composed late, never by mutating a buffer, so there is nothing to
    /// restore on cancel.
    public static func compose(transcript: String, fragments: [String]) -> String {
        guard !fragments.isEmpty else { return transcript }
        let prefix = fragments.joined(separator: "\n\n")
        return transcript.isEmpty ? prefix : prefix + "\n\n" + transcript
    }
}

/// The tray's holder: one shared, lock-guarded copy. Coordinator is a value
/// type, so mutable state lives behind a reference the way PreparedSummaries
/// does — a class with a lock rather than an actor because the panel reads
/// chips synchronously inside render().
public final class AttachmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tray = AttachmentTray()

    public init() {}

    @discardableResult
    public func stage(_ fragment: String, session: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tray.stage(fragment, session: session)
    }

    public func staged(for session: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tray.staged(for: session)
    }

    public func unstage(_ fragment: String, session: String) {
        lock.lock(); defer { lock.unlock() }
        tray.unstage(fragment, session: session)
    }

    public func clearStaged(session: String) {
        lock.lock(); defer { lock.unlock() }
        tray.clearStaged(session: session)
    }

    public func sessionEnded(_ session: String) {
        lock.lock(); defer { lock.unlock() }
        tray.sessionEnded(session)
    }

    public func adopt(stagingKey: String, asSession session: String) {
        lock.lock(); defer { lock.unlock() }
        tray.adopt(stagingKey: stagingKey, asSession: session)
    }

    public func snapshot(session: String, utteranceId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tray.snapshot(session: session, utteranceId: utteranceId)
    }

    public func riding(utteranceId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tray.riding(utteranceId: utteranceId)
    }

    public func absorbStaged(session: String, utteranceId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tray.absorbStaged(session: session, utteranceId: utteranceId)
    }

    public func resolve(utteranceId: String, landed: Bool) {
        lock.lock(); defer { lock.unlock() }
        tray.resolve(utteranceId: utteranceId, landed: landed)
    }
}
