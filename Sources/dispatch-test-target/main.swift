import Foundation

// dispatch-test-target — a stand-in for a real Claude Code session.
//
// Launch this in a Terminal.app tab and the entire dispatch leg (tty lookup,
// AppleScript injection, the separate Return, and read-back verification) can be
// exercised without a single Claude session involved. It is safe to hammer, and it
// cannot type into anything that matters.
//
// It mimics the two things the dispatcher depends on: a raw-mode tty (see below)
// and a transcript of one JSON object per line with `type: "user"`.

/// Puts stdin into raw mode, exactly as Claude Code's TUI does.
///
/// This is not cosmetic. In canonical mode the tty line discipline silently discards
/// everything past MAX_CANON (1024 bytes on macOS), so a `readLine`-based harness
/// truncates a long reply mid-sentence with no error — and would make this harness
/// lie about what a real dispatch can carry. Raw mode has no such limit, which is why
/// 1687 characters land fine in an actual Claude Code session.
final class RawTerminal {
    private var original = termios()
    private let isTTY = isatty(STDIN_FILENO) == 1

    init() {
        guard isTTY else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    func restore() {
        guard isTTY else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }
}

func appendToTranscript(_ text: String, sessionId: String, path: String) {
    let record: [String: Any] = [
        "type": "user",
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "sessionId": sessionId,
        "message": ["role": "user", "content": text],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: record),
          var line = String(data: data, encoding: .utf8)
    else { return }
    line += "\n"
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

func runInputLoop(sessionId: String, transcriptPath: String) {
    let terminal = RawTerminal()
    var buffer = [UInt8]()
    var byte: UInt8 = 0

    while read(STDIN_FILENO, &byte, 1) == 1 {
        switch byte {
        case 0x03:  // Ctrl-C — raw mode suppresses signal generation, so handle it here.
            terminal.restore()
            print("\r\nbye")
            exit(0)
        case 0x0d, 0x0a:  // Enter arrives as CR in raw mode.
            let text = String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll(keepingCapacity: true)
            if text.isEmpty {
                // A bare Return with nothing buffered — what the submit step sends
                // once the text has already arrived as its own AppleEvent.
                print("  [bare return]\r")
            } else {
                appendToTranscript(text, sessionId: sessionId, path: transcriptPath)
                print("  [recorded \(text.count) chars] \(text.prefix(60))\r")
            }
        default:
            buffer.append(byte)
        }
    }
    terminal.restore()
}

// MARK: - Entry

let home = FileManager.default.homeDirectoryForCurrentUser
let dir = home.appendingPathComponent(
    "Library/Application Support/VoiceDispatch/test-targets", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let sessionId = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "test-\(ProcessInfo.processInfo.processIdentifier)"
let transcript = dir.appendingPathComponent("\(sessionId).jsonl")

// Fresh transcript per run, so stale lines can't produce a false confirmation.
try? FileManager.default.removeItem(at: transcript)
FileManager.default.createFile(atPath: transcript.path, contents: Data())

print("dispatch-test-target ready")
print("pid=\(ProcessInfo.processInfo.processIdentifier)")
print("sessionId=\(sessionId)")
print("transcript=\(transcript.path)")
print("---- raw mode; waiting for injected text (Ctrl-C to stop) ----")

runInputLoop(sessionId: sessionId, transcriptPath: transcript.path)
