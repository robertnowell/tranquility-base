import AVFoundation
import CryptoKit
import Foundation

/// Audio for the lines that never change, kept on disk.
///
/// The launch greeting is the same sentence every time. Paying to synthesize it on
/// every start is the kind of waste that is invisible until you look at a bill, and
/// it also puts a network round trip in front of the first thing the app does.
///
/// Keyed by voice AND text, so changing voice in the picker regenerates once for
/// that voice and is free from then on. There are a few dozen voices and a couple
/// of fixed lines, so the cache converges almost immediately and never grows.
public enum GreetingCache {
    private static var directory: URL {
        QueueStore.supportDirectory.appendingPathComponent("greetings", isDirectory: true)
    }

    static func url(voiceId: String, text: String) -> URL {
        let digest = SHA256.hash(data: Data(text.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(voiceId)-\(digest).mp3")
    }

    private static let player = PlayerBox()

    final class PlayerBox: @unchecked Sendable {
        private let queue = DispatchQueue(label: "greeting.player")
        private var player: AVAudioPlayer?
        func play(_ data: Data) -> AVAudioPlayer? {
            queue.sync {
                player = try? AVAudioPlayer(data: data)
                player?.play()
                return player
            }
        }
        func stop() { queue.sync { player?.stop(); player = nil } }
    }

    public static func stop() { player.stop() }

    /// Speak a fixed line, fetching it once per voice and replaying it thereafter.
    /// Silent when the good voice is unavailable: a greeting is not worth the
    /// system voice, and the panel carries the same information anyway.
    public static func speak(_ text: String) async {
        let voiceId = VoiceCatalog.selectedVoiceId
        let file = url(voiceId: voiceId, text: text)

        if let cached = try? Data(contentsOf: file), !cached.isEmpty {
            await play(cached)
            return
        }

        guard let key = Secrets.read(.elevenLabsAPIKey) else { return }
        var request = URLRequest(
            url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["text": text, "model_id": "eleven_flash_v2_5"])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty
        else { return }

        try? PrivateStorage.createDirectory(at: directory)
        try? data.write(to: file, options: .atomic)
        PrivateStorage.protect(file)
        await play(data)
    }

    private static func play(_ data: Data) async {
        guard let audio = player.play(data) else { return }
        while audio.isPlaying {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
