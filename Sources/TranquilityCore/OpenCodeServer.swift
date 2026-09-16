import Foundation
import os

/// An `opencode serve` this app owns: one headless server in the workspace,
/// on a port of its own, driven over HTTP and shared with the terminal.
///
/// **Why a server and not the pipe.** Over `opencode acp` a permission lives
/// in the child that asked it, and `opencode --session X` in a Terminal is a
/// second OpenCode on the same stored session that never hears the question.
/// Robert, 15 Sep 9:11 PM: "Amber goes to agent. When you go to agent, it
/// should work to answer the question." A served session is shared: a
/// terminal attached with `opencode attach <url> --session X` shows the
/// permission the app's prompt raised, the answer given there clears it for
/// the app, and the reverse. Verified against 1.18.31 on 15 Sep: asked over
/// HTTP, shown in the attached terminal, answered with Enter, pending 0, the
/// turn finished.
public final class OpenCodeServer: @unchecked Sendable {
    public let binary: String
    public let directory: String
    public let port: Int
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private let process = Process()
    private let lock = NSLock()
    private var started = false

    /// Where this server's pid is remembered across launches, so the next
    /// app instance can reap a server the previous one left behind. A child
    /// process does not die with its parent on macOS: the first deploy after
    /// this route shipped left an `opencode serve` running on a port nobody
    /// used (found 16 Sep, pid 70757 from an app gone eleven hours).
    public var pidFile: URL?

    public init(binary: String, directory: String, port: Int? = nil, pidFile: URL? = nil) {
        self.binary = binary
        self.directory = directory
        self.port = port ?? Self.freePort()
        self.pidFile = pidFile
    }

    /// End a server a previous instance recorded, if it is still an
    /// `opencode serve` of ours. Never a pid that has been recycled into
    /// something else: the command line is checked first.
    public static func reapStale(pidFile: URL, binary: String) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe(); probe.standardOutput = out; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        let command = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if command.contains(binary), command.contains(" serve ") || command.hasSuffix("serve") || command.contains("serve --port") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// The terminal's way onto one of this server's sessions.
    public func attachCommand(session raw: String) -> String {
        [binary, "attach", baseURL.absoluteString, "--session", raw]
            .map(SessionLauncher.shellQuoted).joined(separator: " ")
    }

    /// Spawn and wait until `GET /session` answers. Idempotent.
    public func start(timeout: TimeInterval = 20) async throws {
        let already = lock.withLock { () -> Bool in
            if started { return true }
            started = true
            return false
        }
        if !already {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["serve", "--port", String(port), "--hostname", "127.0.0.1"]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if let pidFile { Self.reapStale(pidFile: pidFile, binary: binary) }
            try process.run()
            if let pidFile {
                try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
            }
            // And with THIS instance: `stopAll()` from the app's own exit
            // path ends it on a normal quit; a crash leaves it for the reap
            // above at the next launch.
            Self.registry.withLock { $0.append(self) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var request = URLRequest(url: baseURL.appendingPathComponent("session"))
        request.timeoutInterval = 2
        while Date() < deadline {
            if !process.isRunning {
                throw ServerError.exited(process.terminationStatus)
            }
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw ServerError.notReady(port)
    }

    public var isRunning: Bool { process.isRunning }

    private static let registry = OSAllocatedUnfairLock<[OpenCodeServer]>(initialState: [])

    /// Every server this process started: for the app's exit path.
    public static func stopAll() {
        let servers = registry.withLock { list -> [OpenCodeServer] in defer { list.removeAll() }; return list }
        for server in servers { server.stop() }
    }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    public enum ServerError: Error, CustomStringConvertible {
        case exited(Int32)
        case notReady(Int)
        public var description: String {
            switch self {
            case .exited(let code): return "opencode serve exited with status \(code)"
            case .notReady(let port): return "opencode serve did not answer on port \(port)"
            }
        }
    }

    /// A port nobody is listening on right now: bind 0, read what the
    /// kernel picked, release it. The gap before `opencode serve` binds it is
    /// small and a collision is a spawn failure the caller sees, not a silent
    /// wrong server.
    static func freePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) }
        }
        guard bound == 0 else { return 41_000 + Int.random(in: 0..<1000) }
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(sock, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
