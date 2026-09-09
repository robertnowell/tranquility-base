import Foundation

/// One record per user-facing failure, built from allow-listed facts.
///
/// Ruled 6 Sep 2026, from the Codex launch that died three times in a
/// minute: every fact that explained it lived on the machine at that moment
/// (the app's own architecture, the harness binary's slices, the pane's
/// PATH, the pane's last line) and none of it was in the message. The card
/// said "a missing tmux binary is the usual suspect" over a pane tmux had
/// just created. The bar this type sets is not "record the error" but
/// "record the environment the error depended on", so that what went wrong,
/// why, and how to reproduce it are one artefact: the card, the local
/// record, and (once wired) the alert.
///
/// Never in here: transcripts, dictated text, what an agent said, model
/// prompts or replies, file contents. `app.log` records dictated text when
/// the Apple engine runs (README), which is exactly why failures get their
/// own file and why breadcrumbs are allow-listed by prefix rather than
/// copied. Paths are scrubbed of the username before the record exists.
public struct FailureEvent: Codable, Equatable, Sendable {
    public var id: String
    public var at: Date
    public var kind: FailureKind
    /// What the failing thing said, scrubbed. The pane's last line, the
    /// provider's error, the transport's verdict.
    public var reason: String
    /// `file:line` of the reporting site. Stable across builds in a way the
    /// reason text is not (labels and directories vary), so this is what a
    /// grouping key is built from.
    public var site: String
    /// A line a human can paste into a terminal to see the failure themselves.
    public var reproduction: String?
    /// Which harness, when the failure is about one.
    public var harness: String?
    /// First eight characters of the session id, when the failure is about one.
    public var session: String?
    public var installId: String
    public var environment: EnvironmentSnapshot?
    public var breadcrumbs: [Breadcrumb]
    public var captureId: String? = nil

    public init(id: String = UUID().uuidString.lowercased(), at: Date = Date(),
                kind: FailureKind, reason: String, site: String,
                reproduction: String? = nil, harness: String? = nil, session: String? = nil,
                installId: String, environment: EnvironmentSnapshot?, breadcrumbs: [Breadcrumb]) {
        self.id = id; self.at = at; self.kind = kind; self.reason = reason; self.site = site
        self.reproduction = reproduction; self.harness = harness; self.session = session
        self.installId = installId; self.environment = environment; self.breadcrumbs = breadcrumbs
    }
}

/// The kinds a failure card can be. `notice` is the catch-all: every card
/// the panel shows becomes at least a notice, so no user-facing failure can
/// go unrecorded; the named kinds are the sites that know more.
public enum FailureKind: String, Codable, CaseIterable, Sendable {
    case launchFailed = "launch_failed"
    case launchNeverRegistered = "launch_never_registered"
    case transcriptionProvider = "transcription_provider"
    case deliveryFailed = "delivery_failed"
    case microphone = "microphone"
    case permissions = "permissions"
    case panelLostTrack = "panel_lost_track"
    case notice = "notice"
}

public struct Breadcrumb: Codable, Equatable, Sendable {
    public var at: Date
    public var category: String
    public var message: String
    public init(at: Date = Date(), category: String, message: String) {
        self.at = at; self.category = category; self.message = message
    }
}

/// The facts a failure depended on, captured once at startup off the main
/// thread and refreshed after a launch failure. Cheap to read, never probed
/// on the reporting path.
public struct EnvironmentSnapshot: Codable, Equatable, Sendable {
    public var appVersion: String
    public var appBuild: String
    public var sourceCommit: String?
    /// The slice this process is running, which for a universal app is a
    /// fact about how it was launched, not about the Mac.
    public var appArch: String
    /// Rosetta. True means every plain subprocess inherits translation.
    public var appTranslated: Bool
    public var macOS: String
    public var harnesses: [HarnessFact]
    public var tmuxPath: String?
    public var tmuxVersion: String?
    /// Permission states by name, as the app derives them.
    public var permissions: [String: String]
    public var takenAt: Date

