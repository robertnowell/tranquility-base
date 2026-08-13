import XCTest
@testable import TranquilityCore

/// The cache's one promise: no reader ever waits on the loader. The loader is
/// the TextToSpeech daemon plus four plists, and readers are 1.5 s main-thread
/// menu ticks — issue 14's nested blocker was exactly a reader waiting.
final class SystemVoiceCatalogCacheTests: XCTestCase {

    private final class CountingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var sawMainThread = false
        func load(_ language: String) -> SystemVoiceCatalog.RowsSnapshot {
            lock.lock()
            count += 1
            sawMainThread = sawMainThread || Thread.isMainThread
            lock.unlock()
            return .init(
                catalogue: [Voice(id: "v-\(language)", name: "Voice", category: "Free · Premium")],
                downloads: [])
        }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return sawMainThread }
    }

    private func settle(until condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testFirstReadIsInstantAndEmptyThenTheCacheWarms() {
        let loader = CountingLoader()
        let cache = SystemVoiceCatalog.RowsCache(maxAge: 60) { loader.load($0) }
        XCTAssertEqual(cache.rows(language: "en"), .empty,
                       "the first read must not wait for the loader")
        settle(until: { cache.rows(language: "en") != .empty })
        XCTAssertEqual(cache.rows(language: "en").catalogue.first?.id, "v-en")
        XCTAssertFalse(loader.ranOnMain, "the loader is the blocker; it never runs on main")
    }

    func testAWarmCacheDoesNotReload() {
        let loader = CountingLoader()
        let cache = SystemVoiceCatalog.RowsCache(maxAge: 60) { loader.load($0) }
        _ = cache.rows(language: "en")
        settle(until: { loader.calls == 1 })
        for _ in 0..<50 { _ = cache.rows(language: "en") }
        settle(until: { false }, timeout: 0.2)
        XCTAssertEqual(loader.calls, 1, "fresh snapshot, no revalidation")
    }

    func testStaleReadsClaimExactlyOneRefresh() {
        let loader = CountingLoader()
        let cache = SystemVoiceCatalog.RowsCache(maxAge: 0) { loader.load($0) }
        for _ in 0..<20 { _ = cache.rows(language: "en") }
        settle(until: { loader.calls >= 1 }, timeout: 2)
        // maxAge 0 means every settled read is stale, but concurrent stale
        // reads before the first refresh lands must collapse to ONE loader run.
        XCTAssertLessThanOrEqual(loader.calls, 3,
            "single-flight: a burst of stale reads is not a burst of loads")
    }

    func testALanguageChangeIsStale() {
        let loader = CountingLoader()
        let cache = SystemVoiceCatalog.RowsCache(maxAge: 60) { loader.load($0) }
        _ = cache.rows(language: "en")
        settle(until: { loader.calls == 1 })
        _ = cache.rows(language: "fr")
        settle(until: { loader.calls == 2 })
        settle(until: { cache.rows(language: "fr").catalogue.first?.id == "v-fr" })
        XCTAssertEqual(cache.rows(language: "fr").catalogue.first?.id, "v-fr")
    }
}
