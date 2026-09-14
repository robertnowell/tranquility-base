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

        // F — a kept file is a Recents row the moment it is kept, not at the
        // next boot (14 Sep 2026). The brief kept file from C is seconds old
        // and under the boot floor: both guards the boot sweep applies, and
        // neither applies to a file the recorder itself just decided to keep.
        let keptNowId = try store.adoptKeptCapture(at: brief.url, because: "abandoned")
        let keptNowRow = try keptNowId.flatMap { try store.utterance(id: $0) }
        let keptNowTwice = try store.adoptKeptCapture(at: brief.url, because: "abandoned")
        let now = Group(name: "keptNow", checks: [
            Check("keptFileAdoptedAtOnce", keptNowId == "keep-brief"),
            Check("adoptedRowIsRecorded", keptNowRow?.status == .recorded),
            Check("adoptedRowSaysWhy", keptNowRow?.transcriptionOutcome == "adopted_abandoned"),
            Check("adoptedFileIsFinished",
                  !fm.fileExists(atPath: brief.url.path)
                  && fm.fileExists(atPath: brief.url.deletingPathExtension().path)),
            Check("adoptingTwiceIsOnce", keptNowTwice == nil),
        ])

        // G — Dismiss keeps the words and never sends them (14 Sep 2026: the
        // menu-bar click that ran `_ = try? recorder.stop()`). A capture with
        // speech becomes a row with its transcript, parked `.discarded` so the
        // boot sweep cannot promote it toward a terminal; room tone is removed
        // rather than left for the reap. The chain is a fixture — the drill
        // spends nothing and reaches no provider.
        let audioStore = AudioStore(directory: audio)
        let spoken = try LiveAudioCapture(utteranceId: "keep-dismissed", sampleRate: 16000, directory: audio)
        try spoken.append(pcm16: pcm(seconds: 2))
        _ = spoken.abandon(hadSpeech: true)
        let dismissed = try awaitDismiss(store: store, audioStore: audioStore,
                                         pcm16: pcm(seconds: 2), peak: 0.5, preWritten: spoken.url,
                                         utteranceId: "keep-dismissed")
        let slipFile = try LiveAudioCapture(utteranceId: "keep-dismissed-slip", sampleRate: 16000, directory: audio)
        try slipFile.append(pcm16: pcm(seconds: 0.3))
        _ = try slipFile.close()
        let dismissedSlip = try awaitDismiss(store: store, audioStore: audioStore,
                                             pcm16: pcm(seconds: 0.3), peak: 0.5, preWritten: slipFile.url,
                                             utteranceId: "keep-dismissed-slip")
        let boot2 = try store.reconcileOnBoot(audioDirectory: audio)
        let afterBoot = try store.utterance(id: "keep-dismissed")
        let slipRow = try store.utterance(id: "keep-dismissed-slip")
        let dismiss = Group(name: "dismissKeeps", checks: [
            Check("dismissedSpeechHasARow", dismissed != nil),
            Check("dismissedSpeechIsTranscribed", dismissed?.transcriptText == "the drill heard it"),
            Check("dismissedRowIsParked", dismissed?.status == .discarded
                  && dismissed?.discardedReason == "dismissed before send"),
            Check("dismissedRowKeepsItsAudio",
                  dismissed?.audioPath.map { fm.fileExists(atPath: $0) } ?? false),
            Check("bootDoesNotRequeueIt", !boot2.requeuedForTranscription.contains("keep-dismissed")
                  && afterBoot?.status == .discarded),
            Check("dismissedRoomToneHasNoRow", dismissedSlip == nil && slipRow == nil),
            Check("dismissedRoomToneIsRemoved", !fm.fileExists(atPath: slipFile.url.path)),
        ])

        return [keep, boot, now, dismiss]
    }

    /// A fixture chain that answers at once, so the drill spends nothing.
    private struct Says: RecoveryTranscriptionProvider {
        let name = "drill-fixture"
        let isConfigured = true
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            TranscriptionResult(text: "the drill heard it", finality: .recoveryForcedFinal, provider: name)
        }
    }

    /// The drill is synchronous (it runs inside the launch gate and `tbase
    /// keepdrill`); the dismiss path is async because transcription is.
    /// Bridged with a semaphore on a detached task, never on the caller's
    /// executor.
    private static func awaitDismiss(store: QueueStore, audioStore: AudioStore, pcm16: Data, peak: Float,
                                     preWritten: URL, utteranceId: String) throws -> Utterance? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            defer { done.signal() }
            do {
                let row = try await store.keepDismissedCapture(
                    pcm16: pcm16, sampleRate: 16000, peak: peak, audioStore: audioStore,
                    chain: RecoveryChain(providers: [Says()], maxAttemptsPerProvider: 1, backoff: [0], floorAfter: nil),
                    preWritten: preWritten, utteranceId: utteranceId)
                box.set(.success(row))
            } catch {
                box.set(.failure(error))
            }
        }
        done.wait()
        return try box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private var result: Result<Utterance?, Error> = .success(nil)
        private let lock = NSLock()
        func set(_ r: Result<Utterance?, Error>) { lock.lock(); result = r; lock.unlock() }
        func get() throws -> Utterance? { lock.lock(); defer { lock.unlock() }; return try result.get() }
    }
}
