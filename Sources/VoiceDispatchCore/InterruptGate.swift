import CoreGraphics
import Foundation

/// Decides whether *now* is an acceptable moment to speak.
///
/// This is a veto, never a trigger. It can only ever delay an announcement; it can
/// never cause one, and a vetoed item stays in the queue. That asymmetry is
/// deliberate and matches what the interruption literature actually supports:
/// deferring to a breakpoint reliably reduces annoyance, while idle time has never
/// been validated as positive evidence that someone is *ready* to be interrupted.
/// Notably, only 10% of programming sessions resume coding within a minute — so a
/// long-idle developer may be deep in reading, and one who just typed may already
/// have checked out. Hence: use it to avoid obviously-bad moments, nothing more.
public struct InterruptGate: Sendable {
    public struct Decision: Sendable, Equatable {
        public let allowed: Bool
        public let reason: String
        public let idleSeconds: Double
        public let frontmostApp: String?
        public let screenLocked: Bool
    }

    /// Typing right now. The one moment that is unambiguously bad.
    public var minimumIdleSeconds: Double
    /// Apps where an interruption is especially unwelcome (calls, presentations).
    public var mutedApps: Set<String>

    public init(
        minimumIdleSeconds: Double = 8,
        mutedApps: Set<String> = ["zoom.us", "Google Meet", "Microsoft Teams", "FaceTime", "Keynote"]
    ) {
        self.minimumIdleSeconds = minimumIdleSeconds
        self.mutedApps = mutedApps
    }

    public func evaluate() -> Decision {
        let idle = Self.idleSeconds()
        let app = Self.frontmostApplication()
        let locked = Self.screenIsLocked()

        if locked {
            return Decision(allowed: false, reason: "screen is locked",
                            idleSeconds: idle, frontmostApp: app, screenLocked: true)
        }
        if let app, mutedApps.contains(app) {
            return Decision(allowed: false, reason: "muted app in front: \(app)",
                            idleSeconds: idle, frontmostApp: app, screenLocked: false)
        }
        if idle < minimumIdleSeconds {
            return Decision(
                allowed: false,
                reason: String(format: "actively typing (idle %.1fs < %.0fs)", idle, minimumIdleSeconds),
                idleSeconds: idle, frontmostApp: app, screenLocked: false)
        }
        return Decision(allowed: true, reason: "no veto", idleSeconds: idle,
                        frontmostApp: app, screenLocked: false)
    }

    // MARK: - Signals

    /// Seconds since the last keyboard or mouse event. `CGEventSource` is the
    /// supported in-process form of the same number `ioreg`'s HIDIdleTime reports.
    public static func idleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    public static func screenIsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Frontmost app name. Uses `lsappinfo`, which needs no Accessibility grant —
    /// unlike System Events, which would prompt.
    public static func frontmostApplication() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "lsappinfo info -only name \"$(lsappinfo front)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        // Output looks like:  "LSDisplayName"="Google Chrome"
        guard let range = out.range(of: "=\"") else { return nil }
        let tail = out[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let name = String(tail[..<end])
        return name.isEmpty ? nil : name
    }
}

/// Records what the gate *would* have decided, without acting on it.
///
/// The plan calls for running log-only for a day before the gate is allowed to
/// suppress anything, because thresholds tuned in the abstract are usually wrong.
public struct GateObservationLog: Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? QueueStore.supportDirectory.appendingPathComponent("gate-observations.jsonl")
    }

    public func record(_ decision: InterruptGate.Decision, context: String) {
        let record: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "allowed": decision.allowed,
            "reason": decision.reason,
            "idleSeconds": decision.idleSeconds,
            "frontmostApp": decision.frontmostApp ?? "",
            "screenLocked": decision.screenLocked,
            "context": context,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}