    public init(appVersion: String, appBuild: String, sourceCommit: String?,
                appArch: String, appTranslated: Bool, macOS: String,
                harnesses: [HarnessFact], tmuxPath: String?, tmuxVersion: String?,
                permissions: [String: String], takenAt: Date = Date()) {
        self.appVersion = appVersion; self.appBuild = appBuild; self.sourceCommit = sourceCommit
        self.appArch = appArch; self.appTranslated = appTranslated; self.macOS = macOS
        self.harnesses = harnesses; self.tmuxPath = tmuxPath; self.tmuxVersion = tmuxVersion
        self.permissions = permissions; self.takenAt = takenAt
    }
}

/// One harness as the app can see it: where its binary resolved on the
/// pane's PATH, which architectures that binary carries, and what it says
/// its version is. The 6 Sep failure was `slices: ["x86_64"]` under an app
/// whose `appArch` was `arm64`; with these two fields in the record the
/// cause reads off the alert.
public struct HarnessFact: Codable, Equatable, Sendable {
    public var id: String
    public var path: String?
    public var slices: [String]
    public var version: String?
    public var panePath: String
    public init(id: String, path: String?, slices: [String], version: String?, panePath: String) {
        self.id = id; self.path = path; self.slices = slices; self.version = version
        self.panePath = panePath
    }
}

// MARK: - Scrubbing

/// What leaves the record before it is written, not after. A record that
/// exists unscrubbed on disk for a moment is a record that can be copied
/// unscrubbed.
public enum Scrub {
    /// The home directory becomes `~`; emails, API keys and long opaque
    /// tokens become placeholders. Deliberately not clever: an over-eager
    /// pattern that ate a tmux session name would remove the one fact the
    /// record is for, so only shapes that are unmistakably secrets or
    /// identities are replaced.
    public static func text(_ s: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var out = s
        if !home.isEmpty, home != "/" {
            // The /private spelling first (what `tmux` and `realpath` report
            // on macOS), or the plain replacement leaves "/private~" behind.
            out = out.replacingOccurrences(of: "/private" + home, with: "~")
            out = out.replacingOccurrences(of: home, with: "~")
        }
        out = replace(out, pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "[email]")
        // sk-…, sk-ant-…, xoxb-…, ghp_…, AKIA…, and the like: a recognisable
        // prefix followed by a long run of token characters.
        out = replace(out, pattern: #"\b(sk-[A-Za-z0-9_-]{8,}|xox[abpr]-[A-Za-z0-9-]{8,}|ghp_[A-Za-z0-9]{8,}|AKIA[A-Z0-9]{12,})"#, with: "[key]")
        // Bearer tokens in headers or command lines.
        out = replace(out, pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{16,}"#, with: "$1[token]")
        return out
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}

// MARK: - Breadcrumbs

/// The last few things the app said about itself before a failure, kept in
/// a ring, fed by the app's own log line and filtered by prefix.
///
/// Allow-listed, never copied: `app.log` carries dictated text on some
/// lines, so a breadcrumb is admitted only when its category is one the app
/// writes about its own machinery. Anything else, including a category that
/// does not exist yet, stays out until somebody adds it here on purpose.
public final class Breadcrumbs: @unchecked Sendable {
    public static let shared = Breadcrumbs()

    /// Categories are the prefix before the first colon of a log line.
    public static let allowedCategories: Set<String> = [
        "launcher", "routing", "liveness", "state", "mic", "queue", "transfer",
        "launch", "send", "capture", "arm", "ack", "terminate", "revive", "goTo",
        "startup", "hooks", "11labs", "assemblyai", "stream", "chain", "prewarm",
        "selftest", "drop", "permissions", "secrets", "env", "failure", "announce",
        "grid harness", "breadcrumb", "dismissed", "invitation", "homebase",
    ]
    /// A line that mentions these is about content even under an allowed
    /// category. Belt and braces; the categories above should not produce
    /// them, and if one day one does, it is still refused.
    static let refusedFragments = ["text:", "transcript", "dispatched(", "queued(", "said:", "Its screen says"]

    public static let capacity = 40
    /// Sees each admitted crumb, on the recording thread. The app hands
    /// them to the crash reporter so a crash carries the same trail a
    /// record does.
    nonisolated(unsafe) public var onRecord: (@Sendable (Breadcrumb) -> Void)?
    private let lock = NSLock()
    private var ring: [Breadcrumb] = []
    private let capacity: Int

    public init(capacity: Int = Breadcrumbs.capacity) { self.capacity = capacity }

    /// Admit a raw log line if its category is allowed. Returns whether it was.
    @discardableResult
    public func record(_ line: String, at: Date = Date()) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let category = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard Self.allowedCategories.contains(category) else { return false }
        if category == "secrets", line.contains(" -> keys ") { return false }
        for fragment in Self.refusedFragments where line.contains(fragment) { return false }
        var message = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if message.count > 240 { message = String(message.prefix(240)) + "…" }
        let crumb = Breadcrumb(at: at, category: category, message: Scrub.text(message))
        lock.lock()
        ring.append(crumb)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        lock.unlock()
        onRecord?(crumb)
        return true
    }

    public var recent: [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        ring.removeAll()
    }
}

// MARK: - Mach-O slices

/// Which architectures a binary on disk carries, read from its header. The
/// question `file(1)` answers, without a subprocess: sixteen bytes for a
/// thin binary, the fat header for a universal one.
public enum MachOSlices {
    public static func of(path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return [] }
        return parse(head)
    }

    /// Exposed for tests: the parser over the first bytes of a file.
    public static func parse(_ head: Data) -> [String] {
        let bytes = [UInt8](head)
        guard bytes.count >= 8 else { return [] }
        func be32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        func le32(_ i: Int) -> UInt32 {
            UInt32(bytes[i + 3]) << 24 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i])
        }
        let magic = be32(0)
        // FAT_MAGIC / FAT_MAGIC_64, big-endian on disk.
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF {
            let n = Int(be32(4))
            let entry = magic == 0xCAFEBABE ? 20 : 32
            var out: [String] = []
            for i in 0..<min(n, 8) {
                let off = 8 + i * entry
                guard off + 4 <= bytes.count else { break }
                out.append(name(cputype: be32(off)))
            }
            return out
        }
        // MH_MAGIC_64 / MH_MAGIC, little-endian on disk for every Mac Apple ships.
        if le32(0) == 0xFEEDFACF || le32(0) == 0xFEEDFACE {
            return [name(cputype: le32(4))]
        }
        return []
    }

    static func name(cputype: UInt32) -> String {
        switch cputype {
        case 0x0100000C: return "arm64"
        case 0x01000007: return "x86_64"
        case 0x0000000C: return "arm"
        case 0x00000007: return "i386"
        default: return String(format: "cputype_0x%08x", cputype)
        }
    }
}

