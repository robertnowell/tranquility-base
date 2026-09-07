import AppKit
import PostHog
import TranquilityCore

/// The product-event sink: PostHog, fed by `Track`, on the same toggle and
/// the same published config as the failure record.
///
/// Ruled 6 Sep 2026. Everything that reaches here has already passed
/// `Track`'s door (tokens, numbers, bools, hashes; no text), so this file
/// has no scrubbing to do. It has three jobs: start the SDK when a key is
/// known, hand each event over, and identify the install by its random id
/// with the facts that describe the machine, never the person.
///
/// The SDK's own automatic capture is off (lifecycle, screen views, session
/// replay); the app says what happened in its own words. Batched and
/// flushed by the SDK on a timer, off the main thread; a dropped network
/// queues on disk.
enum Analytics {
    static let channel = "track"
    @MainActor private static var started = false
    @MainActor private static var key: String?

    /// Called once, after the panel's first paint, beside Sentry.
    @MainActor
    static func start(key: String?, host: String?) {
        Track.trace = { Permissions.log("\(channel): \($0)") }
        self.key = key
        guard let key, !key.isEmpty else {
            // No sink yet: Track keeps a bounded backlog, so what happened
            // before the key arrived is not lost, it is waiting.
            Permissions.log("\(channel): dormant, no PostHog key configured")
            return
        }
        guard !started else { return }
        let t0 = Date()
        let config = PostHogConfig(apiKey: key, host: host ?? "https://us.i.posthog.com")
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.flushAt = 20
        config.flushIntervalSeconds = 30
        config.debug = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.identify(Failures.installId, userProperties: personProperties())
        PostHogSDK.shared.register(commonProperties())
        started = true
        // The sink attaches only now, AFTER setup: the SDK drops a capture it
        // receives before it is set up, and on the first deployed build the
        // sink was attached while the key was still being fetched, so the
        // launch's own events were replayed into a closed door and lost.
        // Track's backlog holds them until this line.
        Track.attach { event in forward(event) }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Permissions.log("\(channel): reporting on, sdk started in \(ms) ms")
    }

    /// The toggle. Off means the SDK keeps nothing and sends nothing.
    @MainActor
    static func apply(enabled: Bool) {
        guard started else { return }
        if enabled { PostHogSDK.shared.optIn() } else { PostHogSDK.shared.optOut() }
        Permissions.log("\(channel): \(enabled ? "opted in" : "opted out")")
    }

    @MainActor
    static func flush() { if started { PostHogSDK.shared.flush() } }

    /// After the install id is reset: a new person, same machine facts.
    @MainActor
    static func reidentify() {
        guard started else { return }
        PostHogSDK.shared.reset()
        PostHogSDK.shared.identify(Failures.installId, userProperties: personProperties())
        PostHogSDK.shared.register(commonProperties())
    }

    private static func forward(_ event: TrackEvent) {
        var props: [String: Any] = [:]
        for (k, v) in event.properties { props[k] = v.json }
        PostHogSDK.shared.capture(event.name, properties: props)
    }

    /// Facts about the machine and the build, none about the person.
    static func commonProperties() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        var props: [String: Any] = [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "?",
            "app_build": info["CFBundleVersion"] as? String ?? "?",
            "app_arch": EnvironmentProbe.currentArch,
            "app_translated": EnvironmentProbe.isTranslated,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            // The install id as a property in its own right, so that when
            // sign-in arrives and the distinct id becomes the person, the
            // machine each event came from is still on the event.
            "device_id": Failures.installId,
        ]
        if let commit = info["TBSourceCommit"] as? String { props["app_commit"] = String(commit.prefix(7)) }
        return props
    }

    static func personProperties() -> [String: Any] {
        var props = commonProperties()
        if let env = Failures.environment {
            for h in env.harnesses {
                props["harness_\(h.id)_installed"] = h.path != nil
                if let v = h.version { props["harness_\(h.id)_version"] = v }
            }
            props["tmux_version"] = env.tmuxVersion ?? "none"
        }
        return props
    }

    /// The gesture event, in one place so every chord records the same
    /// three things: what was pressed, which face it landed in, and what
    /// the app decided. Called from the gesture handler on the main actor.
    @MainActor
    static func gesture(_ chord: String, phase: String, decision: String,
                        face: PanelState, extra: [String: TrackValue] = [:]) {
        var props: [String: TrackValue] = [
            "chord": .token(chord), "phase": .token(phase), "decision": .token(decision),
            "face_before": .token(face.name),
        ]
        for (k, v) in extra { props[k] = v }
        Track.record("gesture", props)
    }
}
