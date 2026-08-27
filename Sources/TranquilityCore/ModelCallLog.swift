import Foundation

/// Every model call, recorded whole: the exact system prompt, the exact user
/// content, and the exact response body.
///
/// A summary that reads wrong is otherwise undebuggable — the inputs are
/// assembled from four sources and the output is a black box, so all anyone can
/// do is guess at which part misled it. One JSONL line per call turns that into
/// reading a file.
public enum ModelCallLog {
    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("model-calls.jsonl")
    }

    public static func record(
        model: String, status: Int, elapsedMs: Int,
        system: String, user: String, response: String
    ) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "model": model,
            "status": status,
            "elapsedMs": elapsedMs,
            "system": system,
            "user": user,
            "response": response,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"

        try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}