// MARK: - Probe

/// Fills an `EnvironmentSnapshot`. Runs subprocesses (`--version`), so it
/// is called off the main thread, once at startup and again after a launch
/// failure, and never on the reporting path.
public enum EnvironmentProbe {
    public static func snapshot(appVersion: String, appBuild: String, sourceCommit: String?,
                                permissions: [String: String],
                                adapters: [any HarnessAdapter] = KnownHarnesses.all,
                                tmuxPath: String? = nil) -> EnvironmentSnapshot {
        let harnesses = adapters.map { adapter -> HarnessFact in
            let dirs = adapter.pathCandidates
            let path = dirs.map { $0 + "/" + adapter.processCommandFragment }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            let resolved = path.flatMap { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) }
                .map { $0.hasPrefix("/") ? $0 : (path! as NSString).deletingLastPathComponent + "/" + $0 }
            let slices = (resolved ?? path).map { MachOSlices.of(path: $0) } ?? []
            var version: String?
            if let path, case .success(let out) = Subprocess.run(path, ["--version"], timeout: 4) {
                version = out.split(separator: "\n").first.map(String.init)
            }
            return HarnessFact(id: adapter.id, path: path.map { Scrub.text($0) }, slices: slices,
                               version: version, panePath: Scrub.text(dirs.joined(separator: ":")))
        }
        var tmuxVersion: String?
        if let tmuxPath, case .success(let out) = Subprocess.run(tmuxPath, ["-V"], timeout: 3) {
            tmuxVersion = out
        }
        return EnvironmentSnapshot(
            appVersion: appVersion, appBuild: appBuild, sourceCommit: sourceCommit,
            appArch: currentArch, appTranslated: isTranslated,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            harnesses: harnesses, tmuxPath: tmuxPath, tmuxVersion: tmuxVersion,
            permissions: permissions)
    }

    /// The slice this process runs. Compile-time is exactly right here: each
    /// slice of a universal binary is its own compilation.
    public static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Rosetta, asked of the kernel. Only ever true for the x86_64 slice on
    /// Apple silicon; false on an Intel Mac and for a native process.
    public static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}

