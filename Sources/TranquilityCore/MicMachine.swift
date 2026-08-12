import Foundation

/// What the microphone is doing, as one value rather than five flags.
///
/// PanelState's pattern applied to capture. The recorder used to track its
/// lifecycle in `running`, `staleFormat`, `forcedDevice`, `fellBackToBuiltIn`
/// and the implicit state of a six-attempt retry loop — five pieces of
/// hand-kept state whose interactions produced the Aug 12 failure shape:
/// a synchronous retry storm that re-triggered the Bluetooth renegotiation
/// it was waiting out, blocked the main thread past the event-tap watchdog,
/// and re-asked a blocked device six times per press. One case per state
/// makes those interactions a table instead of a reconstruction.
///
/// The machine is PURE: no CoreAudio imports, no side effects. The app-layer
/// Recorder owns one, submits events, and performs effects only when a
/// transition is accepted. That split is what makes the mic lifecycle
/// unit-testable for the first time.
public enum MicState: Equatable {
    /// No usable capture unit — launch, or the unit was discarded after a
    /// device/config change. A press from here must build before starting.
    case cold
    /// Unit built and initialized on the chosen device, not running. The
    /// resting state; a press from here pays only a start.
    case warm
    /// Start requested; audio has not yet proven it is flowing. Carries the
    /// generation so a late verdict for a superseded open is refusable by type.
    case opening(generation: Int)
    /// The first buffer arrived; capture is real.
    case capturing(generation: Int)
    /// Consecutive opens produced no audio (or the device refused binding).
    /// No automatic per-press retry leaves this state: retry churn is what
    /// sustained the Aug 12 flap. Exit is an explicit heal (re-prepare that
    /// succeeds) or process relaunch.
    case wedged(failures: Int)

    public var name: String {
        switch self {
        case .cold: return "cold"
        case .warm: return "warm"
        case .opening: return "opening"
        case .capturing: return "capturing"
        case .wedged: return "wedged"
        }
    }

    public var isCapturing: Bool {
        if case .capturing = self { return true }
        return false
    }

    /// The one question hands-free auto-arm asks. While wedged, an
    /// announcement finishing must NOT open the microphone on its own —
    /// each auto-open during the Aug 12 wedge burned ~2s of main thread
    /// with nobody at the keyboard.
    public var allowsAutoArm: Bool {
        if case .wedged = self { return false }
        return true
    }
}

/// Events the recorder can submit. Each carries the generation it belongs to
/// where staleness is possible.
public enum MicEvent: Equatable {
    /// Build + initialize succeeded on the chosen device.
    case unitPrepared
    /// The unit was torn down (config change, device gone, bind failure
    /// during prepare). The machine forgets it was ever warm.
    case unitDiscarded
    /// A capture was requested. Legal from `warm` (fast path) and from
    /// `cold` (the caller prepares first, then submits this after
    /// `unitPrepared`). Refused while another open/capture owns the mic
    /// and while wedged.
    case openRequested
    /// The first buffer arrived for this generation.
    case firstBuffer(generation: Int)
    /// The open failed for this generation: start error, bind refusal, or
    /// the verification window elapsed with zero buffers.
    case openFailed(generation: Int)
    /// The capture was stopped or abandoned by its owner.
    case captureEnded
    /// An explicit heal attempt succeeded (used by the background re-prepare
    /// path to leave `wedged` on evidence, never on hope).
    case healed
}

/// The outcome of submitting an event: whether it was accepted, and the
/// state that resulted. A refused event changes nothing — the caller must
/// not perform the effect it was proposing.
public struct MicTransition: Equatable {
    public let accepted: Bool
    public let state: MicState
    /// Non-nil when acceptance implies the caller should do something:
    /// currently only `.enterWedge` (stop retrying, tell the user once).
    public let effect: MicEffect?
}

public enum MicEffect: Equatable {
    /// The failure threshold was crossed: stop per-press retries, silence
    /// auto-arm, surface one honest fault.
    case enterWedge
}

/// The machine. A value type on purpose: tests copy it freely, and the
/// recorder replaces its copy atomically under its own lock.
public struct MicMachine: Equatable {
    public private(set) var state: MicState = .cold
    /// Monotonic. Minted at each accepted `openRequested`; every callback
    /// carries the generation of the open it belongs to, and a mismatch is
    /// refused by the table rather than guarded at call sites.
    public private(set) var generation = 0
    /// Consecutive failed opens. Reset by a first buffer or a heal.
    public private(set) var consecutiveFailures = 0

    /// Failures that flip the machine to `wedged`. Two, not six: the Aug 12
    /// evidence is that identical immediate retries against a blocked device
    /// all fail the same way, and the retries themselves sustained the
    /// Bluetooth flap they were waiting out.
    public static let wedgeThreshold = 2

    public init() {}

    @discardableResult
    public mutating func submit(_ event: MicEvent) -> MicTransition {
        func accept(_ next: MicState, _ effect: MicEffect? = nil) -> MicTransition {
            state = next
            return MicTransition(accepted: true, state: next, effect: effect)
        }
        func refuse() -> MicTransition {
            MicTransition(accepted: false, state: state, effect: nil)
        }

        switch (state, event) {
        // Preparing is legal from cold (launch, post-discard) and as a
        // re-prepare while warm (device preference changed). It never
        // interrupts a live open/capture — the owner must end it first.
        case (.cold, .unitPrepared), (.warm, .unitPrepared):
            return accept(.warm)
        // Never mid-open/mid-capture (the owner ends it first), and never a
        // silent exit from wedged — leaving wedged is `healed`'s job, which
        // demands a verified start, not merely a rebuilt unit.
        case (_, .unitPrepared):
            return refuse()

        // A discard is legal anywhere except mid-wedge (where the unit is
        // already presumed unusable; the failure count must survive).
        case (.wedged, .unitDiscarded):
            return refuse()
        case (_, .unitDiscarded):
            return accept(.cold)

        // Opens start from warm only. From cold the caller prepares first;
        // from opening/capturing a second open is a caller bug the table
        // refuses; from wedged, per-press retries are the disease.
        case (.warm, .openRequested):
            generation += 1
            return accept(.opening(generation: generation))
        case (_, .openRequested):
            return refuse()

        // Verification verdicts only count for the CURRENT generation of an
        // open that is still in flight. A late verdict for a superseded open
        // — the abandon-mid-open race — is refused by construction.
        case (.opening(let g), .firstBuffer(let vg)) where g == vg:
            consecutiveFailures = 0
            return accept(.capturing(generation: g))
        case (_, .firstBuffer):
            return refuse()

        case (.opening(let g), .openFailed(let vg)) where g == vg:
            consecutiveFailures += 1
            if consecutiveFailures >= Self.wedgeThreshold {
                return accept(.wedged(failures: consecutiveFailures), .enterWedge)
            }
            return accept(.warm)
        case (_, .openFailed):
            return refuse()

        // Ending a capture is legal from opening (abandon before the first
        // buffer) and capturing. The unit remains warm — ending a capture
        // is not evidence against the device.
        case (.opening, .captureEnded), (.capturing, .captureEnded):
            return accept(.warm)
        case (_, .captureEnded):
            return refuse()

        // Healing is evidence, not hope: only the background re-prepare
        // path submits it, and only after a prepare + verified start
        // succeeded. From anywhere else it is meaningless.
        case (.wedged, .healed):
            consecutiveFailures = 0
            return accept(.warm)
        case (_, .healed):
            return refuse()
        }
    }
}
