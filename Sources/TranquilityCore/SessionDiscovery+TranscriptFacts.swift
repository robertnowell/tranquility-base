import Foundation

extension SessionDiscovery {
    /// What `scan` needs from one transcript, read once per change instead of
    /// once per tick.
    ///
    /// Measured 29 Sep: with the window at thirty days (#488) the walk read
    /// 1,148 transcripts every `scanTTL` (a 64KB head, a 64KB tail, and a JSON
    /// parse of every line of both). It cost two-thirds of a core for the life
    /// of the process, in bursts to two cores, with RSS swinging 500MB each
    /// pass. Almost none of those files had changed since the last pass.
    ///
    /// Two halves, because they go stale differently:
    /// - The HEAD answers "who started this, and where". A transcript is
    ///   append-only, so the first `entrypoint` and the first `cwd` cannot
    ///   move once found. They are kept for the file's life, and re-read on
    ///   growth only while one of them is still missing.
    /// - The TAIL answers "what happened last". It is re-read whenever the
    ///   file's size or mtime moves, and never otherwise.
    ///
    /// A file that shrank was rewritten, not appended to, and starts over.
    /// `SessionActivity.classify` is deliberately NOT cached: it depends on
    /// `now`, and a working row must still go stale on time.
    final class TranscriptFactsCache: @unchecked Sendable {
        struct Head: Sendable {
            let entrypoint: String?
            let cwd: String?
            var settled: Bool { entrypoint != nil && cwd != nil }
        }
        struct Tail: Sendable {
            let tail: [String]
            /// `firstCwd(head:tail:)`, with the head half filled from `Head`.
            let cwd: String?
            let lastMoved: Date?
            let answered: Bool
        }
        private struct Entry {
            var size: Int
            var modified: Date
            var head: Head
            var tail: Tail?
            var usedAt: Date
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        /// How long an entry outlives its last use. Past this the file has
        /// left every window anyone is scanning, and its tail is dead weight.
        static let idleLimit: TimeInterval = 60 * 60

        func head(path: String, size: Int, modified: Date) -> Head? {
            lock.lock()
            if var entry = entries[path], entry.size <= size,
               entry.size == size || entry.head.settled {
                entry.usedAt = Date()
                if entry.size != size || entry.modified != modified {
                    // Grown or touched: the head stands, the tail does not.
                    entry.size = size; entry.modified = modified; entry.tail = nil
                }
                entries[path] = entry
                lock.unlock()
                return entry.head
            }
            lock.unlock()

            guard let lines = SessionDiscovery.classifiableHead(of: path) else { return nil }
            let head = Head(entrypoint: SessionDiscovery.entrypoint(head: lines),
                            cwd: SessionDiscovery.firstCwd(head: lines))
            lock.lock()
            entries[path] = Entry(size: size, modified: modified, head: head,
                                  tail: nil, usedAt: Date())
            lock.unlock()
            return head
        }

        /// Call after `head` for the same file and stat; that call is what
        /// invalidates a stale tail.
        func tail(path: String, size: Int, modified: Date, head: Head) -> Tail {
            lock.lock()
            if let entry = entries[path], entry.size == size,
               entry.modified == modified, let tail = entry.tail {
                lock.unlock()
                return tail
            }
            lock.unlock()

            let lines = SessionActivity.tail(of: path) ?? []
            let tail = Tail(
                tail: lines,
                cwd: SessionDiscovery.firstCwd(head: [], tail: lines) ?? head.cwd,
                lastMoved: SessionDiscovery.lastMoved(tail: lines),
                answered: SessionDiscovery.isAnswered(tail: lines))
            lock.lock()
            if var entry = entries[path], entry.size == size, entry.modified == modified {
                entry.tail = tail
                entries[path] = entry
            }
            lock.unlock()
            return tail
        }

        func evictIdle(now: Date = Date()) {
            lock.lock(); defer { lock.unlock() }
            entries = entries.filter { now.timeIntervalSince($0.value.usedAt) < Self.idleLimit }
        }
    }

    static let transcriptFacts = TranscriptFactsCache()

    /// The Codex half of the same idea. A rollout is read and parsed whole,
    /// so an unchanged file is the most expensive thing to re-read.
    final class RolloutFactsCache: @unchecked Sendable {
        struct Facts: Sendable {
            let sessionId: String?
            let isSubagent: Bool
            let cwd: String?
            let answered: Bool
        }
        private let lock = NSLock()
        private var entries: [String: (size: Int, modified: Date, facts: Facts, usedAt: Date)] = [:]

        func facts(path: String, size: Int, modified: Date) -> Facts? {
            lock.lock()
            if let hit = entries[path], hit.size == size, hit.modified == modified {
                entries[path]?.usedAt = Date()
                lock.unlock()
                return hit.facts
            }
            lock.unlock()

            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let parsed = autoreleasepool { CodexRollout.parse(text) }
            let facts = Facts(sessionId: parsed.meta?.sessionId,
                              isSubagent: parsed.meta?.isSubagent == true,
                              cwd: parsed.meta?.cwd,
                              answered: parsed.messages.last?.role == "user")
            lock.lock()
            entries[path] = (size, modified, facts, Date())
            entries = entries.filter {
                Date().timeIntervalSince($0.value.usedAt) < TranscriptFactsCache.idleLimit
            }
            lock.unlock()
            return facts
        }
    }

    static let rolloutFacts = RolloutFactsCache()
}
