import AppKit
import Sentry
import TranquilityCore

/// The app's half of the failure record, and the door it leaves through.
///
/// Ruled 6 Sep 2026. The record is built in Core (`Failures`); this file is
/// what only the app can know (its bundle, its permission states, where its
/// tmux resolved, when to look again) and what only the app may do: send.
///
/// Sending is Sentry, on by default with a menu toggle, and it is dormant
/// until a DSN exists. The DSN is not compiled in: it is read from
/// `diagnostics.json` beside the update feed (fetched off-main, cached, and
/// overridable with `TB_SENTRY_DSN` for a local test), so it can be rotated
/// without shipping a build, which is what Sentry recommends for apps on
/// other people's machines. No DSN, no SDK, no network.
///
/// What leaves: the failure records (`Failures.sink`), crashes and hangs the
/// SDK catches itself, MetricKit's diagnostics, and one "session started"
/// per launch for the crash-free rate. What never leaves: anything a person
/// or an agent said. `beforeSend` scrubs the event the same way the record
/// is scrubbed, the SDK's own PII collection is off, and every automatic
/// integration that would touch the audio or provider paths (network
/// swizzling, file I/O tracing, failed-request capture, performance
/// tracing) is off, so the SDK costs a crash handler, a two-second watchdog
/// and nothing on any path a person waits on.
enum Diagnostics {
    static let sendKey = "diagnostics.sendFailureReports"
    static let channel = "diagnostics"

