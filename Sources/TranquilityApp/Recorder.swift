import AVFoundation
import Foundation
import ObjCExceptionFirewall
import TranquilityCore

/// Microphone capture for push-to-talk.
///
/// Buffers converted PCM16 in memory while the key is held and flushes once on
/// release, **before** anything touches the network. Per-chunk write-ahead was
/// considered and rejected: it only buys the crash-mid-utterance case, and the
/// failures that actually happen are network and API ones, which a single flush at
/// key-up already covers. That is a deliberate line, not an oversight.
public final class Recorder: @unchecked Sendable {
    public enum RecorderError: Error, Sendable {
        case microphoneDenied
        case engineFailed(String)
        case nothingRecorded
    }

    /// Rebuilt, never merely restarted. `AVAudioEngine.inputNode` caches its
    /// stream description and does NOT renegotiate when the hardware re-rates
    /// underneath it, so an engine that outlives a device change reports a
    /// format that no longer exists — and `installTap` refuses it. Only a fresh
    /// engine re-reads the hardware. See `rebindEngine`.
    ///
    /// `var`, but not shared state: it is touched only in `start`/`stop`/
    /// `abandon`, which the `running` guard serializes. The tap callback never
    /// reads it.
    private var engine = AVAudioEngine()
    private let sampleRate: Double
    private var buffer = Data()
    private let lock = NSLock()

    /// Optional live-transcription stream, one per utterance. Set once at app
    /// init; the Recorder creates a stream at every mic-open and feeds it from
    /// the tap. The stream can only ever ADD speed — the durable buffer and the
    /// file-based recovery path are untouched whatever the stream does.
    public var streamFactory: (@Sendable () -> StreamedUtterance?)?
    private var stream: StreamedUtterance?
    private var running = false

    /// Live input level, for a waveform or an orb pulse.
    public private(set) var level: Float = 0
    /// Loudest moment of the current recording; the silence gate reads it.
    public private(set) var peakLevel: Float = 0

    /// What the tap actually handed us, and how much of it survived conversion.
    ///
    /// These two numbers separate the three ways a capture comes back empty,
    /// which nothing in the log could tell apart before:
    ///
    ///   delivered 0, kept 0    the tap never fired. The engine started, the
    ///                          graph is not rendering, and no microphone was
    ///                          ever really open — the case behind 10 Aug's
    ///                          24.14s / 29.01s / 67.21s captures at peak 0.0000.
    ///   delivered n, kept 0    the device is feeding us and every buffer fails
    ///                          conversion. A format problem downstream of the
    ///                          tap, not a dead input.
    ///   delivered n, kept n    the device is honest; if `peakLevel` is also 0 it
    ///                          is sending real silence, which is a muted or
    ///                          denied mic (CourtesyCheck already names that one).
    ///
    /// Counted rather than inferred on purpose. `peakLevel` cannot stand in for
    /// them: `rms` reads `floatChannelData` and returns 0 for an Int16 buffer, so
    /// a peak of 0 is consistent with all three and proves none of them.
    public private(set) var tapBuffersDelivered = 0
    public private(set) var tapBuffersKept = 0

    /// How long the microphone was open for the last capture, by the wall clock.
    ///
    /// Deliberately NOT the length of the audio, and the difference is the whole
    /// point. Duration measured from the buffer is a measure of what the DEVICE
    /// gave us: a microphone that yields no samples reports a zero-length
    /// recording however long you held the key, so buffer-length cannot tell a
    /// slip of the thumb from a dead input — both read as "too short". The wall
    /// clock can, and that distinction is what decides whether the panel says
    /// nothing, says one quiet line, or says something is actually wrong.
    ///
    /// Recorded before the `nothingRecorded` guard in `stop()`, because the case
    /// that most needs it is exactly the one that throws.
    public private(set) var lastOpenSeconds: TimeInterval = 0
    private var openedAt: Date?

