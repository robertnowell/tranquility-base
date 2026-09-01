import Foundation

/// Files staged to ride the next voice reply, as a pure value type.
///
/// The tray is the whole of the drop feature's state: drop a file on the
/// panel and it stages here, bound to one session; a voice reply to that
/// session snapshots the staged paths into the outgoing message at capture
/// close; any outcome where the message did not land returns them to staged,
/// untouched. "Not sending never clobbers" (ruled 15 Aug) is not a guard
/// anywhere — it falls out of the snapshot: the voice flow never mutates
/// staged entries, so keeping them costs nothing.
///
/// Per-session on purpose (ruled over a single global tray): a file staged
/// for one agent must never ride a reply to another. That is not a UX bug,
/// it is a cross-project leak — a screenshot of one client's dashboard typed
/// into another client's transcript. Binding at stage time and reading only
/// the target session's entry makes the leak unrepresentable.
///
/// MicMachine's pattern: a value type tests copy freely, replaced atomically
/// by its holder under a lock. No AppKit, no side effects.
public struct AttachmentTray: Equatable, Sendable {
    /// Staged paths by session, in drop order.
    private var staged: [String: [String]] = [:]
    /// Paths that left staged to ride one specific utterance. Keyed by the
    /// utterance id so a late outcome for a superseded reply can never clear
    /// (or restore) another reply's files — same generation discipline as
    /// MicMachine's opens.
    private var riding: [String: (session: String, paths: [String])] = [:]

    public init() {}

    public static func == (a: AttachmentTray, b: AttachmentTray) -> Bool {
        a.staged == b.staged
            && a.riding.mapValues { [$0.session] + $0.paths }
                == b.riding.mapValues { [$0.session] + $0.paths }
    }

    /// Stage a path for a session. Returns false when it was already staged
    /// (a re-drop of the same file is one chip, not two).
    @discardableResult
    public mutating func stage(_ path: String, session: String) -> Bool {
        guard !(staged[session] ?? []).contains(path) else { return false }
        staged[session, default: []].append(path)
        return true
    }

    /// The chips: what would ride a reply to this session right now.
    public func staged(for session: String) -> [String] {
        staged[session] ?? []
    }

    /// One chip's ✕. Per-path rather than clear-all: with three files staged,
    /// a cross that silently took the other two would be the same class of
    /// surprise as a send that carried something you had forgotten.
    public mutating func unstage(_ path: String, session: String) {
        guard var paths = staged[session] else { return }
        paths.removeAll { $0 == path }
        staged[session] = paths.isEmpty ? nil : paths
    }

    /// Discard everything staged for a session.
    public mutating func clearStaged(session: String) {
        staged[session] = nil
    }

    /// A session left the roster; its chips die with it. Files on disk stay.
    public mutating func sessionEnded(_ session: String) {
        staged[session] = nil
        // Riding entries stay: their utterance's outcome still resolves them,
        // and a failed send's paths returning to a dead session's staged set
        // is harmless — nothing can target it again.
    }

    /// Capture close: the staged paths bind to this utterance and leave the
    /// tray. Idempotent per utterance — a second call for the same id (a
    /// retried compose) returns what is already riding rather than snapping
    /// up files staged since.
    public mutating func snapshot(session: String, utteranceId: String) -> [String] {
        if let already = riding[utteranceId] { return already.paths }
        let paths = staged[session] ?? []
        guard !paths.isEmpty else { return [] }
        staged[session] = nil
        riding[utteranceId] = (session, paths)
        return paths
    }

    /// Move files dropped during the undo window onto the utterance that is
    /// already waiting to send. Unlike `snapshot`, this deliberately absorbs
    /// newly staged paths on a later call: the user can still see and change
    /// the pending message until its countdown closes.
    public mutating func absorbStaged(session: String, utteranceId: String) -> [String] {
        let additions = staged[session] ?? []
        let existing = riding[utteranceId]
        guard existing == nil || existing?.session == session else {
            return existing?.paths ?? []
        }
        guard !additions.isEmpty else { return existing?.paths ?? [] }
        let before = existing?.paths ?? []
        let combined = before + additions.filter { !before.contains($0) }
        staged[session] = nil
        riding[utteranceId] = (session, combined)
        return combined
    }

    /// What one utterance is carrying (compose-time read, no mutation).
    public func riding(utteranceId: String) -> [String] {
        riding[utteranceId]?.paths ?? []
    }

    /// The outcome arrived. `landed: true` covers confirmed, queued, AND the
    /// ambiguous verification timeout — the transport's own doctrine
    /// (DispatchTransport.swift: "a duplicate injection is worse than a
    /// drop") decides the ambiguous case as cleared. `landed: false`
    /// (don't-send, deferred, failed) returns the paths to staged, ahead of
    /// anything dropped since, so the retry carries what the original did.
    public mutating func resolve(utteranceId: String, landed: Bool) {
        guard let entry = riding.removeValue(forKey: utteranceId) else { return }
        if !landed {
            staged[entry.session] = entry.paths + (staged[entry.session] ?? [])
                .filter { !entry.paths.contains($0) }
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

    /// The one place transcript and paths become a message. Composed late,
    /// never by mutating a buffer, so there is nothing to restore on cancel.
    public static func compose(transcript: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return transcript }
        let tail = paths.map(quoted).joined(separator: " ")
        return transcript.isEmpty ? tail : transcript + " " + tail
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
    public func stage(_ path: String, session: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tray.stage(path, session: session)
    }

    public func staged(for session: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return tray.staged(for: session)
    }

    public func unstage(_ path: String, session: String) {
        lock.lock(); defer { lock.unlock() }
        tray.unstage(path, session: session)
    }

    public func clearStaged(session: String) {
        lock.lock(); defer { lock.unlock() }
        tray.clearStaged(session: session)
    }

    public func sessionEnded(_ session: String) {
        lock.lock(); defer { lock.unlock() }
        tray.sessionEnded(session)
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
