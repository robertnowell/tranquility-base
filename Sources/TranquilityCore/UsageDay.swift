import Foundation

/// `app_alive`: once per day, how much the person did with the app.
///
/// Ruled 24 Oct 2026 ("we need to know how our users are using the app").
/// It counts only what a PERSON started, never what the app or an agent did
/// on its own, so a Mac left running with busy agents does not look used.
/// The list is fixed here, as Track event names, and the event carries a
/// count for every one of them, zero included, so a query can sum any of
/// them without knowing which existed on which build.
///
/// It is emitted for a finished day, at the first drain on a later day, so
/// a day's counts are complete when they leave. Counts persist in a small
/// file beside events.jsonl, so a relaunch mid-day does not lose them.
public final class UsageDay: @unchecked Sendable {

    /// Person-initiated events, by the count each feeds.
    public static let actions: [String: String] = [
        "capture_started": "captures",
        "typed_reply": "typed_replies",
        "turn_heard": "turns_heard",
        "go_to_agent": "agents_opened",
        "row_clicked": "agents_opened",
        "agent_launch_requested": "agents_launched",
        "new_agent_compose": "agents_launched",
        "agent_revive_requested": "agents_revived",
        "agent_handoff_requested": "handoffs",
        "door_opened": "doors",
        "placard_clicked": "doors",
        "strip_clicked": "doors",
        "menubar_clicked": "panel_opened",
        "dock_clicked": "panel_opened",
        "past_agents_opened": "past_agents_opened",
        "hub_opened": "hub_opened",
        "files_picked": "files_attached",
        "folder_drag": "files_attached",
        "settings_opened": "settings_opened",
        "setting_changed": "settings_changed",
        "folder_made": "folders_edited",
        "folder_renamed": "folders_edited",
        "folder_deleted": "folders_edited",
    ]
    /// A reply the person sent is a `reply_outcome` whose outcome is `dispatched`.
    public static let counts: [String] = Array(Set(actions.values).union(["replies_sent"])).sorted()

    struct State: Codable { var day: String?; var counts: [String: Int] = [:] }

    public static let shared = UsageDay()
    private let lock = NSLock()
    private var url: URL?
    private var state = State()
    private var dirty = false

    public init(url: URL? = nil) {
        if let url { configure(url: url) }
    }

    public func configure(url: URL) {
        lock.lock(); defer { lock.unlock() }
        self.url = url
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        }
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Called by `Track.record` for every admitted event.
    public func observe(_ name: String, _ properties: [String: TrackValue], at: Date = Date()) {
        let key: String?
        if name == "reply_outcome" {
            key = properties["outcome"] == .token("dispatched") ? "replies_sent" : nil
        } else {
            key = Self.actions[name]
        }
        guard let key else { return }
        lock.lock(); defer { lock.unlock() }
        let today = Self.dayString(at)
        if state.day == nil { state.day = today }
        if state.day == today {
            state.counts[key, default: 0] += 1
        } else {
            // A day rolled over before the drain ran: the new action belongs
            // to today, and the finished day is kept for the drain to send.
            pendingFinished = pendingFinished ?? state
            state = State(day: today, counts: [key: 1])
        }
        dirty = true
    }
    private var pendingFinished: State?

    /// Send a finished day, if one is waiting. Saves the running count either way.
    public func flush(now: Date = Date(), emit: (String, [String: TrackValue]) -> Void) {
        lock.lock()
        let today = Self.dayString(now)
        var finished = pendingFinished
        pendingFinished = nil
        if finished == nil, let day = state.day, day != today {
            finished = state
            state = State(day: today, counts: [:])
            dirty = true
        }
        let snapshot = state
        let shouldSave = dirty || finished != nil
        dirty = false
        let url = self.url
        lock.unlock()
        if let finished, let day = finished.day {
            var props: [String: TrackValue] = ["day": .token(day)]
            var total = 0
            for key in Self.counts {
                let n = finished.counts[key] ?? 0
                props[key] = .int(n); total += n
            }
            props["actions"] = .int(total)
            emit("app_alive", props)
        }
        if shouldSave, let url, let data = try? JSONEncoder().encode(snapshot) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
