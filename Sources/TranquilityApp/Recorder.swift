import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import TranquilityCore

/// Microphone capture for push-to-talk.
///
/// Buffers converted PCM16 in memory while the key is held and flushes once on
/// release, with a durable write-ahead copy from the first frame
/// (`LiveAudioCapture`, see docs/measurement-audio-must-be-durable-from-the-
/// first-frame.md).
///
/// ## The 12 Aug 2026 redesign (research HQ: tb-micstate-auhal-plan)
///
/// Capture no longer goes through AVAudioEngine. On macOS the engine cannot
/// capture without first binding the system default input — `inputNode`
/// access alone creates a `CADefaultDeviceAggregate` around the default
/// devices (probe-verified on this machine) — which dragged AirPods into
/// SCO on every open, and coreaudiod blocks all IO starts while that
/// renegotiation is pending (`StartAndWaitForState` error 35). The old
/// six-attempt synchronous retry loop then retried INTO the block window,
/// re-triggering the renegotiation each time, while blocking the main
/// thread long enough for macOS to kill the CGEvent tap.
///
/// The replacement, in one sentence: a warm `CaptureUnit` (raw AUHAL pinned
/// to the chosen device, default never consulted) owned by a pure
/// `MicMachine` transition table, with an optimistic start, asynchronous
/// first-buffer verification, and event-classified backoff instead of
/// blocking retries. Five pieces of hand-tracked state died in this rewrite:
/// `running`, `staleFormat`, `forcedDevice`, `fellBackToBuiltIn`-as-flag
/// (it survives as a read-only fact the heal rung sets), and the retry
/// loop's implicit position. Nothing on the gesture path may block the main
/// thread — the per-press hardware cost is `AudioOutputUnitStart` on an
/// initialized unit.
public final class Recorder: @unchecked Sendable {
    public enum RecorderError: Error, Sendable {
        case microphoneDenied
        /// Kept under its historical name — main.swift's failure copy keys
        /// off it — but it now means "the capture stack refused the open",
        /// carrying the machine's reason.
        case engineFailed(String)
        case nothingRecorded
    }

    private let sampleRate: Double
    private var buffer = Data()
    private let lock = NSLock()

    /// The machine. Guarded by `lock`; every submission happens under it,
    /// and effects run only when a transition is accepted.
    private var machine = MicMachine()

    /// All unit construction, start/stop, teardown, listeners, and heals run
    /// here, in program order. One serial owner is the safe reading of
    /// AUHAL's undocumented thread-safety — and it is what keeps the main
    /// thread out of the hardware's way entirely.
    private let audioQueue = DispatchQueue(label: "base.tranquility.capture-unit")
    private var unit: CaptureUnit?
    /// Listeners registered on the bound device, so a rebuild can remove
    /// exactly what it added.
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Optional live-transcription stream, one per utterance. Unchanged from
    /// the engine era: the stream can only ever ADD speed — the durable
    /// buffer and the file-based recovery path are untouched whatever the
    /// stream does.
    public var streamFactory: (@Sendable () -> StreamedUtterance?)?
    private var stream: StreamedUtterance?

    /// Everything one finished capture produced (see stop()).
    public struct Capture: Sendable {
        public let pcm16: Data
        public let fileURL: URL?
    }

    private var liveCapture: LiveAudioCapture?

    /// True while capture runs on the built-in mic because the preferred
    /// (Bluetooth) device failed and the heal rung retargeted. Read by the
    /// menu; cleared by `warmUp` so a retreat never outlives its cause.
    public private(set) var fellBackToBuiltIn = false

    /// Live input level, for a waveform or an orb pulse.
    public private(set) var level: Float = 0
    /// Loudest moment of the current recording; the silence gate reads it.
    public private(set) var peakLevel: Float = 0

    /// What the render callback actually delivered and how much survived
    /// conversion — the three-way postmortem separator (tap never fired /
    /// format failure / honest silence). Semantics unchanged.
    public private(set) var tapBuffersDelivered = 0
    public private(set) var tapBuffersKept = 0

