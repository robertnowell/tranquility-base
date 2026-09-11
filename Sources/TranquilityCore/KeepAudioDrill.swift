import Foundation

/// The "an open microphone is a promise" data path, as a self-contained drill
/// that runs on a THROWAWAY store — no microphone, no real audio directory, no
/// global input (docs/rulings/ruling-an-open-microphone-is-a-promise.md).
///
/// It exists because the five keyboard drills the 10 Sep incident asked for
/// could not be run by synthetic system input: `HotkeyMonitor`'s tap is
/// system-wide, so a drill's keystrokes interleave with the user's real ones —
/// on 11 Sep a synthetic drill ended a live hands-free dictation and auto-sent
/// it. The gesture DECISION is unit-tested in `InstantArmTests` (interference
/// after commit → `endReply`, never abort). This drill is the other half: that
/// `LiveAudioCapture.abandon` KEEPS a committed capture and that
/// `QueueStore.reconcileOnBoot` SURFACES a kept file as a Recents row.
///
/// One implementation, two callers: the app runs it under `--selftest-hud` on
/// every deploy and reports each group through `SelfTest`; `tbase keepdrill`
/// runs it on demand. Returning results rather than logging keeps Core free of
/// the app's reporting.
public enum KeepAudioDrill {
    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public init(_ name: String, _ passed: Bool) { self.name = name; self.passed = passed }
    }
    public struct Group: Sendable {
        public let name: String
        public let checks: [Check]
    }

    /// 16 kHz PCM16: bytes = seconds * 16000 * 2. Silence is fine — the keep
    /// rule gates on duration and the caller's speech evidence, not content.
    private static func pcm(seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

    public static func run(now: Date = Date()) throws -> [Group] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("tb-keep-drill-\(UUID().uuidString)", isDirectory: true)
        let audio = root.appendingPathComponent("audio", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: audio, withIntermediateDirectories: true)

        // A — a committed-length capture is KEPT, whatever the caller intended.
        // This is the 5m08s case: abandon() used to unlink it on the spot.
        let long = try LiveAudioCapture(utteranceId: "keep-long", sampleRate: 16000, directory: audio)
        try long.append(pcm16: pcm(seconds: LiveAudioCapture.keepAfterSeconds + 1))
        let keptLong = long.abandon() != .removed && fm.fileExists(atPath: long.url.path)

        // B — a short SILENT slip is removed (the arm-window tap-abort, E2).
        let slip = try LiveAudioCapture(utteranceId: "keep-slip", sampleRate: 16000, directory: audio)
        try slip.append(pcm16: pcm(seconds: 0.3))
        let slipRemoved = slip.abandon(hadSpeech: false) == .removed
            && !fm.fileExists(atPath: slip.url.path)

        // C — a short capture WITH speech is kept ("...or has speech").
        let brief = try LiveAudioCapture(utteranceId: "keep-brief", sampleRate: 16000, directory: audio)
        try brief.append(pcm16: pcm(seconds: 1))
        let keptBrief = brief.abandon(hadSpeech: true) != .removed
            && fm.fileExists(atPath: brief.url.path)

        let keep = Group(name: "keepAudio", checks: [
            Check("committedHoldIsKept", keptLong),
            Check("silentSlipIsRemoved", slipRemoved),
            Check("shortSpeechIsKept", keptBrief),
        ])

        // D/E — boot reconciliation: the kept long file becomes a .recorded
        // Recents row dated by the file; a short orphan is left for the reap.
        // Back-date past reconcile's "still under a writer" guard.
        let old = now.addingTimeInterval(-120)
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: long.url.path)
        let orphan = try LiveAudioCapture(utteranceId: "keep-orphan", sampleRate: 16000, directory: audio)
        try orphan.append(pcm16: pcm(seconds: 1))
        _ = try orphan.close()
        try? fm.setAttributes([.modificationDate: old], ofItemAtPath: orphan.url.path)

        let store = try QueueStore(url: root.appendingPathComponent("queue.sqlite"))
        let report = try store.reconcileOnBoot(audioDirectory: audio)
        let adopted = Set(report.adoptedAudio)
        let longRow = try store.utterance(id: "keep-long")

        let boot = Group(name: "bootAdopt", checks: [
            Check("keptLongAdopted", adopted.contains("keep-long")),
            Check("adoptedRowIsRecorded", longRow?.status == .recorded),
            Check("adoptedRowHasNoTranscript", longRow?.transcriptText == nil),
            Check("adoptedRowDatedByFile",
                  longRow.map { abs(Double($0.createdAtMs) / 1000 - old.timeIntervalSince1970) < 2 } ?? false),
            Check("shortOrphanNotAdopted", !adopted.contains("keep-orphan")),
            Check("shortOrphanStaysForReap", fm.fileExists(atPath: orphan.url.path)),
        ])

        return [keep, boot]
    }
}
