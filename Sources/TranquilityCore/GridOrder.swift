import Foundation

/// The grid's order, top to bottom, as the panel last drew it: the order
/// agents are read out in.
///
/// Ruled 29 Sep 2026, on a screenshot of the grid with project folders:
/// "the order of the agents speaking should be informed by the actual grid
/// order top to bottom, unread first." Until then ⌃⌥ walked the waiting
/// list newest-first, and the hands-free manager did the same, so once
/// folders arranged the grid the voice skipped around it.
///
/// The panel records the order every time it paints. The announcer reads it
/// from memory; `tbase status` (a separate process, which the hands-free
/// manager asks) reads the copy on disk. Collapsed folders count in their
/// place: a hidden row is still where it lives.
public enum GridOrder {

    public static var url: URL {
        QueueStore.supportDirectory.appendingPathComponent("grid-order.json")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: [String] = []

    /// Record the order the panel just drew. Written to disk only when it
    /// changed, and off the caller's thread: the caller is a repaint.
    public static func record(_ order: [String], to url: URL = GridOrder.url) {
        lock.lock()
        let changed = ids != order
        if changed { ids = order }
        lock.unlock()
        guard changed else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(order) else { return }
            try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
            try? data.write(to: url, options: .atomic)
            PrivateStorage.protect(url)
        }
    }

    /// This process's last recorded order. Empty in any process without a
    /// panel, which leaves every ordering exactly as it was before.
    public static func inMemory() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ids
    }

    /// The app's order, read from disk, for another process.
    public static func load(from url: URL = GridOrder.url) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let order = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return order
    }

    /// Items in grid order, top to bottom. Items the grid does not show keep
    /// their incoming order, after every item it does: a turn that has not
    /// reached the panel yet still gets read, just not ahead of the grid.
    public static func rank<T>(_ items: [T], id: (T) -> String, order: [String]) -> [T] {
        guard !order.isEmpty else { return items }
        let position = Dictionary(order.enumerated().map { ($1, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { a, b in
            switch (position[id(a.element)], position[id(b.element)]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }
}
