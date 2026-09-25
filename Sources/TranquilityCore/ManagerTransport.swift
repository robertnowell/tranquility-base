import Foundation

/// What hands-free talks to.
///
/// There was a second one until 25 Sep: `ManagerSocket`, one WebSocket
/// carrying PCM up and down with JSON lines between. It went with the
/// transport it was named for. A raw socket has no echo canceller, so the bot
/// had to feed its transcriber silence while the manager spoke, so nothing
/// said over the manager could ever reach it — which is to say the feature
/// this app exists for could not work on that path and never would.
///
/// The protocol stays, with one implementation, because the panel, the orb and
/// the door answering are written against it and none of them should know what
/// carries the audio.
public protocol ManagerTransport: AnyObject, Sendable {
    func start() throws
    func lines() -> AsyncStream<Data>
    func close() async
    /// Every frame kind and every failure, for the log.
    var onTrace: (@Sendable (String) -> Void)? { get set }
}

/// Why a manager transport could not start or could not continue.
///
/// Named for the socket while that was the only one; the failures are the
/// transport's, not any particular wire's.
public enum ManagerTransportError: Error, Equatable {
    case noInputDevice
    case closed
}