    /// How long the microphone was open for the last capture, by the wall
    /// clock — the evidence `reportNothingHeard` reasons from.
    public private(set) var lastOpenSeconds: TimeInterval = 0
    private var openedAt: Date?

    /// The open under verification: generation + the scheduled verdict.
    private var verification: DispatchWorkItem?
    /// True until the first buffer of the current open lands; the render
    /// callback checks it so the machine is submitted to exactly once.
    private var awaitingFirstBuffer = false

    /// An async open failure (verification timeout, start error) after
    /// `start()` already returned optimistically. Invoked on the main queue;
    /// the host ends the listening face honestly. The message is
    /// user-showable.
    public var onCaptureFault: ((String) -> Void)?
    /// The machine crossed the wedge threshold. Invoked on the main queue,
    /// once per wedge entry, after the capture fault for the same open.
    public var onWedge: (() -> Void)?

    /// Deferred teardown: a device config change landed mid-capture. The
    /// capture keeps whatever audio arrives; the unit is discarded and
    /// rebuilt when the capture ends rather than under it.
    private var discardAfterCapture = false

    /// Verification windows. Warm unit: generous but invisible — nothing
    /// blocks on it. The old 250ms ceiling sat BELOW the ~730ms cold HAL
    /// start and manufactured failures after idle; these do not, because
    /// they are async and the cold cost is prepaid at warm-up.
    static let verifyWindow: TimeInterval = 1.0
    /// Backoff before rebuilding after a config change — OBS's shipped
    /// calibration: a default-device change settles fast; a format change
    /// (the Bluetooth profile flip) needs the long wait.
    static let rebuildAfterDefaultChange: TimeInterval = 0.3
    static let rebuildAfterFormatChange: TimeInterval = 2.0
    /// One background heal attempt after a wedge, then the machinery stays
    /// quiet: the Aug 12 evidence is that in-process retries cannot clear a
    /// wedged period, so recovery beyond this is the relaunch path's job.
    static let healDelay: TimeInterval = 5.0

    /// Marker heartbeat (unchanged): says "a live capture owns the mic" on
    /// its own queue, because the main queue is the one thing in this app
    /// already known to wedge.
    private let markerQueue = DispatchQueue(label: "base.tranquility.capture-marker")
    private var markerTimer: DispatchSourceTimer?