    public init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
    }

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Only prompts when the status is undetermined — macOS never re-prompts after a
    /// denial, so the UI has to send the user to System Settings instead.
    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// `openingStream: false` is the instant-arm path (docs/instant-arm.md):
    /// capture begins optimistically at the arm window WITHOUT creating a
    /// StreamedUtterance — no network session for audio that a tap will
    /// discard. The stream attaches at hold-resolution via `openStream()`,
    /// which feeds it everything buffered since this call.
    public func start(openingStream: Bool = true) throws {
        guard Self.microphoneAuthorized() else { throw RecorderError.microphoneDenied }
        lock.lock()
        guard !running else { lock.unlock(); return }
        buffer.removeAll(keepingCapacity: true)
        peakLevel = 0
        tapBuffersDelivered = 0
        tapBuffersKept = 0
        openedAt = Date()
        lastOpenSeconds = 0
        running = true
        if let stale = stream {
            // An aborted utterance never took its stream; close it quietly.
            stream = nil
            Task { _ = await stale.finish(timeout: 0) }
        }
        if openingStream {
            stream = streamFactory?()
            if let s = stream { Task { await s.start() } }
        }
        lock.unlock()

        // Replying while the announcement is still playing is the normal case,
        // and it is exactly when the audio device is mid route-change: the input
        // briefly reports 0 Hz / 0 channels, and installTap on that format
        // throws an ObjC NSException rather than a Swift error. The change
        // settles in tens of milliseconds, so ride through it — a press during
        // playback must open the mic, not report an error about audio plumbing.
        // Worst case here is ~480ms before giving up, well under the event-tap
        // watchdog.
        var lastReason = "unknown"
        for attempt in 0..<6 {
            // A retry that re-asks the same cached question is not a retry. Every
            // attempt past the first gets a NEW engine, because the failure this
            // loop rides through can be a stale format rather than a transient
            // one — and from in here those are indistinguishable. The stale case
            // used to burn all six attempts in 480ms on six byte-identical
            // mismatch errors and then give up (app.log 07 Aug, 15:12:19–15:13:04:
            // a cached 48000 against AirPods that had re-rated to 24000).
            if attempt > 0 { usleep(80_000) }
            let input = rebindEngine(rebuilding: attempt > 0)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                lastReason = "input format invalid (rate=\(format.sampleRate), "
                    + "channels=\(format.channelCount)) — audio device mid route-change"
                continue
            }

            // Firewalled: any NSException AVFoundation still throws becomes a
            // Swift error instead of unwinding through the caller's main-queue
            // block. One such unwind wedged the main dispatch queue permanently —
            // panel frozen, gestures dead, main thread sampling as idle
            // (2026-08-05, 18:01:11Z).
            var startError: Error?
            let exception = VDCatchObjCException {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcmBuffer, _ in
                    guard let self else { return }
                    // Convert first, outside the lock, as before — it is the
                    // expensive part and nothing else needs serialising for it.
                    let converted = BuddyPCM16Converter.pcm16Data(
                        from: pcmBuffer, targetSampleRate: self.sampleRate)
                    self.lock.lock()
                    // Counted BEFORE the conversion is consulted, so "the tap
                    // fired" and "the buffer survived" stay separable. Counting
                    // only successes would collapse the two failures this exists
                    // to tell apart back into one indistinguishable empty buffer.
                    self.tapBuffersDelivered += 1
                    var liveStream: StreamedUtterance?
                    if let converted {
                        self.tapBuffersKept += 1
                        self.buffer.append(converted)
                        liveStream = self.stream
                    }
                    self.lock.unlock()
                    if let converted { liveStream?.feed(pcm16: converted) }
                    let rms = Self.rms(of: pcmBuffer)
                    self.level = rms
                    if rms > self.peakLevel { self.peakLevel = rms }
                }
                engine.prepare()
                do { try engine.start() } catch { startError = error }
            }

            if exception == nil && startError == nil {
                // Say WHICH device the capture is bound to and at WHAT rate the
                // tap was installed. `warmUp` logged the bind at launch and
                // nothing logged it again, so every mid-session rebind — the
                // exact path a capture comes back empty on — left no record of
                // what was in play. Reasoning from an absent error line is not
                // evidence, which is the same standard `warmUp`'s own comment sets.
                //
                // The deviceID is read raw, never resolved to a name: resolving
                // walks CoreAudio, and this is the instant-arm path, which budgets
                // ~80ms end to end. The name costs nothing on the failure path,
                // where `reportNothingHeard` already resolves it.
                Permissions.log("mic: open attempt \(attempt + 1) "
                    + "deviceID=\(input.auAudioUnit.deviceID) "
                    + "tap=\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
                    + (attempt > 0 ? " after: \(lastReason)" : ""))
                // Marked only once the microphone is genuinely open, and after the
                // work that opening costs — so this cannot delay capture starting,
                // only the return to the caller. See CaptureMarker: the reader is
                // the relaunch script, which must not kill an utterance that is
                // still only in memory.
                CaptureMarker.begin()
                return
            }
            _ = VDCatchObjCException { input.removeTap(onBus: 0); engine.stop() }
            lastReason = exception.map { "\($0.name.rawValue): \($0.reason ?? "no reason")" }
                ?? "\(startError!)"
        }

        lock.lock(); running = false; lock.unlock()
        throw RecorderError.engineFailed(lastReason)
    }

    /// Bind to the preferred input NOW, at launch, instead of on the first press.
    ///
    /// At launch the engine is always on the wrong device: AVAudioEngine comes up
    /// bound to the system default, which is precisely the device the preference
    /// exists to avoid. So `rebindEngine` was guaranteed to rebuild — and left to
    /// `start()`, that rebuild landed on the first arm gesture of every launch.
    /// Measured on this hardware: 42.3 / 46.3 / 85.6 ms (min/median/max) against
    /// instant-arm's ~80ms grace, so the slowest press blew the window that the
    /// whole optimistic-capture design is built on.
    ///
    /// Paid here it is invisible, and every press afterwards finds the engine
    /// already bound and reuses it. The cost did not go away; it moved off the
    /// only path where it was ever visible.
    public func warmUp() {
        _ = rebindEngine(rebuilding: false)
        // Say which device won, POSITIVELY. Only the failure path logged before,
        // so a successful bind was indistinguishable from a bind that never ran —
        // and confirming the fix meant reasoning from the absence of an error
        // line, which is not evidence. The one thing this whole change turns on
        // is which microphone is live; the log should simply say so.
        let bound = AudioInputDevice.allInputs()
            .first { $0.id == engine.inputNode.auAudioUnit.deviceID }
        Permissions.log("mic: bound to \(bound?.name ?? "engine default") "
            + "(preference: \(AudioInputPreference.current.rawValue))")
    }

    /// Point the engine at the preferred input, rebuilding it when that cannot be
    /// done in place, and hand back the node to install a tap on.
    ///
    /// A device change is ALWAYS a rebuild. Binding a device invalidates the input
    /// node's cached stream description and `outputFormat(forBus:)` does not
    /// renegotiate to match — the documented trap behind "0 channels after
    /// changing deviceID". A fresh engine reads the hardware once, correctly,
    /// rather than being asked to correct itself.
    ///
    /// Steady state costs nothing: the engine is reused whenever it is already on
    /// the right device, which is every press except the first and the ones where
    /// the hardware genuinely moved.
    private func rebindEngine(rebuilding: Bool) -> AVAudioInputNode {
        let desired = AudioInputDevice.resolve()
        let mismatched = desired.map { engine.inputNode.auAudioUnit.deviceID != $0.id } ?? false
        guard rebuilding || mismatched else { return engine.inputNode }

        _ = VDCatchObjCException { engine.stop() }
        engine = AVAudioEngine()
        if let desired {
            do { try engine.inputNode.auAudioUnit.setDeviceID(desired.id) }
            catch {
                // Not fatal. An unbindable device means capture falls back to
                // whatever the engine picks, which still records — but it is the
                // difference between "on AirPods anyway" and a broken preference,
                // so it does not get to fail quietly.
                Permissions.log("mic: could not bind \(desired.name): \(error)")
            }
        }
        return engine.inputNode
    }

    /// Attach the live stream to a capture that is already running — the
    /// instant-arm upgrade (docs/instant-arm.md). Everything buffered since
    /// the mic opened is fed FIRST, under the same lock the tap uses to
    /// publish the stream, so no live chunk can jump ahead of the backlog:
    /// the tap reads `stream` under this lock, and any chunk that read nil
    /// is already in the backlog being fed here. Pre-socket delivery rides
    /// StreamedUtterance's own pre-open buffer (the buffer-then-flush design
    /// documented in AssemblyAIStreaming.swift), so the transcript covers
    /// the arm window even though the socket opens after this returns.
    public func openStream() {
        lock.lock()
        guard running, stream == nil else { lock.unlock(); return }
        let s = streamFactory?()
        if let s, !buffer.isEmpty { s.feed(pcm16: buffer) }
        stream = s
        lock.unlock()
        if let s { Task { await s.start() } }
    }

    /// Seconds of audio captured so far (PCM16 mono at `sampleRate`) — the
    /// arm-window accounting the latency log reports at upgrade.
    public var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(buffer.count) / 2.0 / sampleRate
    }

    /// Take ownership of this utterance's live stream (nil if none was created
    /// or it was already taken). Callers `await finish()` it — which returns nil
    /// on ANY stream problem, in which case the file path recovers as always.
    public func takeStream() -> StreamedUtterance? {
        lock.lock(); defer { lock.unlock() }
        let s = stream
        stream = nil
        return s
    }

    /// Stop capturing and hand back everything recorded. The caller persists it
    /// before doing anything else.
    @discardableResult
    public func stop() throws -> Data {
        lock.lock()
        // Never ran, or already stopped: there is no "how long was it open"
        // answer for THIS event, and leaving the last capture's answer standing
        // would let a stale five seconds masquerade as a fresh device fault.
        guard running else {
            lastOpenSeconds = 0
            lock.unlock(); throw RecorderError.nothingRecorded
        }
        running = false
        // Before the nothingRecorded guard below, on purpose: a dead device
        // takes that throw, and how long it was open is the only evidence the
        // caller will have to work with.
        lastOpenSeconds = openedAt.map { Date().timeIntervalSince($0) } ?? 0
        openedAt = nil
        lock.unlock()

        _ = VDCatchObjCException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // The words are about to be handed back, so the utterance is no longer
        // only in memory and a relaunch can proceed.
        CaptureMarker.end()
        level = 0

        lock.lock()
        let captured = buffer
        let delivered = tapBuffersDelivered
        let kept = tapBuffersKept
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        // One line per capture, success or failure, because the failures are only
        // legible next to what a working capture looks like. Logged BEFORE the
        // nothingRecorded guard for the same reason `lastOpenSeconds` is recorded
        // before it: the case that most needs the evidence is the one that throws.
        Permissions.log(String(
            format: "capture: %.2fs open, tap delivered %d, kept %d, %d bytes, peak %.4f",
            lastOpenSeconds, delivered, kept, captured.count, peakLevel))

        guard captured.count > 1600 else { throw RecorderError.nothingRecorded }  // <50ms
        return captured
    }

    /// Abandon without returning audio — used when a press is cancelled before the
    /// engine ever produced anything.
    public func abandon() {
        lock.lock()
        running = false
        lastOpenSeconds = openedAt.map { Date().timeIntervalSince($0) } ?? 0
        openedAt = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        _ = VDCatchObjCException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        CaptureMarker.end()
        level = 0
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}