    /// The toggle. Default on; explicitly stored once the user touches it.
    @MainActor
    static var sendingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: sendKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sendKey); apply() }
    }

    struct RemoteConfig: Codable, Equatable {
        var enabled: Bool?
        var sentryDsn: String?
        var org: String?
        var project: String?
    }

    static let remoteURL = URL(string: "https://updates.tranquilitybase.to/diagnostics.json")!
    private static var cacheURL: URL { QueueStore.supportDirectory.appendingPathComponent("diagnostics-config.json") }
    @MainActor private static var dsn: String?
    @MainActor private static var startedAt: Date?

    // MARK: Environment

    /// Take (or retake) the environment snapshot. Once at startup, and again
    /// after a launch failure, since a harness that was just reinstalled is
    /// exactly the fact the next record should carry.
    @MainActor
    static func refreshEnvironment(reason: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["TBSourceCommit"] as? String
        let permissions = Dictionary(uniqueKeysWithValues:
            Permissions.Kind.allCases.map { ($0.title, "\(Permissions.state($0))") })
        let tmux = Tmux.resolvedBinaryPath
        Task.detached(priority: .utility) {
            let snap = EnvironmentProbe.snapshot(
                appVersion: version, appBuild: build, sourceCommit: commit,
                permissions: permissions, tmuxPath: tmux)
            Failures.environment = snap
            tagScope(with: snap)
            let harnesses = snap.harnesses.map {
                "\($0.id)=\($0.path ?? "missing") slices=\($0.slices.joined(separator: "+")) v=\($0.version ?? "?")"
            }.joined(separator: "; ")
            Permissions.log("env: \(reason): arch=\(snap.appArch) translated=\(snap.appTranslated) "
                + "commit=\(snap.sourceCommit?.prefix(7) ?? "?") macOS=\(snap.macOS) "
                + "tmux=\(snap.tmuxVersion ?? "?") \(harnesses)")
        }
    }

    /// The "what we send" view: the local file, in whatever opens it, else
    /// Finder. Every line in it is one card the panel showed.
    @MainActor
    static func revealFailureLog() {
        guard let url = Failures.storeURL else { return }
        Failures.flush()
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @MainActor
    static func resetInstallId() {
        let fresh = Failures.resetInstallId()
        Permissions.log("\(channel): install id reset to \(fresh.prefix(8))")
        if SentrySDK.isEnabled { SentrySDK.configureScope { $0.setUser(User(userId: fresh)) } }
    }

    // MARK: Reporting

    /// Called once, after the panel's first paint. Wires the record to the
    /// SDK, starts the SDK if a DSN is already known, and asks for the
    /// current config off-main.
    @MainActor
    static func startReporting() {
        Breadcrumbs.shared.onRecord = { crumb in
            guard SentrySDK.isEnabled else { return }
            let b = Breadcrumb(level: .info, category: crumb.category)
            b.message = crumb.message
            SentrySDK.addBreadcrumb(b)
        }
        Failures.sink = { event in forward(event) }
        if let override = ProcessInfo.processInfo.environment["TB_SENTRY_DSN"], !override.isEmpty {
            dsn = override
            Permissions.log("\(channel): DSN from TB_SENTRY_DSN")
        } else if let cached = try? Data(contentsOf: cacheURL),
                  let config = try? JSONDecoder().decode(RemoteConfig.self, from: cached) {
            dsn = (config.enabled ?? true) ? config.sentryDsn : nil
        }
        apply()
        fetchRemoteConfig()
    }

    /// Reconcile the SDK with the toggle and the DSN. Idempotent.
    @MainActor
    private static func apply() {
        let want = sendingEnabled && !(dsn ?? "").isEmpty
        if want, !SentrySDK.isEnabled, let dsn { start(dsn: dsn) }
        if !want, SentrySDK.isEnabled {
            SentrySDK.close()
            startedAt = nil
            Permissions.log("\(channel): reporting off (\(sendingEnabled ? "no DSN" : "user toggle"))")
        }
        if !want, !SentrySDK.isEnabled, dsn == nil {
            Permissions.log("\(channel): dormant, no DSN configured")
        }
    }

    @MainActor
    private static func start(dsn: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let t0 = Date()
        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = false
            options.releaseName = "tranquility-base@\(version)"
            options.dist = build
            options.environment = "release"
            // Crashes, hangs over two seconds, MetricKit's own diagnostics.
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2
            options.enableMetricKit = true
            // Off: it registers NSApplicationCrashOnExceptions and changes
            // what an uncaught NSException does to the app.
            options.enableUncaughtNSExceptionReporting = false
            // Off: every automatic integration that would ride the audio,
            // provider or file paths. The SDK is here for failures.
            options.enableAutoPerformanceTracing = false
            options.enableSwizzling = false
            options.enableCaptureFailedRequests = false
            options.enableNetworkTracking = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.enableAutoBreadcrumbTracking = false
            options.enableAutoSessionTracking = true
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.maxBreadcrumbs = 60
            options.beforeSend = { event in scrub(event) }
        }
        SentrySDK.configureScope { scope in
            scope.setUser(User(userId: Failures.installId))
        }
        if let env = Failures.environment { tagScope(with: env) }
        startedAt = Date()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Permissions.log("\(channel): reporting on, sdk started in \(ms) ms, "
            + "release tranquility-base@\(version) dist \(build)")
    }

    /// Tags every event gets, from the snapshot: the facts that decided the
    /// 6 Sep failure, searchable.
    private static func tagScope(with snap: EnvironmentSnapshot) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.configureScope { scope in
            scope.setTag(value: snap.appArch, key: "app.arch")
            scope.setTag(value: snap.appTranslated ? "yes" : "no", key: "app.translated")
            scope.setTag(value: String(snap.sourceCommit?.prefix(7) ?? "?"), key: "app.commit")
            scope.setTag(value: snap.macOS, key: "os.version")
            for h in snap.harnesses {
                scope.setTag(value: h.slices.isEmpty ? "missing" : h.slices.joined(separator: "+"),
                             key: "harness.\(h.id).slices")
                scope.setTag(value: h.version ?? "?", key: "harness.\(h.id).version")
            }
        }
    }

    /// One record, one message event: fingerprinted by kind and site so a
    /// thousand copies of one bug are one issue, tagged so it can be
    /// searched, the whole record attached so nothing is lost in the
    /// flattening.
    private static func forward(_ event: FailureEvent) {
        guard SentrySDK.isEnabled else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try? encoder.encode(event)
        SentrySDK.capture(message: "\(event.kind.rawValue): \(event.reason)") { scope in
            scope.setLevel(.error)
            scope.setFingerprint([event.kind.rawValue, event.site])
            scope.setTag(value: event.kind.rawValue, key: "failure.kind")
            scope.setTag(value: event.site, key: "failure.site")
            if let harness = event.harness { scope.setTag(value: harness, key: "harness") }
            var context: [String: Any] = ["site": event.site, "reason": event.reason]
            if let r = event.reproduction { context["reproduction"] = r }
            if let s = event.session { context["session"] = s }
            scope.setContext(value: context, key: "failure")
            if let json {
                scope.addAttachment(Attachment(data: json, filename: "failure-\(event.id.prefix(8)).json",
                                               contentType: "application/json"))
            }
        }
    }

    /// The same scrub the record gets, applied to what the SDK composed on
    /// its own: crash messages, exception values, its breadcrumbs. Nothing
    /// that names the machine leaves either.
    private static func scrub(_ event: Event) -> Event? {
        if let message = event.message?.formatted {
            event.message = SentryMessage(formatted: Scrub.text(message))
        }
        event.exceptions?.forEach { exception in
            if let value = exception.value { exception.value = Scrub.text(value) }
        }
        event.breadcrumbs?.forEach { crumb in
            if let m = crumb.message { crumb.message = Scrub.text(m) }
        }
        event.serverName = nil
        return event
    }

    /// The published config, fetched with a short timeout and cached. The
    /// SDK starts (or stops) on the main actor when the answer changes.
    private static func fetchRemoteConfig() {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let cache = cacheURL
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let config = try? JSONDecoder().decode(RemoteConfig.self, from: data) else {
                Permissions.log("\(channel): config fetch failed (\(error?.localizedDescription ?? "http")); keeping cached")
                return
            }
            try? data.write(to: cache, options: .atomic)
            let next = (config.enabled ?? true) ? config.sentryDsn : nil
            DispatchQueue.main.async {
                if ProcessInfo.processInfo.environment["TB_SENTRY_DSN"] == nil {
                    let changed = next != dsn
                    dsn = next
                    if changed { Permissions.log("\(channel): config fetched; DSN \(next == nil ? "absent" : "present")") }
                    apply()
                }
            }
        }.resume()
    }
}