    public init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
    }

    // MARK: - Authorization (unchanged)

    public static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Machine-derived facts

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        switch machine.state {
        case .opening, .capturing: return true
        default: return false
        }
    }

    /// The hands-free gate: an announcement finishing must not auto-open a
    /// microphone the machine knows is wedged.
    public var allowsAutoArm: Bool {
        lock.lock(); defer { lock.unlock() }
        return machine.state.allowsAutoArm
    }

    public var micStateName: String {
        lock.lock(); defer { lock.unlock() }
        return machine.state.name
    }

    private func submit(_ event: MicEvent, because reason: String) -> MicTransition {
        lock.lock()
        let before = machine.state.name
        let transition = machine.submit(event)
        let after = machine.state.name
        lock.unlock()
        // Deliberately NOT the panel's "state: X -> Y" / "state: REFUSED"
        // shape: check-selftests.sh greps those exact tokens to judge the
        // PANEL after the drills, and a mic refusal (which the table emits
        // by design — stale generations, wedged prepares) must never read
        // as a stuck panel and fail a deploy.
        if transition.accepted, before != after {
            Permissions.log("mic: \(before) -> \(after)  (\(reason))")
        } else if !transition.accepted {
            Permissions.log("mic: refused \(event) in \(before)  (\(reason))")
        }
        return transition
    }

    // MARK: - Warm-up and unit lifecycle (audioQueue only)

    /// Bind, build and initialize the unit NOW, off the gesture path, and
    /// pre-pay the HAL device start with one start/stop cycle. Called at
    /// launch and on a mic-preference change; also the door that retires a
    /// Bluetooth retreat.
    public func warmUp() {
        audioQueue.async { [self] in
            fellBackToBuiltIn = false
            prepareUnit(preferring: nil, because: "warmUp")
            prepayStart()
        }
    }

    /// The device this recorder should bind, honoring an explicit override
    /// from the heal rung. Only the systemDefault preference ever consults
    /// the default device — for the builtIn default (and any explicit
    /// device), the default is never queried and Bluetooth never hears
    /// from us.
    private func resolveDeviceID(preferring override: AudioInputDevice.Device?) -> AudioDeviceID? {
        if let override { return override.id }
        if let resolved = AudioInputDevice.resolve() { return resolved.id }
        // Preference is systemDefault (or resolution failed): ask the HAL
        // for the default input, explicitly — the user chose to track it.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// Build (or keep) the unit for the chosen device. audioQueue only.
    @discardableResult
    private func prepareUnit(preferring override: AudioInputDevice.Device?,
                             because reason: String) -> Bool {
        guard Self.microphoneAuthorized() else {
            Permissions.log("mic: prepare skipped — not authorized")
            return false
        }
        guard let deviceID = resolveDeviceID(preferring: override) else {
            Permissions.log("mic: prepare failed — no input device resolvable")
            return false
        }
        if let unit, unit.deviceID == deviceID {
            // Already warm on the right device; nothing to pay.
            _ = submit(.unitPrepared, because: "\(reason) (already bound)")
            return true
        }
        teardownUnit()
        do {
            let built = try CaptureUnit(deviceID: deviceID) { [weak self] pcmBuffer in
                self?.deliver(pcmBuffer)
            }
            unit = built
            installListeners(on: deviceID)
            let name = AudioInputDevice.allInputs().first { $0.id == deviceID }?.name
                ?? "device \(deviceID)"
            Permissions.log("mic: unit prepared on \(name) "
                + "tap=\(Int(built.clientFormat.sampleRate))Hz/"
                + "\(built.clientFormat.channelCount)ch (\(reason))")
            _ = submit(.unitPrepared, because: reason)
            return true
        } catch {
            Permissions.log("mic: unit build FAILED on device \(deviceID): \(error) (\(reason))")
            _ = submit(.unitDiscarded, because: "build failed")
            return false
        }
    }

    /// One start/stop cycle so the first press finds hardware that has
    /// already spun up — the ~730ms cold HAL start is paid here, invisibly,
    /// instead of being misclassified as a dead graph on the first press
    /// after launch. audioQueue only.
    private func prepayStart() {
        guard let unit else { return }
        let began = Date()
        do {
            try unit.start()
            unit.stop()
            Permissions.log(String(format: "mic: prepay start/stop %.0fms",
                                   Date().timeIntervalSince(began) * 1000))
        } catch {
            Permissions.log("mic: prepay start failed: \(error)")
        }
    }

    private func teardownUnit() {
        removeListeners()
        unit?.dispose()
        unit = nil
    }

    // MARK: - Config-change listeners (the settle machinery)

    private func installListeners(on deviceID: AudioObjectID) {
        // The block is invoked on `audioQueue` (passed at registration), so
        // handleConfigChange runs on the one serial owner — the old
        // observer's data race (queue: nil, mutating a flag from the posting
        // thread) is unrepresentable here.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleConfigChange()
        }
        listenerBlock = block
        // StreamConfiguration listens on the INPUT scope — that is the side
        // a Bluetooth profile flip reshapes; the global scope does not
        // reliably fire for it. Rate and liveness are global facts.
        let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        ]
        for (selector, scope) in watched {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(deviceID, &addr, audioQueue, block) == noErr {
                listeners.append((deviceID, addr))
            }
        }
    }

    private func removeListeners() {
        guard let block = listenerBlock else { return }
        for (device, address) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(device, &addr, audioQueue, block)
        }
        listeners = []
        listenerBlock = nil
    }

    /// audioQueue only. The device under our unit changed shape (the
    /// Bluetooth profile flip re-rates it) or is going away. The old engine
    /// discovered this by failing on the next open, once per capture,
    /// forever; the unit hears it from the HAL and rebuilds once, after the
    /// change has had time to settle. The delay is OBS's shipped format-
    /// change calibration (2s); the shorter default-change delay (300ms)
    /// applies only to a default-tracking preference, which installs no
    /// listener today — noted so the constant isn't mistaken for dead code.
    private func handleConfigChange() {
        lock.lock()
        let state = machine.state
        lock.unlock()
        Permissions.log("mic: device config changed (state=\(state.name)); "
            + "rebuild in \(Int(Self.rebuildAfterFormatChange * 1000))ms")
        switch state {
        case .capturing, .opening:
            // Never tear the unit out from under a live capture: whatever
            // audio still arrives belongs to the user. The rebuild runs
            // when the capture ends.
            lock.lock(); discardAfterCapture = true; lock.unlock()
        case .cold, .warm, .wedged:
            _ = submit(.unitDiscarded, because: "device config changed")
            teardownUnit()
            audioQueue.asyncAfter(deadline: .now() + Self.rebuildAfterFormatChange) { [weak self] in
                guard let self else { return }
                self.prepareUnit(preferring: nil, because: "rebuild after config change")
            }
        }
    }

    // MARK: - The open

    /// Begin a capture. Optimistic by design: on a warm unit this is
    /// bookkeeping plus an `AudioOutputUnitStart` dispatched to the audio
    /// queue, and it returns immediately — audio-arrival verification runs
    /// asynchronously, and an open that produces no audio surfaces through
    /// `onCaptureFault` (and, on the second consecutive failure, `onWedge`).
    ///
    /// Throws only for immediate, certain refusals: no permission, a wedged
    /// machine, or no buildable unit. A thrown open never opened anything.
    ///
    /// `openingStream: false` is the instant-arm path (docs/instant-arm.md):
    /// capture begins at the arm window without a network session; the
    /// stream attaches at hold-resolution via `openStream()`.
    public func start(openingStream: Bool = true) throws {
        guard Self.microphoneAuthorized() else { throw RecorderError.microphoneDenied }

        lock.lock()
        switch machine.state {
        case .wedged:
            lock.unlock()
            throw RecorderError.engineFailed(
                "microphone stack is wedged, capture suspended until it heals or the app relaunches")
        case .opening, .capturing:
            // Idempotent, as before: a second start during a live capture
            // is a no-op, not an error.
            lock.unlock()
            return
        case .cold, .warm:
            lock.unlock()
        }

        // Capture bookkeeping, exactly as the engine era did it. Everything
        // here is lock-and-local-disk work — the HAL is not consulted.
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        peakLevel = 0
        tapBuffersDelivered = 0
        tapBuffersKept = 0
        openedAt = Date()
        lastOpenSeconds = 0
        awaitingFirstBuffer = true
        liveCapture = try? LiveAudioCapture(
            utteranceId: "capture-\(UUID().uuidString)",
            sampleRate: sampleRate,
            directory: QueueStore.audioDirectory)
        if let stale = stream {
            stream = nil
            Task { _ = await stale.finish(timeout: 0) }
        }
        if openingStream {
            stream = streamFactory?()
            if let s = stream { Task { await s.start() } }
        }
        lock.unlock()

        // Marked from the instant we intend to capture: the marker protects
        // audio that exists only in memory, and buffering begins with the
        // first render callback, which may precede any verification.
        beginMarkerHeartbeat()

        // EVERYTHING hardware-shaped happens off the caller's thread —
        // including the cold-path prepare. The 20:30 beach-ball (sampled
        // live, old binary) was not the retry loop: it was a synchronous
        // HAL format query inside inputNode access that never returned
        // while a config change was pending. The gesture path therefore
        // contains no HAL call at all, not even behind a `sync` — a hung
        // HAL wedges the audio queue, and the verdict below (which runs on
        // a DIFFERENT queue for exactly that reason) reports the dead press
        // instead of a frozen app.
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillWanted = self.awaitingFirstBuffer
            let state = self.machine.state
            self.lock.unlock()
            // The press may have been superseded (stop/abandon/verdict fired
            // while this waited behind a slow queue) — a capture must never
            // start for a press nobody is holding any more.
            guard stillWanted else { return }
            if case .cold = state {
                guard self.prepareUnit(preferring: nil, because: "open on cold") else {
                    self.failPress(why: "no usable input device")
                    return
                }
            }
            let open = self.submit(.openRequested, because: "capture requested")
            guard open.accepted, case .opening(let generation) = open.state else {
                self.failPress(why: "open refused from \(self.micStateName)")
                return
            }
            guard let unit = self.unit else {
                self.failOpen(generation: generation, why: "unit vanished before start")
                return
            }
            do { try unit.start() } catch {
                self.failOpen(generation: generation, why: "start failed: \(error)")
                return
            }
        }

        // The verdict, scheduled on its OWN queue — never the audio queue,
        // whose hang is one of the failure modes being judged. If no buffer
        // lands inside the window, the press is dead whatever the hardware
        // eventually says.
        let verdict = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let delivered = self.tapBuffersDelivered
            let pending = self.awaitingFirstBuffer
            let state = self.machine.state
            self.lock.unlock()
            guard delivered == 0, pending else { return }
            if case .opening(let generation) = state {
                self.failOpen(generation: generation,
                              why: "started but no audio in \(Int(Self.verifyWindow * 1000))ms")
            } else {
                // The open never reached the hardware — the audio queue is
                // stuck in a HAL call. Off-main now, so it reads as one
                // honest fault instead of a beach-ball.
                self.failPress(why: "audio stack unresponsive, the open never reached the hardware")
            }
        }
        verification = verdict
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + Self.verifyWindow, execute: verdict)
    }

    /// A press died before the machine ever accepted an open (no generation
    /// exists to fail): unwind the bookkeeping and tell the host. Any thread.
    private func failPress(why: String) {
        lock.lock()
        guard awaitingFirstBuffer else { lock.unlock(); return }
        awaitingFirstBuffer = false
        let discarding = liveCapture
        liveCapture = nil
        buffer.removeAll(keepingCapacity: false)
        openedAt = nil
        lock.unlock()
        discarding?.abandon()
        endMarkerHeartbeat()
        level = 0
        Permissions.log("mic: press failed — \(why)")
        let message = "Couldn't open the microphone, \(why)."
        DispatchQueue.main.async { [weak self] in self?.onCaptureFault?(message) }
    }

    /// An open died after `start()` returned. Tear the capture down, tell
    /// the machine (stale generations are refused by the table), and tell
    /// the host. audioQueue or lock-free contexts only.
    private func failOpen(generation: Int, why: String) {
        let transition = submit(.openFailed(generation: generation), because: why)
        guard transition.accepted else { return }
        audioQueue.async { [weak self] in self?.unit?.stop() }
        lock.lock()
        let discarding = liveCapture
        liveCapture = nil
        buffer.removeAll(keepingCapacity: false)
        awaitingFirstBuffer = false
        lock.unlock()
        discarding?.abandon()
        endMarkerHeartbeat()
        level = 0
        Permissions.log("mic: open failed (gen \(generation)) — \(why)")
        let message = "Couldn't hear the microphone, \(why)."
        DispatchQueue.main.async { [weak self] in self?.onCaptureFault?(message) }

        if transition.effect == .enterWedge {
            Permissions.log("mic: WEDGED after \(MicMachine.wedgeThreshold) consecutive failures — "
                + "per-press retries stop; one background heal in \(Int(Self.healDelay))s")
            DispatchQueue.main.async { [weak self] in self?.onWedge?() }
            audioQueue.asyncAfter(deadline: .now() + Self.healDelay) { [weak self] in
                self?.attemptHeal()
            }
        }
    }

    /// One evidence-based recovery attempt: rebuild the unit — retargeting
    /// a failing Bluetooth device to the built-in mic, the f8a0db0 rung,
    /// now one line of the heal instead of a flag with its own lifecycle —
    /// then prove audio flows with a short start/verify/stop cycle before
    /// telling the machine anything. audioQueue only.
    private func attemptHeal() {
        lock.lock()
        let wedged: Bool = { if case .wedged = machine.state { return true }; return false }()
        lock.unlock()
        guard wedged else { return }

        var override: AudioInputDevice.Device?
        if let current = AudioInputDevice.resolve(), current.isBluetooth,
           let builtIn = AudioInputDevice.builtIn, builtIn.id != current.id {
            override = builtIn
        }
        teardownUnit()
        // The machine refuses `unitPrepared` while wedged — deliberately, so
        // a rebuilt unit alone never claims recovery. prepareUnit's submit
        // will log a REFUSED line here; that is the table working, not a
        // fault. Only `healed`, below, on evidence, moves the state.
        _ = prepareUnit(preferring: override, because: "heal attempt")
        guard let unit else {
            Permissions.log("mic: heal failed — unit would not build; staying wedged")
            return
        }
        do { try unit.start() } catch {
            Permissions.log("mic: heal failed — start refused: \(error); staying wedged")
            return
        }
        // Blocking THIS queue is fine — it is the audio queue's job to wait
        // on hardware, and nothing user-facing is behind it.
        let deadline = Date().addingTimeInterval(Self.verifyWindow)
        var heard = false
        while Date() < deadline {
            lock.lock(); heard = healProbeBuffers > 0; lock.unlock()
            if heard { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        unit.stop()
        lock.lock(); healProbeBuffers = 0; lock.unlock()
        if heard {
            if override != nil { fellBackToBuiltIn = true }
            _ = submit(.healed, because: "heal verified — audio flowed")
        } else {
            Permissions.log("mic: heal failed — unit started but delivered nothing; staying wedged")
        }
    }

    /// Buffers heard by a heal probe, counted separately so a probe can
    /// never be mistaken for a capture.
    private var healProbeBuffers = 0

    // MARK: - Buffer delivery (render thread)

    private func deliver(_ pcmBuffer: AVAudioPCMBuffer) {
        // Convert first, outside the lock — it is the expensive part and
        // nothing else needs serialising for it. Unchanged from the tap era.
        let converted = BuddyPCM16Converter.pcm16Data(
            from: pcmBuffer, targetSampleRate: sampleRate)
        lock.lock()
        // A heal probe is not a capture: count and bail.
        if case .wedged = machine.state {
            healProbeBuffers += 1
            lock.unlock()
            return
        }
        // Only a live open may append. The stop is asynchronous now, so a
        // few render callbacks can trail the machine leaving `capturing` —
        // and audio for a capture nobody owns must vanish, not leak into
        // the counters or the next press's buffer.
        switch machine.state {
        case .opening, .capturing: break
        default:
            lock.unlock()
            return
        }
        tapBuffersDelivered += 1
        var liveStream: StreamedUtterance?
        if let converted {
            tapBuffersKept += 1
            buffer.append(converted)
            liveStream = stream
        }
        let live = liveCapture
        let firstBuffer = awaitingFirstBuffer
        if firstBuffer { awaitingFirstBuffer = false }
        let generation = machine.generation
        lock.unlock()

        if firstBuffer {
            verification?.cancel()
            verification = nil
            let transition = submit(.firstBuffer(generation: generation), because: "audio arrived")
            // "The mic is open, talk now." Deliberately here and not at the
            // keypress: this is the first moment audio is PROVABLY flowing, and a
            // cue that fires on the press would be a promise the machine has not
            // kept yet — the exact case the `opening -> wedged` path exists for.
            // Gated on the transition being accepted, so a stale generation's late
            // buffer cannot announce a capture that is not this one.
            if transition.accepted {
                Earcons.acknowledge(.listening)
            }
        }
        if let converted {
            liveStream?.feed(pcm16: converted)
            try? live?.append(pcm16: converted)
        }
        let rms = Self.rms(of: pcmBuffer)
        level = rms
        if rms > peakLevel { peakLevel = rms }
    }

    // MARK: - Stream attach (instant-arm; unchanged semantics)

    public func openStream() {
        lock.lock()
        let live: Bool = {
            switch machine.state {
            case .opening, .capturing: return true
            default: return false
            }
        }()
        guard live, stream == nil else { lock.unlock(); return }
        let s = streamFactory?()
        if let s, !buffer.isEmpty { s.feed(pcm16: buffer) }
        stream = s
        lock.unlock()
        if let s { Task { await s.start() } }
    }

    /// Seconds of audio captured so far — the arm-window accounting.
    public var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(buffer.count) / 2.0 / sampleRate
    }

    public func takeStream() -> StreamedUtterance? {
        lock.lock(); defer { lock.unlock() }
        let s = stream
        stream = nil
        return s
    }

    // MARK: - Stop / abandon

    /// Stop capturing and hand back everything recorded. The caller persists
    /// it before doing anything else.
    @discardableResult
    public func stop() throws -> Capture {
        let ended = submit(.captureEnded, because: "key-up")
        guard ended.accepted else {
            // Nothing was ever recording — either no press was live, or the
            // press is still stuck behind an unresponsive audio queue. Unwind
            // whatever bookkeeping the press left so the marker and the
            // write-ahead file cannot outlive it.
            lock.lock()
            lastOpenSeconds = 0
            let hadPress = awaitingFirstBuffer
            awaitingFirstBuffer = false
            let discarding = liveCapture
            liveCapture = nil
            buffer.removeAll(keepingCapacity: false)
            openedAt = nil
            lock.unlock()
            if hadPress {
                discarding?.abandon()
                endMarkerHeartbeat()
                verification?.cancel(); verification = nil
            }
            throw RecorderError.nothingRecorded
        }
        lock.lock()
        lastOpenSeconds = openedAt.map { Date().timeIntervalSince($0) } ?? 0
        openedAt = nil
        awaitingFirstBuffer = false
        lock.unlock()

        verification?.cancel(); verification = nil
        // Async, never sync: AudioOutputUnitStop is a HAL call, and a HAL
        // mid-config-change can sit on any of its calls (the 20:30 sample).
        // The machine has already left `capturing`, so late render callbacks
        // are dropped by deliver()'s state check — the snapshot below cannot
        // be contaminated while the stop drains.
        audioQueue.async { [weak self] in self?.unit?.stop() }
        endMarkerHeartbeat()
        level = 0
        rebuildIfDeferred()

        lock.lock()
        let finishing = liveCapture
        liveCapture = nil
        let captured = buffer
        let delivered = tapBuffersDelivered
        let kept = tapBuffersKept
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        let captureURL = try? finishing?.close()

        Permissions.log(String(
            format: "capture: %.2fs open, tap delivered %d, kept %d, %d bytes, peak %.4f",
            lastOpenSeconds, delivered, kept, captured.count, peakLevel))

        guard captured.count > 1600 else { throw RecorderError.nothingRecorded }  // <50ms
        return Capture(pcm16: captured, fileURL: captureURL)
    }

    /// Abandon without returning audio — a press cancelled before anything
    /// came of it.
    public func abandon() {
        let ended = submit(.captureEnded, because: "abandoned")
        lock.lock()
        lastOpenSeconds = openedAt.map { Date().timeIntervalSince($0) } ?? 0
        openedAt = nil
        awaitingFirstBuffer = false
        let discarding = liveCapture
        liveCapture = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        discarding?.abandon()
        verification?.cancel(); verification = nil
        if ended.accepted {
            // Async for the same reason stop() is: no gesture waits on the HAL.
            audioQueue.async { [weak self] in self?.unit?.stop() }
        }
        endMarkerHeartbeat()
        level = 0
        rebuildIfDeferred()
    }

    /// A config change arrived mid-capture and was deferred; honor it now.
    private func rebuildIfDeferred() {
        guard discardAfterCapture else { return }
        discardAfterCapture = false
        audioQueue.async { [weak self] in
            guard let self else { return }
            _ = self.submit(.unitDiscarded, because: "deferred config change")
            self.teardownUnit()
            self.audioQueue.asyncAfter(deadline: .now() + Self.rebuildAfterFormatChange) { [weak self] in
                self?.prepareUnit(preferring: nil, because: "rebuild after deferred config change")
            }
        }
    }

    // MARK: - Marker heartbeat (unchanged)

    private func beginMarkerHeartbeat() {
        markerQueue.sync {
            CaptureMarker.begin()
            markerTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: markerQueue)
            timer.schedule(deadline: .now() + CaptureMarker.heartbeat,
                           repeating: CaptureMarker.heartbeat)
            timer.setEventHandler { CaptureMarker.refresh() }
            timer.resume()
            markerTimer = timer
        }
    }

    private func endMarkerHeartbeat() {
        markerQueue.sync {
            markerTimer?.cancel()
            markerTimer = nil
            CaptureMarker.end()
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}
