import Foundation

/// The one bounded subprocess runner.
///
/// Every process this app spawns goes through here with a deadline, because
/// every unbounded spawn in this repo's history eventually starred in an
/// incident: the AppleScript drain deadlock (issue 14), the 55-second
/// send-keys stall the tmux pre-mortem measured, and the unbounded
/// `claude agents --json` probe the 19 Aug audit flagged as R5 — a wedged CLI
/// there blocked whichever thread asked, on every tick, for as long as the
/// wedge lasted. A deadline turns all of those from hangs into loud, traced
/// failures.
///
/// (The AppleScript runner keeps its own bounded async implementation for
/// now: it is on the arc's delete list with the single-transport cut, and
/// polishing code scheduled for deletion is motion, not progress.)
public enum Subprocess {

    /// A Data accumulator safe to fill from a GCD drain thread and read after
    /// the drain group is waited out. The one copy; the twins that used to
    /// live in the AppleScript and Tmux runners collapse here.
    public final class PipeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        public init() {}
        public func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        public var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// Run one process to completion under a deadline. Both pipes drain
    /// concurrently with the wait (a child writing more than the 64KB pipe
    /// buffer otherwise deadlocks against a parent blocked in wait); the
    /// deadline is enforced with SIGKILL, and a killed run reports
    /// `timedOut: true` so callers can distinguish "it failed" from "we
    /// stopped waiting".
    @discardableResult
    public static func run(
        _ executablePath: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval
    ) -> Result<String, ScriptError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.arguments = arguments
        if let environment { p.environment = environment }

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            do { try p.run() } catch { return .failure(ScriptError(message: "\(error)")) }
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        } else {
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return .failure(ScriptError(message: "\(error)")) }
        }

        let stdout = PipeBuffer(), stderr = PipeBuffer()
        let drained = DispatchGroup()
        for (pipe, buf) in [(out, stdout), (err, stderr)] {
            let handle = pipe.fileHandleForReading
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                buf.append(handle.readDataToEndOfFile())
                drained.leave()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(p.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
        drained.wait()
        if timedOut {
            return .failure(ScriptError(
                message: "\((executablePath as NSString).lastPathComponent) "
                    + "\(arguments.first ?? "") killed after \(Int(timeout))s deadline",
                timedOut: true))
        }
        return p.terminationStatus == 0
            ? .success(stdout.text)
            : .failure(ScriptError(message: stderr.text))
    }

    /// `command -v <name>` through a login shell, bounded. The last-resort
    /// binary probe both harness binaries use; a blocking ~/.zprofile used to
    /// hang this forever, silently, on every liveness tick.
    public static func loginShellWhich(_ name: String, timeout: TimeInterval = 5) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard case .success(let out) = run(shell, ["-lic", "command -v \(name)"],
                                           timeout: timeout),
              !out.isEmpty else { return nil }
        return out
    }
}