// MARK: - Store and funnel

/// Appends records to `failures.jsonl` beside the app's other private files.
/// Serial queue, `0600`, rolls at a fixed size. Never on the caller's thread.
public final class FailureStore: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "base.tranquility.failures", qos: .utility)
    private let limit: Int

    public init(url: URL, limit: Int = 8 * 1024 * 1024) {
        self.url = url; self.limit = limit
    }

    public func append(_ event: FailureEvent) {
        queue.async { [self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(event) else { return }
            line.append(0x0A)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { return }
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            let size = lseek(fd, 0, SEEK_CUR)
            close(fd)
            if size > limit {
                let rolled = url.deletingPathExtension().appendingPathExtension("jsonl.1")
                try? FileManager.default.removeItem(at: rolled)
                try? FileManager.default.moveItem(at: url, to: rolled)
            }
        }
    }

    /// Block until everything queued is on disk. For tests and for the
    /// termination path.
    public func flush() { queue.sync {} }
}

/// The one door. Every failure the panel shows passes through here; the
/// named sites add what they know, the panel's own receipt adds the rest.
public enum Failures {
    /// Where records go once wired to a service. Only `attach` writes it
    /// (and `detach` clears it); nil means local only. Called off the
    /// caller's thread. Same rule as `Track.sink`, for the same reason: a
    /// drill that captures this, swaps it and puts it back is racing
    /// whoever attaches the real one.
    nonisolated(unsafe) public private(set) static var sink: (@Sendable (FailureEvent) -> Void)?
    nonisolated(unsafe) public static var trace: (@Sendable (String) -> Void)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _environment: EnvironmentSnapshot?
    nonisolated(unsafe) private static var _store: FailureStore?
    nonisolated(unsafe) private static var _installId: String?
    nonisolated(unsafe) private static var _installIdMinted = false
    nonisolated(unsafe) private static var _suppressed = false
    nonisolated(unsafe) private static var lastReported: (card: String, at: Date)?
    nonisolated(unsafe) private static var _reportedCount = 0
    nonisolated(unsafe) private static var _suppressedCount = 0
    private static let queue = DispatchQueue(label: "base.tranquility.failures.report", qos: .utility)

