import Foundation

/// Where a spoken clip goes, when the ordinary speakers are the wrong answer.
///
/// While a hands-free session is up, everything this Mac says out loud has to
/// reach the microphone already cancelled, and a canceller can only subtract
/// audio its own renderer played. `AVAudioPlayer` is a different renderer, so a
/// line read through it arrives at the microphone as though a person had said
/// it — and on 23 Sep three announcements in a row came back as the developer's
/// speech and were judged as commands.
///
/// So the app's voice is routed, while the connection is up, into the engine
/// the connection renders through. This is the seam: Core knows only that
/// something else may own the speakers, and the app installs the thing that
/// does.
public protocol SpokenAudioSink: AnyObject, Sendable {
    /// False when there is no session, or its engine is not running; the
    /// caller falls back to the ordinary player.
    var isReady: Bool { get }
    /// Plays an encoded clip and returns when the audio has finished. Throws
    /// if it could not be decoded or scheduled, which also falls back.
    func play(_ data: Data) async throws
    /// Whatever is playing stops now. Safe to call when nothing is.
    func stop()
    /// Seconds of the current clip that have reached the speakers, for the
    /// callers that measure completion rather than infer it.
    var played: TimeInterval { get }
}

/// Installed by the app when a hands-free session starts, cleared when it ends.
public enum SpokenAudioRoute {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _sink: SpokenAudioSink?

    public static var sink: SpokenAudioSink? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    /// The sink to use right now, or nil to use the speakers directly.
    public static var ready: SpokenAudioSink? {
        guard let s = sink, s.isReady else { return nil }
        return s
    }
}
