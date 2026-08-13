import AVFoundation
import Foundation

/// Plays one saved utterance at a time for the recent-audio pane.
///
/// One at a time by design: the pane's ▶ becomes ■ on exactly one row, and
/// playing a second recording stops the first — two dictations talking over
/// each other is never what "let me hear it" meant. The row's state is the
/// host's `playingId` projection; every change funnels through
/// `onStateChange` so the pane re-renders from one source of truth.
///
/// Rule 9: `AVAudioPlayer(contentsOf:)` reads the whole file — 52MB for the
/// 13 Aug dictation — so the load runs detached and only the state flips
/// happen on the main actor. A toggle that arrives while a load is in
/// flight wins by generation: the stale load discards itself.
@MainActor
final class UtterancePlayer: NSObject {
    private var player: AVAudioPlayer?
    private var generation = 0
    private(set) var playingId: String?
    var onStateChange: (() -> Void)?

    /// Play this utterance's audio, or stop it if it is the one playing.
    func toggle(id: String, path: String) {
        if playingId == id {
            stop()
            return
        }
        player?.stop()
        player = nil
        playingId = id
        generation += 1
        let mine = generation
        onStateChange?()

        Task.detached {
            let loaded = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            await MainActor.run { [weak self] in
                guard let self, self.generation == mine else { return }
                guard let loaded else {
                    Permissions.log("recent-audio: could not open audio for \(id.prefix(8))")
                    self.playingId = nil
                    self.onStateChange?()
                    return
                }
                loaded.delegate = self
                self.player = loaded
                loaded.play()
                Permissions.log(String(format: "recent-audio: playing %@ (%.1fs)",
                                       String(id.prefix(8)), loaded.duration))
            }
        }
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        playingId = nil
        onStateChange?()
    }
}

extension UtterancePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.player = nil
            self.playingId = nil
            self.onStateChange?()
        }
    }
}