    public static var environment: EnvironmentSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return _environment }
        set { lock.lock(); _environment = newValue; lock.unlock() }
    }

    /// Point the funnel at a directory. Idempotent; the app calls it once.
    public static func configure(directory: URL) {
        lock.lock(); defer { lock.unlock() }
        _store = FailureStore(url: directory.appendingPathComponent("failures.jsonl"))
        let (id, minted) = loadOrMintInstallId(directory: directory)
        _installId = id
        _installIdMinted = minted
    }

    /// True on the run that minted this install's id: the first launch of a
    /// fresh install, or the first after a reset. `app_launched` carries it,
    /// so a new install can announce itself.
    public static var installIdWasMinted: Bool { lock.lock(); defer { lock.unlock() }; return _installIdMinted }

    public static var storeURL: URL? { lock.lock(); defer { lock.unlock() }; return _store?.url }

    /// A random id for this install, minted once and kept in a file. Not the
    /// hostname, not the username, not tied to anything else. Resettable by
    /// deleting the file.
    public static var installId: String {
        lock.lock(); defer { lock.unlock() }
        return _installId ?? "unconfigured"
    }

    /// While true, nothing is written or forwarded. The self-test slate turns
    /// this on: a drill that paints "Couldn't open the microphone" on purpose
    /// must not become a record that says the microphone failed.
    public static var suppressed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _suppressed }
        set { lock.lock(); _suppressed = newValue; lock.unlock() }
    }

    /// How many reports were accepted (including while suppressed). For drills.
    public static var reportedCount: Int { lock.lock(); defer { lock.unlock() }; return _reportedCount }
    /// How many of those were dropped because `suppressed` was on.
    public static var suppressedCount: Int { lock.lock(); defer { lock.unlock() }; return _suppressedCount }

    public static func attach(sink newSink: @escaping @Sendable (FailureEvent) -> Void) {
        lock.lock(); sink = newSink; lock.unlock()
    }

    public static func detach() { lock.lock(); sink = nil; lock.unlock() }

    public static var hasSink: Bool { lock.lock(); defer { lock.unlock() }; return sink != nil }

    /// A site that knows what happened. Cheap on the caller's thread: it
    /// snapshots the breadcrumbs and enqueues; everything else is off-thread.
    ///
    /// `card` is the text the site is about to paint on the panel, when it
    /// differs from `reason`. The panel's own receipt (`notice`) sees every
    /// card, and this is how it knows one was already recorded with more
    /// context than it has.
    public static func report(_ kind: FailureKind, reason: String, card: String? = nil,
                              reproduction: String? = nil, harness: String? = nil,
                              session: String? = nil,
                              file: StaticString = #fileID, line: UInt = #line) {
        let site = "\(file):\(line)"
        let crumbs = Breadcrumbs.shared.recent
        let captureId = Track.captureID.map { Track.hash($0).tokenString }
        let now = Date()
        lock.lock()
        lastReported = (card ?? reason, now)
        _reportedCount += 1
        let suppressed = _suppressed
        let installId = _installId ?? "unconfigured"
        let environment = _environment
        let store = _store
        if suppressed { _suppressedCount += 1 }
        lock.unlock()
        guard !suppressed else { return }
        // The product stream sees the same failure as a fact: kind, site,
        // harness. Enough to join failures to gestures and to retention;
        // nothing of the reason text.
        var mirror: [String: TrackValue] = ["kind": .token(kind.rawValue), "site": Track.token(from: site)]
        if let harness { mirror["harness"] = .token(harness) }
        if let session { mirror["agent_id"] = Track.hash(session) }
        Track.record("failure", mirror)
        queue.async {
            var event = FailureEvent(
                at: now, kind: kind, reason: Scrub.text(reason), site: site,
                reproduction: reproduction.map { Scrub.text($0) }, harness: harness,
                session: session.map { String($0.prefix(8)) },
                installId: installId, environment: environment, breadcrumbs: crumbs)
            event.captureId = captureId
            store?.append(event)
            trace?("\(kind.rawValue) at \(site): \(event.reason.prefix(120))")
            sink?(event)
        }
    }

    /// The panel's receipt. Every card becomes a record; a card whose site
    /// already reported it (same card text, within two seconds) is not
    /// recorded twice.
    public static func notice(_ message: String, session: String? = nil,
                              file: StaticString = #fileID, line: UInt = #line) {
        lock.lock()
        let duplicate = lastReported.map { $0.card == message && Date().timeIntervalSince($0.at) < 2 } ?? false
        lock.unlock()
        if duplicate { return }
        report(.notice, reason: message, session: session, file: file, line: line)
    }

    /// Block until queued reports are written. Tests and termination.
    public static func flush() {
        queue.sync {}
        lock.lock(); let store = _store; lock.unlock()
        store?.flush()
    }

    /// Forget this install's id and mint another. The user's door out of
    /// any history the id has accrued. Returns the new id.
    @discardableResult
    public static func resetInstallId() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let store = _store else { return "unconfigured" }
        let directory = store.url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("install-id"))
        let (fresh, _) = loadOrMintInstallId(directory: directory)
        _installId = fresh
        _installIdMinted = true
        return fresh
    }

    private static func loadOrMintInstallId(directory: URL) -> (id: String, minted: Bool) {
        let url = directory.appendingPathComponent("install-id")
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return (existing, false)
        }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fresh.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return (fresh, true)
    }

    /// Tests only: forget the configured store and id.
    public static func resetForTesting() {
        lock.lock(); defer { lock.unlock()
        _suppressedCount = 0; sink = nil
    }
        _store = nil; _installId = nil; _environment = nil; _suppressed = false
        lastReported = nil; _reportedCount = 0
    }
}
