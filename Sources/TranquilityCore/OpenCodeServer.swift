import Foundation
import Network

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

    public init(binary: String, directory: String, port: Int? = nil) {
        self.binary = binary
        self.directory = directory
        self.port = port ?? Self.freePort()
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
            try process.run()
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
