import Foundation

/// An ACP agent running as a child process, spoken to over its stdin/stdout.
///
/// ACP ships stdio only, so owning a process is not an alternative to the
/// provider seam, it is this provider's transport. That distinction is the
/// whole reason `ACPProvider` is an `AgentProvider` and not a `HarnessAdapter`:
/// a harness owns a TERMINAL and reads a screen, while this owns a PIPE and
/// reads a protocol. Ruled 14 Sep, and the reason OpenCode was never allowed to
/// become a keystroke-scraped terminal.
public final class ACPProcessTransport: ACPTransport, @unchecked Sendable {

    private let process = Process()
    private let toAgent = Pipe()
    private let fromAgent = Pipe()
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var buffer = Data()

    /// Guards against an agent that never emits a newline. 1 MiB is far beyond
    /// any real ACP message and far below a leak that matters.
    private static let maxLine = 1 << 20

    public init(command: [String], cwd: String, environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = toAgent
        process.standardOutput = fromAgent
        // stderr is DISCARDED, not merged. An agent's diagnostics on the same
        // pipe as its protocol would be lines the parser has to survive, and
        // "survive a banner" is a weaker guarantee than "never see one".
        process.standardError = FileHandle.nullDevice
        if let environment { process.environment = environment }
    }

    public func start() throws {
        try process.run()
    }

    /// The child's exit status once it has ended; nil while it runs.
    public var exitStatus: Int32? {
        process.isRunning ? nil : process.terminationStatus
    }

    public func write(_ line: Data) async throws {
        var out = line
        out.append(0x0A)
        try toAgent.fileHandleForWriting.write(contentsOf: out)
    }

    /// Hand-rolled line splitting over the raw handle, for the reason recorded
    /// on 14 Sep against a live SSE stream: `AsyncBytes.lines` yielded nothing
    /// at all there, with no error, while raw bytes delivered immediately. The
    /// same class of silence on a pipe would read as an agent with nothing to
    /// say, which is a state an idle agent legitimately has.
    public func lines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            fromAgent.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    continuation.finish()
                    handle.readabilityHandler = nil
                    return
                }
                self.lock.lock()
                self.buffer.append(chunk)
                var lines: [Data] = []
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<newline]
                    self.buffer = self.buffer[self.buffer.index(after: newline)...]
                    if !line.isEmpty { lines.append(Data(line)) }
                }
                if self.buffer.count > Self.maxLine { self.buffer.removeAll(keepingCapacity: false) }
                self.lock.unlock()
                for line in lines { continuation.yield(line) }
            }

            continuation.onTermination = { [weak self] _ in
                self?.fromAgent.fileHandleForReading.readabilityHandler = nil
            }
        }
    }

    public func close() async {
        fromAgent.fileHandleForReading.readabilityHandler = nil
        continuation?.finish()
        try? toAgent.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
