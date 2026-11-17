import AppKit
import TranquilityCore

/// The graveyard: everything this machine has run lately, and one click to
/// bring any of it back.
///
/// It exists because the grid answers the wrong question for this job. The grid
/// is an instrument for NOW — who wants you, who is working, who stopped — and
/// it is deliberately small. Robert, 12 Aug: "there is a workstream that I did a
/// week ago, and I don't know which terminal tab it's in, and I don't know which
/// Claude session it's in… the only way I could possibly do it is go hunting
/// through my 60 open terminal tabs." That is a SEARCH, and a search wants a
/// list you scroll, not a panel you read.
///
/// **Built on open, never repainted while you read it.** This is the one face
/// that scrolls, and it is only safe to scroll because of that rule: the grid
/// rebuilds its rows from scratch on every content change, and doing that under
/// a scroll offset would throw the reader back to the top whenever any lamp
/// anywhere changed colour. Anyone adding a live refresh here re-creates that
/// bug — see `apply(rows:)`, which is called once per opening.
final class PastAgentsList: NSView {

    /// One row per session, in the grid's own shape: the same lamp column, the
    /// same name, the same short id. Nothing here has to be learned twice, and
    /// a session looks the same wherever you meet it.
    struct Item: Equatable, Sendable {
        let row: SessionRow
        /// What a click does. Dead sessions come back; live ones get focus.
        let revivable: Bool
        /// Short identity and directory text for the keyword index.
        let haystack: String
        /// What THIS list's right column says, when it is not what the grid's
        /// says. The grid answers "which one is this" and shows the short id;
        /// this list answers "when did I last touch it" and shows the time
        /// (ruled 19 Aug). Two faces, two questions, and the row is not
        /// rewritten to serve one of them — the list carries its own column and
        /// the grid is untouched.
        ///
        /// Nil falls back to `row.aux`, which is what the drills want: a fixture
        /// that says nothing about time keeps the shape it always had.
        let aux: String?
        /// What the pointer says, when it is not what `hoverText` would say.
        /// The id displaced from the column lands here, so nothing is lost by
        /// the swap above — see `openPastAgents`, which is the one place that
        /// knows both halves.
        let tooltip: String?
        /// The project folder it was filed in on the grid, drawn as a chip.
        /// The list stays flat (ruling-project-folders, rule 8); the chip only
        /// says where it came from, and where a revive will put it back.
        let folder: String?
        /// Why this row answered the search: the passage that matched. Nil
        /// when nothing is being searched for.
        let match: MatchLine?

        init(row: SessionRow, revivable: Bool, haystack: String,
             aux: String? = nil, tooltip: String? = nil, folder: String? = nil,
             match: MatchLine? = nil) {
            self.row = row
            self.revivable = revivable
            self.haystack = haystack
            self.aux = aux
            self.tooltip = tooltip
            self.folder = folder
            self.match = match
        }
    }

    /// The reason a result is in the list, shown ON the row.
    ///
    /// It lived in the tooltip until 15 Nov 2026, with no highlight, and it
    /// could be a session id or a path. Robert: *"I want to be able to see why
    /// each is ranking, because often the title alone is not a good
    /// description of the relevant context that has been matched."*
    struct MatchLine: Equatable, Sendable {
        /// Who said it: YOU, AGENT, REPORT, SUMMARY. Empty for a name match.
        let speaker: String
        /// The passage, with `SessionKeywordIndex.Match.open` and `.close`
        /// around each matched word.
        let excerpt: String
        /// Matching passages beyond the one shown.
        let more: Int

        init(_ match: SessionKeywordIndex.Match) {
            switch match.role {
            case .user: speaker = "YOU"
            case .assistant: speaker = "AGENT"
            case .report: speaker = "REPORT"
            case .summary: speaker = "SUMMARY"
            case .title, .metadata: speaker = ""
            }
            excerpt = match.excerpt.isEmpty
                ? (match.tier <= 1 ? "The name matches." : "The folder, directory or id matches.")
                : match.excerpt
            more = max(0, match.count - 1)
        }
        init(speaker: String, excerpt: String, more: Int = 0) {
            self.speaker = speaker; self.excerpt = excerpt; self.more = more
        }

        var plain: String {
            excerpt.filter { $0 != SessionKeywordIndex.Match.open && $0 != SessionKeywordIndex.Match.close }
        }
    }

    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private let filterField = FilterRowView()
    private var items: [Item] = []
    private var shown: [Item] = []
    /// Everything a search may answer with: the list's own rows, the agents
    /// the grid is showing, and agents older than the list's 30 days. The
    /// list with no search text shows `items` alone (ruled 15 Nov 2026).
    private var searchable: [Item] = []
    /// The words, the order, and whether every result needs its passage or
    /// only the first page of them.
    typealias Search = @Sendable (String, SessionKeywordIndex.Order, _ everyExcerpt: Bool) async throws
        -> [SessionKeywordIndex.Match]
    private var search: Search?
    /// Newest first, or best match first. Remembered between launches.
    private(set) var order: SessionKeywordIndex.Order = PastAgentsList.storedOrder {
        didSet { ProductDefaults.shared.set(order.rawValue, forKey: Self.orderKey) }
    }
    static let orderKey = "pastAgentsSearchOrder"
    /// Recent unless the user chose otherwise (ruled 15 Nov 2026).
    static var storedOrder: SessionKeywordIndex.Order {
        ProductDefaults.shared.string(forKey: orderKey)
            .flatMap(SessionKeywordIndex.Order.init(rawValue:)) ?? .recent
    }
    /// How many results a search draws before it is asked for the rest. Every
    /// row is a view, and a common word matches hundreds of agents.
    nonisolated static let resultPage = 50
    /// The most agents one search asks the index for. Past this the summary
    /// says "300+": the count is a floor, and saying so is the honest form.
    nonisolated static let searchLimit = 300
    private var matched: [Item] = []
    private var showsAll = false
    /// Set while the index is still reading logs for the first time.
    private var indexing: (done: Int, total: Int)?
    private var tall = false
    private var searchTask: Task<Void, Never>?
    private var filterGeneration = 0
    private var query = ""
    private var partial = false
    private(set) var openingGeneration = 0
    private(set) var searchPublications = 0

    /// The tap. Carries the row's lamp because the verb depends on it (ruled
    /// 15 Sep): an amber row's tap is Go to Agent, a green or quiet row's tap
    /// picks it up, a dead row's tap revives it.
    var onPick: ((_ row: SessionRow, _ revivable: Bool) -> Void)?
    /// A click on the LAMP COLUMN, which is the session's power switch and
    /// never navigation — see `SessionRow.lampAction(for:)`. The whole row is
    /// handed over rather than an id, because the switch's verb is a function
    /// of the lamp and the caller must read it from the same place the grid
    /// does, or the same dot means two things on two faces.
    var onLamp: ((_ row: SessionRow) -> Void)?
    var onFilterChanged: (() -> Void)?
    /// A search answered. For telemetry: how many, in which order, how long.
    var onSearched: ((_ results: Int, _ order: SessionKeywordIndex.Order, _ milliseconds: Int) -> Void)?
    /// Right-click → "Terminate" on a LIVE row (ruled 13 Aug). Dead sessions
    /// have no process to end and get no menu — an empty menu would promise a
    /// verb this row cannot perform.
    var onTerminate: ((_ id: String, _ name: String) -> Void)?
    /// Right-click → "Go to agent", also on a LIVE row. It was the left-click
    /// until 19 Aug, when Robert pointed out that a session he clicks is a
    /// session he wants ON, not a Terminal window he did not ask for: *"that's
    /// fine as a right-click behaviour."* It keeps the same company as
    /// Terminate — the two verbs that reach past the panel to the process.
    var onGoTo: ((_ id: String) -> Void)?

    /// What the key line says: how much you are looking at, and out of what.
    private(set) var summary = ""

    init(width: CGFloat, height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Overlay scrollers: no reserved gutter, nothing moves when the list
        // grows past the frame, and the indicator fades when it is not needed.
        // It lands in the panel's own padding rather than over the id column —
        // there is no control on the right of a row (the lamp is the only one
        // and it is on the LEFT), so the worst case is a thin line over the
        // last characters of an id while you are actively dragging.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = stack

        // Hover is arbitrated HERE, not by each row.
        //
        // Per-row tracking areas cannot do this job in a scroll view. They fire
        // on enter and exit, and scrolling moves the CONTENT under a stationary
        // cursor — so rows slid under the pointer, took an enter, and never took
        // an exit. The symptom was every row you had scrolled past staying lit
        // at once, which is also the proof that no one was arbitrating: two rows
        // can only be hovered if nothing owns "the hovered row".
        //
        // `.inVisibleRect` was not enough on its own: it keeps a tracking rect
        // aligned with the visible area, and still says nothing about who is
        // under the mouse after a scroll nobody moved the mouse for.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        filterField.onChange = { [weak self] text in
            self?.filter(text)
            self?.onFilterChanged?()
        }
        filterField.setOrder(order)
        filterField.onOrder = { [weak self] picked in
            guard let self, picked != order else { return }
            order = picked
            if !query.isEmpty { filter(query) }
        }

        addSubview(filterField)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            filterField.topAnchor.constraint(equalTo: topAnchor),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterField.widthAnchor.constraint(equalToConstant: width),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: height),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called ONCE per opening. See the type's note: this face does not
    /// refresh under the reader.
    /// False while the archive walk has not landed. An empty list then means
    /// "not measured yet", and saying "0 sessions" would be answering a
    /// question nobody has asked yet.
    var archiveRead = true

    func apply(items: [Item]) {
        openingGeneration += 1
        searchTask?.cancel()
        search = nil
        partial = false
        self.items = items
        searchable = items
        filterField.reset()
        filter("")
    }

    /// The wider set a search may answer with. Arrives once per opening, a
    /// moment after the list, because building it reads the archive.
    func setSearchable(_ items: [Item], opening: Int) {
        guard opening == openingGeneration else { return }
        searchable = items
        if !query.isEmpty { filter(query) }
    }

    /// The index is reading logs for the first time, or has finished. A search
    /// already answers from the part that exists; when the rest lands, the
    /// same query is asked again.
    func indexProgress(_ progress: (done: Int, total: Int)?) {
        let finished = indexing != nil && progress == nil
        indexing = progress
        guard !query.isEmpty else { return }
        if finished { filter(query) } else { summary = resultSummary(); onFilterChanged?() }
    }

    func setOrderForTesting(_ picked: SessionKeywordIndex.Order) { filterField.pick(picked) }
    var rowHeightsForTesting: [CGFloat] {
        stack.arrangedSubviews.compactMap { ($0 as? PastRowView)?.frame.height }
    }
    var excerptsForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? PastRowView)?.excerptForTesting }
    }
    var chipsForTesting: [String?] {
        stack.arrangedSubviews.compactMap { $0 as? PastRowView }.map(\.chipForTesting)
    }
    var showAllTitleForTesting: String? { showAllButton?.title }
    func showAllForTesting() { showAllTapped() }

    private func resultSummary() -> String {
        let count = matched.count
        let total = count >= Self.searchLimit ? "\(count)+" : "\(count)"
        var text = shown.count < count ? "\(shown.count) of \(total) agents"
                                       : "\(total) agent\(count == 1 ? "" : "s")"
        text += order == .recent ? " · newest first" : " · best match first"
        if let indexing, indexing.total > 0 {
            text = "Indexing \(indexing.done) of \(indexing.total) · " + text
        }
        return text + (partial ? " · some text unavailable" : "")
    }

    /// A cold archive finishes once per opening. Preserve any text already typed.
    func finishArchive(items: [Item], opening: Int) {
        guard opening == openingGeneration else { return }
        self.items = items
        archiveRead = true
        filter(query)
    }

    func installSearch(_ search: @escaping Search, opening: Int, partial: Bool = false) {
        guard opening == openingGeneration else { return }
        self.search = search
        self.partial = partial
        if !query.isEmpty { filter(query) }
    }

    func searchFailed(opening: Int) {
        guard opening == openingGeneration else { return }
        summary = "Search unavailable · reopen to retry"
        onFilterChanged?()
    }

    func cancelSearch() {
        openingGeneration += 1
        filterGeneration += 1
        searchTask?.cancel()
    }

    /// Keep the previous answer while computing one complete ranked answer.
    /// Both generations matter: an old query can finish after clearing the
    /// field, and the same text can be entered again after reopening the list.
    private func filter(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        filterGeneration += 1
        searchTask?.cancel()
        // Typing starts a new answer at its first page. Only the SHOW ALL tap,
        // which calls `filter` with the same words, keeps the whole list.
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != lastAsked { showsAll = false }
        lastAsked = query
        guard !query.isEmpty else {
            matched = []
            showsAll = false
            tall = false
            shown = items
            summary = archiveRead
                ? "\(items.count) session\(items.count == 1 ? "" : "s") · "
                    + "\(Int(SessionDiscovery.defaultWindow / 86_400)) days"
                : "Reading the archive…"
            rebuild()
            setHovered(nil)
            scrollToTop()
            onFilterChanged?()
            return
        }
        guard let search else {
            // The app installs the search in the same turn that opens the
            // list, so this is a state no opening should reach. It read
            // "Preparing search…" on every opening until 15 Nov 2026, while
            // the index was rebuilt from nothing each time.
            summary = "Search is not ready"
            onFilterChanged?()
            return
        }
        // Keep the previous answer's summary: a search takes milliseconds,
        // and a line that flickers to "Searching…" on every key reads as work.
        if matched.isEmpty { summary = "Searching…"; onFilterChanged?() }
        let generation = filterGeneration
        let opening = openingGeneration
        let requested = query
        let wanted = order
        let everything = showsAll
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(everything ? 0 : 70))
                let began = Date()
                let matches = try await search(requested, wanted, everything)
                try Task.checkCancellation()
                guard let self, self.filterGeneration == generation,
                      self.openingGeneration == opening else { return }
                let byID = Dictionary((self.searchable + self.items).map { ($0.row.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
                let now = Date()
                self.matched = matches.compactMap { match in
                    guard let item = byID[match.id] else { return nil }
                    let line = MatchLine(match)
                    // The time column says when the shown passage was said,
                    // which is what "newest first" is ordered by.
                    let when = match.count > 0
                        ? SessionActivity.lastMovedLabel(match.at, now: now) : item.aux
                    let tooltip = [item.tooltip, match.excerpt.isEmpty ? nil : line.plain]
                        .compactMap { $0 }.joined(separator: "\n\n")
                    return Item(row: item.row, revivable: item.revivable,
                                haystack: item.haystack, aux: when, tooltip: tooltip,
                                folder: item.folder, match: line)
                }
                self.showsAll = everything
                self.tall = true
                self.shown = everything ? self.matched
                                        : Array(self.matched.prefix(Self.resultPage))
                self.summary = self.resultSummary()
                self.onSearched?(self.matched.count, wanted,
                                 Int(Date().timeIntervalSince(began) * 1000))
                self.searchPublications += 1
                self.rebuild()
                self.setHovered(nil)
                self.scrollToTop()
                self.onFilterChanged?()
            } catch is CancellationError { }
            catch {
                guard let self, self.filterGeneration == generation,
                      self.openingGeneration == opening else { return }
                self.searchFailed(opening: opening)
            }
        }
    }

    var shownIDsForTesting: [String] { shown.map { $0.row.id } }
    func filterForTesting(_ text: String) {
        filterField.input.stringValue = text
        filterField.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                       object: filterField.input))
    }

    private func rebuild() {
        stack.removeAllArrangedSubviews()
        showAllButton = nil
        for (index, item) in shown.enumerated() {
            let row = PastRowView(item: item, target: self,
                                  action: #selector(rowTapped(_:)), tall: tall)
            // Set on EVERY row, not only the ones with something to switch.
            // The grid's original set it on green alone, which is why the
            // column read as inert everywhere else and a dark lamp sent you to
            // a Terminal tab instead of turning the session on. A rule that
            // holds on some rows is not a rule you can learn.
            row.onLampTap = { [weak self] in self?.onLamp?(item.row) }
            // The menu item NAMES its target — "Terminate “promotions-f9”" —
            // which is the confirmation: a right-click then a click on a
            // sentence containing the right name. No dialog after that.
            if !item.revivable {
                let menu = NSMenu()
                // Go to agent first: it is the ordinary one, and the
                // destructive verb should never be the item under the pointer.
                let goTo = NSMenuItem(
                    title: "Go to \u{201C}\(item.row.name)\u{201D}",
                    action: #selector(goToPicked(_:)), keyEquivalent: "")
                goTo.target = self
                goTo.representedObject = item.row.id
                menu.addItem(goTo)
                menu.addItem(.separator())
                let terminate = NSMenuItem(
                    title: "Terminate \u{201C}\(item.row.name)\u{201D}",
                    action: #selector(terminatePicked(_:)), keyEquivalent: "")
                terminate.target = self
                terminate.representedObject = item.row.id
                menu.addItem(terminate)
                row.menu = menu
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: frame.width == 0
                ? StatusHUD.gridWidth : frame.width).isActive = true
            if index < shown.count - 1 {
                let rule = NSView()
                rule.wantsLayer = true
                rule.layer?.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            }
        }
        // The rest of a long answer, one tap away. After the last row, so the
        // rows above keep the fixed pitch `rowIndex(at:)` divides by.
        if tall, shown.count < matched.count {
            let button = ConsoleButton(title: "", target: self, action: #selector(showAllTapped))
            button.isBordered = false
            button.title = "SHOW ALL \(matched.count)"
            button.attributedTitle = Widgets.letterspaced(
                "SHOW ALL \(matched.count) ›", size: 9.5, tracking: 1.33,
                color: StateLegend.Palette.accent)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: GridRowView.height).isActive = true
            stack.addArrangedSubview(button)
            showAllButton = button
        }
    }

    private var showAllButton: NSButton?
    private var lastAsked = ""

    /// The rest of the answer. Asked of the index again, because only the
    /// first page was given its passages.
    @objc private func showAllTapped() {
        guard shown.count < matched.count, !query.isEmpty else { return }
        showsAll = true
        filter(query)
    }

    /// One tracking area over the whole list, so exactly one row can be lit.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }
    @objc private func scrolled() { updateHover() }

    /// Who is under the pointer right now, asked of geometry rather than
    /// remembered from an event. A scroll changes the answer without any event
    /// at all, which is why this is recomputed rather than tracked.
    ///
    /// It runs on EVERY frame of a live scroll, so it has to cost nothing. The
    /// first version scanned every arranged subview and converted each one's
    /// rect — an allocation and forty-five coordinate conversions per frame,
    /// which is what made the scroll feel like it was snapping rather than
    /// moving. Rows are a fixed pitch in a flipped stack, so the row under a
    /// point is one division.
    private func updateHover() {
        guard let window, window.isVisible else { return setHovered(nil) }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { return setHovered(nil) }
        let inStack = convert(local, to: stack)
        guard let index = rowIndex(at: inStack.y),
              let row = stack.arrangedSubviews[safe: index * 2] as? PastRowView
        else { return setHovered(nil) }
        setHovered(row)
    }

    /// Rows and their separators alternate, so row `i` is arranged subview
    /// `i * 2` and occupies one pitch from the top of the flipped stack.
    private func rowIndex(at y: CGFloat) -> Int? {
        // One height for every row of a face: a search result is taller than a
        // plain row, and all of them are, so the pitch is still one constant.
        let height = tall ? PastRowView.resultHeight : GridRowView.height
        let pitch = height + 1
        guard y >= 0 else { return nil }
        let index = Int(y / pitch)
        // Inside the row itself rather than on the hairline under it: a pointer
        // resting on a separator belongs to neither row.
        guard index < shown.count, y - CGFloat(index) * pitch <= height
        else { return nil }
        return index
    }

    private weak var hovered: PastRowView?

    private func setHovered(_ row: PastRowView?) {
        guard hovered !== row else { return }
        hovered?.setHovered(false)
        row?.setHovered(true)
        hovered = row
    }

    /// The top, in a flipped document view, is y = 0 — and it has to be applied
    /// AFTER layout, or the clip view clamps the scroll against a content size
    /// it has not been told about yet and lands wherever it already was.
    private func scrollToTop() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func rowTapped(_ sender: NSControl) {
        guard let id = sender.identifier?.rawValue,
              let item = shown.first(where: { $0.row.id == id }) else { return }
        onPick?(item.row, item.revivable)
    }

    @objc private func goToPicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onGoTo?(id)
    }

    @objc private func terminatePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = shown.first(where: { $0.row.id == id }) else { return }
        onTerminate?(id, item.row.name)
    }

    /// For the pick-up drill: the verb each row offers, by id. The label is
    /// the row's promise about what a click does, and it went wrong silently
    /// the last time the verb moved.
    var verbsForTesting: [String: String] {
        Dictionary(uniqueKeysWithValues: stack.arrangedSubviews.compactMap { view in
            guard let row = view as? PastRowView, let id = row.identifier?.rawValue
            else { return nil }
            return (id, row.verbForTesting)
        })
    }

    /// For the pick-up drill: the right-click menu on each row that has one.
    var menuTitlesForTesting: [String: [String]] {
        Dictionary(uniqueKeysWithValues: stack.arrangedSubviews.compactMap { view in
            guard let row = view as? PastRowView, let id = row.identifier?.rawValue,
                  let menu = row.menu else { return nil }
            return (id, menu.items.map(\.title).filter { !$0.isEmpty })
        })
    }

    /// For the copy drill: what the pointer would show on each row.
    var toolTipsForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? PastRowView)?.toolTip }
    }

    /// For the name drill: how wide each row's NAME was actually laid out.
    /// Read from the frame, because the failure this guards is a name that is
    /// set correctly and rendered at zero points — a long stall reason in the
    /// right column squeezing it out (19 Aug).
    var nameWidthsForTesting: [(id: String, width: CGFloat)] {
        stack.arrangedSubviews.compactMap {
            guard let row = $0 as? PastRowView, let id = row.identifier?.rawValue
            else { return nil }
            return (id, row.nameWidthForTesting)
        }
    }

    /// For the column drill: how wide each row's RIGHT column was laid out.
    /// The failure it guards is the mirror of the name one — a long TITLE
    /// squeezing the time to zero, so three rows showed no time at all
    /// (screenshot, 19 Aug).
    var auxWidthsForTesting: [(id: String, width: CGFloat)] {
        stack.arrangedSubviews.compactMap {
            guard let row = $0 as? PastRowView, let id = row.identifier?.rawValue
            else { return nil }
            return (id, row.auxWidthForTesting)
        }
    }

    /// For the lamp drill: which rows carry a switch in the lamp column.
    /// Asserted rather than assumed, because "every row" IS the ruling — a
    /// target on some rows is exactly what made the column unlearnable.
    var lampTargetsForTesting: [String] {
        stack.arrangedSubviews.compactMap {
            guard let row = $0 as? PastRowView, row.onLampTap != nil,
                  let id = row.identifier?.rawValue else { return nil }
            return id
        }
    }

    /// For the launch drill: which rows exist and whether each carries the
    /// terminate menu — asserted against liveness, never assumed from it.
    var rowsForTesting: [(id: String, hasMenu: Bool)] {
        stack.arrangedSubviews.compactMap {
            guard let row = $0 as? PastRowView, let id = row.identifier?.rawValue
            else { return nil }
            return (id, row.menu != nil)
        }
    }

    func beginFiltering() { window?.makeFirstResponder(filterField.input) }

    /// What the caret is actually painted with, read back from the live field
    /// editor rather than from the constant that set it — the drill's job is to
    /// catch AppKit handing back its own accent, which a constant cannot see.
    /// Whether the list is showing its first row. In a flipped document view
    /// the top is y = 0, which is also what makes this assertable at all.
    var isAtTopForTesting: Bool {
        stack.isFlipped && scroll.contentView.bounds.origin.y <= 0.5
    }

    var caretColourForTesting: NSColor? {
        (filterField.input.currentEditor() as? NSTextView)?.insertionPointColor
    }
}

/// The filter, as a ROW rather than a box.
///
/// Ruled 12 Aug: same placard grammar as `+ NEW AGENT` — a glyph in the lamp
/// column and text beside it. No bezel, no focus ring, no rounded search field:
/// a control that looks like a form field would be the only one on the panel,
/// and the panel is an instrument, not a form.
private final class FilterRowView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 36
    let input = FilterField()
    var onChange: ((String) -> Void)?
    /// Recent or Relevant. Two words, drawn the way the harness picker draws
    /// its choices: the chosen one in ink, the other in hint. Not a segmented
    /// control, whose bezel is AppKit chrome this panel refuses everywhere.
    var onOrder: ((SessionKeywordIndex.Order) -> Void)?
    private var orderButtons: [SessionKeywordIndex.Order: ConsoleButton] = [:]
    private var order: SessionKeywordIndex.Order = .recent

    func setOrder(_ picked: SessionKeywordIndex.Order) {
        order = picked
        for (kind, button) in orderButtons {
            button.attributedTitle = Widgets.letterspaced(
                kind == .recent ? "RECENT" : "RELEVANT", size: 9.5, tracking: 1.33,
                color: kind == picked ? StateLegend.Palette.ink : StateLegend.Palette.hint)
            button.toolTip = kind == .recent ? "Newest matching message first"
                                             : "Best match first: the name, then your words, then the agent's"
        }
    }

    func pick(_ picked: SessionKeywordIndex.Order) {
        setOrder(picked)
        onOrder?(picked)
    }

    @objc private func orderTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let picked = SessionKeywordIndex.Order(rawValue: raw) else { return }
        pick(picked)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSTextField(labelWithString: "⌕")
        glyph.font = ChromeType.mono(ofSize: 12, weight: .regular)
        glyph.textColor = StateLegend.Palette.hint
        glyph.translatesAutoresizingMaskIntoConstraints = false

        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = ChromeType.mono(ofSize: 12, weight: .regular)
        input.textColor = StateLegend.Palette.ink
        input.placeholderAttributedString = NSAttributedString(
            string: "Filter",
            attributes: [.font: ChromeType.mono(ofSize: 12, weight: .regular),
                         .foregroundColor: StateLegend.Palette.faint])
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyph); addSubview(input)
        var trailing = trailingAnchor
        for kind in [SessionKeywordIndex.Order.relevant, .recent] {
            let button = ConsoleButton(title: "", target: self, action: #selector(orderTapped(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(button)
            orderButtons[kind] = button
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.trailingAnchor.constraint(equalTo: trailing,
                                                 constant: kind == .relevant ? 0 : -14),
            ])
            trailing = button.leadingAnchor
        }
        setOrder(order)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: trailing, constant: -12),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func reset() { input.stringValue = "" }
    var currentText: String { input.stringValue }

    func controlTextDidChange(_ obj: Notification) { onChange?(input.stringValue) }
}

/// A stack that counts from the top.
///
/// AppKit's default coordinate origin is the BOTTOM left, so a stack view used
/// as a scroll view's document view lays its first arranged subview at the
/// bottom and `scroll(to: .zero)` scrolls to the end of the list. The list
/// opened on its oldest session every time, which reads as a bug in the sort
/// rather than as a coordinate system.
///
/// Flipping the document view is the whole fix: first row at the top, `.zero`
/// at the top, and the row index maths in `rowIndex(at:)` become the obvious
/// arithmetic instead of a subtraction from the total height.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// A text field whose caret belongs to the console.
///
/// AppKit paints the insertion point in the system accent colour, which on this
/// panel is a saturated blue against a dark olive console — the loudest thing on
/// a face whose whole job is calm, blinking, for a control you are not even
/// using yet. It is also the one colour the palette reserves for something else
/// entirely: blue is the WORKING lamp, and a blinking blue mark on the panel
/// means an agent has work in hand.
///
/// The caret takes the colour of the text it is placing, which is what a caret
/// is: the position of the next glyph, not an announcement.
final class FilterField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = StateLegend.Palette.ink
        }
        return accepted
    }
}

/// A row in the list: the grid's row, plus a verb that appears under the
/// pointer.
///
/// The verb REPLACES the id on hover rather than claiming a third column. At
/// rest the row answers "which one is this"; under the pointer it answers "what
/// happens if I click". A permanent action column would cost ~78pt of name on
/// every row forever to label something you need on one.
final class PastRowView: NSControl {
    /// The right-hand column is FIXED, not negotiated (ruled 19 Aug).
    ///
    /// It used to be negotiated, and both settings were right for the thing the
    /// column held at the time and wrong for the next one. When it held a stall
    /// REASON — a whole sentence — it had to yield, or a long reason ate the
    /// name; so it was given a fraction cap and a resistance one step below the
    /// name's. Then the column started holding the TIME, which is seven
    /// characters, and yielding became the bug: a long title squeezed it to
    /// nothing and three rows in Robert's list showed no time at all, while the
    /// hover verb — which has no such cap — drew straight over the title.
    ///
    /// A time is not a sentence. It has a known maximum width, it is the
    /// question this face exists to answer, and it must be on every row. So the
    /// column is a constant and the TITLE truncates into it — Robert, 19 Aug:
    /// "just slightly truncate the title if we need to, and always show the
    /// time since". The full title stays in the tooltip.
    ///
    /// Measured, not guessed, and measured against the widest thing either
    /// label can hold: `spoken` tops out at seven characters ("89m ago",
    /// "47h ago"; a date is shorter), and the hover verb is "REVIVE ›" with its
    /// tracking. The verb shares the same box, which is what stops it
    /// overlapping the title — it was pinned to the trailing edge with no width
    /// of its own before.
    static let auxColumn: CGFloat = {
        let time = ("88m ago" as NSString)
            .size(withAttributes: [.font: GridRowView.auxFont]).width
        let verb = Widgets.letterspaced("REVIVE ›", size: 9.5, tracking: 1.33,
                                color: .white).size().width
        // Two points of air on each side. The column is measured, but a font
        // substitution on a machine without Berkeley Mono moves the numbers,
        // and clipping the last character of a time is a worse failure than
        // spending four points.
        return ceil(max(time, verb)) + 4
    }()

    private let idLabel: NSTextField
    private let verbLabel: NSTextField
    /// A search result: the usual line, then two lines of the passage that
    /// matched. One fixed height, so the list's hover arithmetic still divides
    /// by a constant.
    static let resultHeight: CGFloat = 78
    private var excerptLabel: NSTextField?
    var excerptForTesting: String? { excerptLabel?.stringValue }

    /// The matched passage as drawn: who said it in small capitals, the words
    /// in the muted ink, and each matched word in full ink and a heavier
    /// weight. Emphasis by weight and contrast, never by a colour of its own.
    static func excerptText(_ line: PastAgentsList.MatchLine, alpha: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !line.speaker.isEmpty {
            out.append(Widgets.letterspaced(line.speaker, size: 9, tracking: 1.4,
                                            color: StateLegend.Palette.hint.withAlphaComponent(alpha)))
            out.append(NSAttributedString(string: "  "))
        }
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: StateLegend.Palette.muted.withAlphaComponent(alpha)]
        let marked: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: StateLegend.Palette.ink.withAlphaComponent(alpha)]
        var run = "", inMark = false
        func flush() {
            guard !run.isEmpty else { return }
            out.append(NSAttributedString(string: run, attributes: inMark ? marked : plain))
            run = ""
        }
        for character in line.excerpt {
            if character == SessionKeywordIndex.Match.open { flush(); inMark = true }
            else if character == SessionKeywordIndex.Match.close { flush(); inMark = false }
            else { run.append(character) }
        }
        flush()
        if line.more > 0 {
            out.append(NSAttributedString(string: "  +\(line.more) more", attributes: [
                .font: GridRowView.auxFont,
                .foregroundColor: StateLegend.Palette.hint.withAlphaComponent(alpha)]))
        }
        return out
    }

    /// The verb this row is promising, read off the label itself rather than
    /// recomputed — a drill that recomputes the answer cannot catch a label
    /// that stopped being set from it.
    var verbForTesting: String { verbLabel.stringValue }

    /// The row names its verb, and amber's is the terminal (ruled 15 Sep),
    /// as is a row with no finished turn to open (21 Sep): the label and the
    /// tap read the same two facts, so the promise and the verb cannot drift.
    static func verb(for item: PastAgentsList.Item) -> String {
        if item.revivable { return "REVIVE ›" }
        return item.row.lamp == .fault || !item.row.hasRecordedTurn ? "GO TO ›" : "OPEN ›"
    }
    var auxWidthForTesting: CGFloat { idLabel.frame.width }
    private let highlight = NSView()
    /// Held so the hover can step its ink and put it back — see `setHovered`.
    private var nameLabel: NSTextField!
    private var restingName: NSColor = StateLegend.Palette.ink

    init(item: PastAgentsList.Item, target: AnyObject, action: Selector, tall: Bool = false) {
        idLabel = NSTextField(labelWithString: item.aux ?? item.row.aux)
        // Green for a resurrection, advisory grey for a door — the same two
        // channels the card uses for the same two meanings.
        verbLabel = NSTextField(labelWithString: Self.verb(for: item))
        super.init(frame: .zero)
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier(item.row.id)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The same hover as the grid, through the same function: a row that
        // said one thing on one face and another on the other would be worse
        // than one that said nothing.
        toolTip = item.tooltip ?? SessionRow.hoverText(for: item.row)

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.translatesAutoresizingMaskIntoConstraints = false

        let ink = item.row.lamp.rowAlpha
        let lamp = NSView()
        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        // Same fill-vs-ring read channel as the grid (16 Aug): solid unread,
        // hollow once opened, in the state's own colour. One rule in both
        // lists, or "have I heard this" would mean something different
        // depending on which face you were looking at.
        let hollow = item.row.read == .opened && item.row.lamp.asksForYou
        lamp.layer?.backgroundColor = hollow ? NSColor.clear.cgColor
                                             : item.row.lamp.fill.cgColor
        lamp.layer?.cornerRadius = Lamp.diameter / 2
        if hollow {
            lamp.layer?.borderWidth = 1.5
            lamp.layer?.borderColor = item.row.lamp.fill.cgColor
        } else if let ring = item.row.lamp.ring {
            lamp.layer?.borderWidth = 1
            lamp.layer?.borderColor = ring.cgColor
        }

        // The read state travels with the row (16 Aug: "idle should have our
        // read text treatment too"). This list is where you come to FIND a
        // session, so "have I already heard this one" is worth as much here
        // as it is on the grid — and the row has carried the flag all along,
        // it was simply the grid that read it.
        //
        // It composes with `rowAlpha` rather than competing: alpha says
        // running-or-gone, the token says read-or-not, so a dead row you had
        // opened is dimmed once by each and still cannot be mistaken for a
        // live one.
        let name = NSTextField(labelWithString: item.row.name)
        name.font = ChromeType.mono(ofSize: 13, weight: .medium)
        name.textColor = (item.row.read.isAsking && item.row.lamp.asksForYou
                          ? StateLegend.Palette.ink
                          : StateLegend.Palette.restingInk).withAlphaComponent(ink)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        idLabel.font = GridRowView.auxFont
        idLabel.textColor = StateLegend.Palette.muted.withAlphaComponent(ink)
        idLabel.alignment = .right
        // The right column YIELDS to the name, and is capped besides.
        //
        // Both halves are needed and neither is enough alone. This column
        // usually holds an eight-character id, so nothing ever pushed on the
        // name — until a stopped session put its REASON here instead (16 Aug,
        // and correctly: "an id would be the one row where this column says
        // nothing useful"). A reason is a sentence. With the name at
        // `.defaultLow` compression resistance and this label at the default,
        // the sentence won every time: "silent for 24h, nothing written since
        // it started" took the whole row and the agent's name was squeezed to
        // ZERO WIDTH — the one row in the list that did not say which agent it
        // was (screenshot, 19 Aug).
        //
        // The grid never had this bug because it measures one shared column
        // across every row and caps it at `auxFraction`; the list, which builds
        // each row alone, had neither. It gets both: the cap, so a long reason
        // cannot claim more than the grid would give it, and a lower resistance
        // than the name, so the name is the last thing to lose space rather
        // than the first. What is cut off is reachable — the row's tooltip
        // carries the name and the full message, uncut (`StateLegend.hoverText`).
        idLabel.lineBreakMode = .byClipping
        // Nothing to negotiate: the column below is a constant, so the label
        // neither claims more than its share nor gives any of it up. The
        // resistance dance this replaces is described on `auxColumn`.
        idLabel.translatesAutoresizingMaskIntoConstraints = false

        verbLabel.attributedStringValue = Widgets.letterspaced(
            Self.verb(for: item), size: 9.5, tracking: 1.33,
            color: item.revivable ? StateLegend.Palette.ready : StateLegend.Palette.accent)
        verbLabel.alignment = .right
        verbLabel.isHidden = true
        verbLabel.translatesAutoresizingMaskIntoConstraints = false

        // Everything that sat on the row's centre sits on the centre of its
        // first line instead, so a plain row and a result row share one layout.
        let line = NSLayoutGuide()
        addLayoutGuide(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.heightAnchor.constraint(equalToConstant: GridRowView.height),
        ])
        addSubview(highlight)
        nameLabel = name
        restingName = name.textColor ?? StateLegend.Palette.ink
        addSubview(lamp); addSubview(name); addSubview(idLabel); addSubview(verbLabel)
        // The folder chip sits between the name and the time, and the name
        // gives way to it: truncating the title is fine, losing the chip is not.
        let nameEnd: NSLayoutXAxisAnchor
        if let folder = item.folder {
            let chip = NSTextField(labelWithAttributedString: Widgets.letterspaced(
                folder.uppercased(), size: 9, tracking: 1.4, color: StateLegend.Palette.muted))
            chip.wantsLayer = true
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = StateLegend.Palette.hairline.cgColor
            chip.layer?.cornerRadius = 3
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            chip.lineBreakMode = .byClipping
            chipLabel = chip
            addSubview(chip)
            NSLayoutConstraint.activate([
                chip.centerYAnchor.constraint(equalTo: line.centerYAnchor),
                chip.trailingAnchor.constraint(equalTo: idLabel.leadingAnchor, constant: -10),
                chip.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
            ])
            nameEnd = chip.leadingAnchor
        } else {
            nameEnd = idLabel.leadingAnchor
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: tall ? Self.resultHeight : GridRowView.height),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: -GridRowView.hoverBleed),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                constant: GridRowView.hoverBleed),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            lamp.widthAnchor.constraint(equalToConstant: Lamp.diameter),
            lamp.heightAnchor.constraint(equalToConstant: Lamp.diameter),
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor),
            lamp.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: GridRowView.lampColumn),
            name.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: nameEnd,
                                           constant: -12),
            idLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            idLabel.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            idLabel.widthAnchor.constraint(equalToConstant: Self.auxColumn),
            verbLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            verbLabel.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            // The verb stands in the time's box rather than beside it. Without
            // a width it sized to its own text and drew over the title, because
            // the title's only right-hand limit is `idLabel`'s leading edge.
            verbLabel.widthAnchor.constraint(equalToConstant: Self.auxColumn),
        ])
        if tall, let match = item.match {
            let excerpt = NSTextField(wrappingLabelWithString: "")
            excerpt.attributedStringValue = Self.excerptText(match, alpha: ink)
            excerpt.maximumNumberOfLines = 2
            excerpt.cell?.wraps = true
            excerpt.cell?.truncatesLastVisibleLine = true
            excerpt.cell?.lineBreakMode = .byWordWrapping
            excerpt.isSelectable = false
            excerpt.translatesAutoresizingMaskIntoConstraints = false
            excerpt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(excerpt)
            excerptLabel = excerpt
            NSLayoutConstraint.activate([
                excerpt.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                 constant: GridRowView.lampColumn),
                excerpt.trailingAnchor.constraint(equalTo: trailingAnchor),
                excerpt.topAnchor.constraint(equalTo: line.bottomAnchor, constant: -5),
                excerpt.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the drill needs to see: the name's laid-out width. Read from the
    /// FRAME rather than from the string, because the failure mode is a name
    /// that is set correctly and rendered at zero points.
    var nameWidthForTesting: CGFloat { nameLabel.frame.width }
    private(set) var chipLabel: NSTextField?
    var chipForTesting: String? { chipLabel?.stringValue }

    /// Rule 1 of the hover standard (18 Aug): the wash says which row, the
    /// cursor says it is a control.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        PointerCursor.track(self)
    }
    override func cursorUpdate(with event: NSEvent) { PointerCursor.show() }

    /// Told, not tracked. The list decides who is hovered — see its own note:
    /// a row cannot know it stopped being under the pointer when the thing that
    /// moved was the scroll view and not the mouse.
    func setHovered(_ on: Bool) {
        // Words only, exactly as the grid's rows — see `GridRowView.setHovered`.
        // This list has a second cue the grid does not: the id gives way to the
        // verb, so the hovered row also says what a click would DO.
        nameLabel.textColor = on ? StateLegend.hovered(restingName) : restingName
        idLabel.isHidden = on
        verbLabel.isHidden = !on
    }

    /// The lamp column, as a control — the same `lampHitWidth` at the same full
    /// row height the grid uses, so the switch is in the same place and the same
    /// size wherever you meet a session. Never falls through to the row's verb:
    /// the point of a switch is that it is not a door.
    var onLampTap: (() -> Void)?

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let onLampTap, point.x <= GridRowView.lampHitWidth {
            onLampTap()
            return
        }
        sendAction(action, to: target)
    }
}

/// Two placards, one row. Ruled 12 Aug: NEW AGENT and PAST AGENTS are halves of
/// one idea — putting an agent on the list, by starting it or by bringing it
/// back — and two 32pt rows for that was a row too many on a panel whose whole
/// discipline is height.
final class SplitPlacardRowView: NSView {
    static let height: CGFloat = 32

    init(width: CGFloat, target: AnyObject,
         leadingHarness: String? = nil,
         leading: (String, String, Selector),
         trailing: (String, String, Selector)) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Each half hugs its own outer edge — the left one reads from the
        // panel's left margin, the right one lands on its right. Left-aligning
        // both put PAST AGENTS in the middle of the row with a hole beside it,
        // which reads as a mistake rather than as a column.
        let left = PlacardHalf(title: leading.0, glyph: leading.1, alignment: .leading,
                               target: target, action: leading.2,
                               harness: leadingHarness)
        let right = PlacardHalf(title: trailing.0, glyph: trailing.1, alignment: .trailing,
                                target: target, action: trailing.2)
        addSubview(left); addSubview(right)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: width / 2),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One placard across the whole row (19 Sep): the manager's door. The split
/// row is for two ways of putting an agent on the grid; this is one thing.
final class PlacardRowView: NSView {
    static let height: CGFloat = SplitPlacardRowView.height

    init(width: CGFloat, target: AnyObject, title: String, glyph: String, action: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let placard = PlacardHalf(title: title, glyph: glyph, alignment: .leading,
                                  target: target, action: action)
        addSubview(placard)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            placard.leadingAnchor.constraint(equalTo: leadingAnchor),
            placard.trailingAnchor.constraint(equalTo: trailingAnchor),
            placard.topAnchor.constraint(equalTo: topAnchor),
            placard.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

private final class PlacardHalf: NSControl {
    private let mark = NSTextField(labelWithString: "")
    private let harnessMark = NSImageView()
    /// Ink height for the mark beside a 9.5pt placard label. A number, chosen
    /// by eye against the caps and then checked in a pose shot, which is the
    /// right amount of ceremony for aligning an icon to some text.
    private static let markHeight: CGFloat = 6
    private let label = NSTextField(labelWithString: "")
    private var resting: [NSAttributedString] = []

    /// The hover standard, re-ruled 18 Aug: **a row washes, a word brightens.**
    ///
    /// This was a wash — a rounded fill across the whole half — because it was
    /// built beside the grid rows, which wash. But a grid row IS a region: a
    /// lamp, a name and a callsign across 352pt, where the fill tells you which
    /// row the click will land on. NEW AGENT and PAST AGENTS are two words in a
    /// strip, and a fill four times their width reads as a button that isn't
    /// there — "they have a big background hover instead of a text hover
    /// effect. That's an inconsistency."
    ///
    /// So the words brighten, exactly as `Controls` and the state pill do, and
    /// the cursor still says the placard is a control at all. The wash stays
    /// where a region needs one.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func cursorUpdate(with event: NSEvent) { PointerCursor.show() }

    init(title: String, glyph: String, alignment: NSLayoutConstraint.Attribute,
         target: AnyObject, action: Selector, harness: String? = nil) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        mark.attributedStringValue = ChromeType.line(
            glyph, font: ChromeType.mono(ofSize: 12, weight: .regular),
            color: StateLegend.Palette.hint)
        mark.translatesAutoresizingMaskIntoConstraints = false

        // A door, so the door treatment: mono, sentence case, the bottom row's
        // size and tracking (ruled 29 Sep 2026). Tracked capitals are for
        // labels, which name a region; these are things you press.
        label.attributedStringValue = StateLegend.BottomLine.label(
            title, weight: .regular, color: StateLegend.Palette.hint)
        label.translatesAutoresizingMaskIntoConstraints = false
        resting = [mark.attributedStringValue, label.attributedStringValue]

        // NEW AGENT wears the mark of the harness the "+" will create. It is
        // the one placement that is never redundant: this row is a button whose
        // effect depends on a setting you cannot see from here.
        //
        // An image view centred on the label. That is all this ever needed to
        // be: a text attachment was tried first and got scaled by the line
        // fragment, which cost an afternoon of measuring pose shots to notice.
        if let harness {
            harnessMark.image = HarnessMark.image(height: Self.markHeight, harness: harness)
            harnessMark.contentTintColor = StateLegend.Palette.hint
                .withAlphaComponent(HarnessMark.opacity)
            harnessMark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(harnessMark)
        }

        addSubview(mark); addSubview(label)
        NSLayoutConstraint.activate([
            // Not a plain centerY: that centres two FRAMES, and a mark's ink
            // sits differently inside its box than a capital does inside
            // theirs. The offset is measured — see `ChromeType.capLineOffset`.
            // The mark keeps its own view here because the 20pt gutter lines up
            // with the grid's lamp column, which a merged string would lose.
            mark.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: -ChromeType.capLineOffset(
                    mark: Character(glyph),
                    markFont: ChromeType.mono(ofSize: 12, weight: .regular),
                    textFont: ChromeType.mono(ofSize: 9.5, weight: .regular))),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if harnessMark.image != nil {
            let size = HarnessMark.size(height: Self.markHeight,
                                        harness: harness ?? "")
            NSLayoutConstraint.activate([
                harnessMark.widthAnchor.constraint(equalToConstant: size.width),
                harnessMark.heightAnchor.constraint(equalToConstant: size.height),
                harnessMark.leadingAnchor.constraint(equalTo: label.trailingAnchor,
                                                     constant: 6),
                harnessMark.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
        }
        // The glyph keeps the lamp column's 20pt offset from the label either
        // way, so both halves read as the same control mirrored rather than as
        // two controls that happen to share a row.
        if alignment == .trailing {
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                mark.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -11),
            ])
        } else {
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
        PointerCursor.track(self)
    }
    override func mouseEntered(with event: NSEvent) {
        mark.attributedStringValue = StateLegend.hoveredInk(resting[0])
        label.attributedStringValue = StateLegend.hoveredInk(resting[1])
    }
    override func mouseExited(with event: NSEvent) {
        mark.attributedStringValue = resting[0]
        label.attributedStringValue = resting[1]
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
    }
}


private extension Array {
    /// Index arithmetic on a list that is being rebuilt under a live pointer
    /// deserves a bounds check rather than a crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// One editable setting, as a row.
///
/// Same grammar as the list's filter and the + NEW AGENT placard: a small caps
/// label, then the value in the panel's own mono, no bezel and no focus ring.
/// A bordered NSTextField would be the only form control in the app, and the
/// panel is an instrument — the console's own answer to "type here" is a lit
/// field on a dark ground, not a box drawn around one.
///
/// Commits on Return and on losing focus, never per keystroke: this is the
/// command that starts your agents, and saving `claude --dangerous` halfway
/// through typing is a setting that is briefly wrong in a way that matters.
final class SettingRowView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 34
    let input = FilterField()
    var onCommit: ((String) -> Void)?

    /// Set when this row picks a folder instead of taking a typed path.
    var onBrowse: (() -> Void)?

    init(width: CGFloat, label: String, placeholder: String, browsable: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = Widgets.letterspaced(
            label, size: 9.5, tracking: 1.33, color: StateLegend.Palette.hint)
        caption.translatesAutoresizingMaskIntoConstraints = false

        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = ChromeType.mono(ofSize: 11, weight: .regular)
        input.textColor = StateLegend.Palette.ink
        input.lineBreakMode = .byTruncatingHead
        input.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: ChromeType.mono(ofSize: 11, weight: .regular),
                         .foregroundColor: StateLegend.Palette.faint])
        input.delegate = self
        input.translatesAutoresizingMaskIntoConstraints = false

        addSubview(caption); addSubview(input)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 74),
            input.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 8),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // A path is chosen, not spelled. Typing one is possible and it is the
        // fallback, not the affordance: the field truncates from the HEAD so a
        // long path shows the part that identifies it, and the button opens the
        // picker that already knows what a folder is.
        if browsable {
            let browse = ConsoleButton(title: "", target: self, action: #selector(browseTapped))
            browse.isBordered = false
            // Not a bottom-line door — it lives in the settings pane and keeps
            // its own letterspaced sans, so it re-inks through the generic hook.
            browse.reink = { [weak browse] color in
                browse?.attributedTitle = Widgets.letterspaced(
                    "CHOOSE…", size: 9.5, tracking: 1.33, color: color)
            }
            browse.restingInk = StateLegend.Palette.accent
            browse.translatesAutoresizingMaskIntoConstraints = false
            addSubview(browse)
            NSLayoutConstraint.activate([
                browse.trailingAnchor.constraint(equalTo: trailingAnchor),
                browse.centerYAnchor.constraint(equalTo: centerYAnchor),
                input.trailingAnchor.constraint(equalTo: browse.leadingAnchor, constant: -10),
            ])
        } else {
            input.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ value: String) { input.stringValue = value }

    /// The hint text shown when the field is empty — fixed at init for every
    /// row but the launch/directory pair, which now shows a different
    /// harness's fallback depending on which one the agents pane's picker
    /// has selected.
    func setPlaceholder(_ text: String) {
        input.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: ChromeType.mono(ofSize: 11, weight: .regular),
                         .foregroundColor: StateLegend.Palette.faint])
    }

    @objc private func browseTapped() { onBrowse?() }

    func controlTextDidEndEditing(_ obj: Notification) { onCommit?(input.stringValue) }
}

/// The settings pane's tabs.
///
/// Restored from the design (docs/design/settings-recent.html v3,
/// docs/design/settings-microphone.html v1), which drew Settings as a tab bar from the
/// start. The build had drifted into one scrolling column with a
/// "Recent audio ▸" link buried among the voices, and then grew launch settings
/// on top of that — three unrelated concerns in one list, which is how a pane
/// stops being navigable.
///
/// Only the tabs with panes behind them are here. The design also names
/// Microphone, Permissions and Keys; those are proposals, and a tab that opens
/// an empty pane is worse than a tab that is not there yet.
enum SettingsTab: String, CaseIterable {
    case agents = "AGENTS"
    case voices = "VOICES"
    case recent = "RECENT"
    /// LAST, and the order is the point (Robert, 30 Aug): "put the setup tab
    /// fourth because it's usually not going to be relevant, it's just for
    /// reference primarily, whereas recent transcripts is going to be more
    /// relevant. Voices, you're going to want to come to that."
    ///
    /// Tabs are ranked by how often you reach for them, not by how important
    /// they sound. Setup is the one you visit when something is wrong, and
    /// something is usually not wrong.
    case setup = "SETUP"
}

/// A row of tabs: the current one in ink, the rest in hint, a hairline beneath.
///
/// Not NSSegmentedControl — its bezel is the same AppKit chrome the rest of
/// this panel refuses, and on a dark console it reads as a foreign object. Caps
/// are the instrument voice, so tabs wear them: these are controls, not prose.
final class SettingsTabBar: NSView {
    static let height: CGFloat = 30
    private var buttons: [SettingsTab: NSButton] = [:]
    private let rule = NSView()
    var onSelect: ((SettingsTab) -> Void)?
    private(set) var selected: SettingsTab = .agents

    init(width: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.layer?.backgroundColor = StateLegend.Palette.hairline.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        var previous: NSView?
        for tab in SettingsTab.allCases {
            // A ConsoleButton for the cursor alone: no `restingInk`, because
            // a tab's ink already carries which one is open and hover must not
            // overwrite a louder signal with a quieter one.
            let button = ConsoleButton(title: "", target: self, action: #selector(tapped(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(tab.rawValue)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            buttons[tab] = button
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
                button.leadingAnchor.constraint(
                    equalTo: previous?.trailingAnchor ?? leadingAnchor,
                    constant: previous == nil ? 0 : 18),
            ])
            previous = button
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.widthAnchor.constraint(equalToConstant: width),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func select(_ tab: SettingsTab) {
        selected = tab
        paint()
    }

    private func paint() {
        for (tab, button) in buttons {
            let lit = tab == selected
            button.attributedTitle = Widgets.letterspaced(
                tab.rawValue, size: 9.5, tracking: 1.33,
                color: lit ? StateLegend.Palette.ink : StateLegend.Palette.hint)
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let tab = SettingsTab(rawValue: raw) else { return }
        select(tab)
        onSelect?(tab)
    }
}

/// Which agent the Agents tab's configuration rows are showing, and which one
/// `New Agent` starts. Modeled on `SettingsTabBar` itself: hand-drawn buttons,
/// not `NSSegmentedControl`'s bezel, for the same reason.
///
/// **SELECTING IS SETTING, since 14 Sep 2026.** This row used to carry a second
/// affordance, MAKE DEFAULT, on the argument that viewing an agent's settings
/// and making it the one `New Agent` launches are different questions, and that
/// switching which one is SHOWN must never itself change the default.
///
/// They ARE different questions and the extra click was still not worth it.
/// Ruled: "to the user it's just which agent do I want to use." The risk the
/// old design guarded against is real but small and visible: the picker shows
/// which agent is current, so opening this tab to look at one and thereby
/// selecting it is something you can see, not something that happens behind
/// you.
///
/// See `docs/rulings/ruling-settings-picks-an-agent-not-a-mechanism.md`, which
/// also settles that this picker lists agents of BOTH kinds, harnesses and
/// providers alike, with no indication of which is which. That distinction is
/// ours to carry, not the user's.
final class HarnessPickerRow: NSView {
    static let height: CGFloat = 30
    private var buttons: [String: NSButton] = [:]
    private var labels: [String: String] = [:]
    private let makeDefault = ConsoleButton(title: "", target: nil, action: nil)
    var onSelect: ((String) -> Void)?
    var onMakeDefault: ((String) -> Void)?
    private(set) var selected: String
    private(set) var defaultHarness: String

    init(width: CGFloat, harnesses: [(id: String, label: String)],
        selected: String, defaultHarness: String) {
        self.selected = selected
        self.defaultHarness = defaultHarness
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        labels = Dictionary(uniqueKeysWithValues: harnesses.map { ($0.id, $0.label) })

        var previous: NSView?
        for h in harnesses {
            let button = ConsoleButton(title: "", target: self, action: #selector(tapped(_:)))
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(h.id)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            buttons[h.id] = button
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.leadingAnchor.constraint(
                    equalTo: previous?.trailingAnchor ?? leadingAnchor,
                    constant: previous == nil ? 0 : 18),
            ])
            previous = button
        }

        makeDefault.isBordered = false
        makeDefault.target = self
        makeDefault.action = #selector(makeDefaultTapped)
        makeDefault.restingInk = StateLegend.Palette.accent
        makeDefault.translatesAutoresizingMaskIntoConstraints = false
        addSubview(makeDefault)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
            makeDefault.trailingAnchor.constraint(equalTo: trailingAnchor),
            makeDefault.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Re-shown whenever the host's own values change — a save elsewhere (the
    /// `tbase` CLI, another window) must not leave this pane's picker stale.
    func update(selected: String, defaultHarness: String) {
        self.selected = selected
        self.defaultHarness = defaultHarness
        paint()
    }

    private func paint() {
        for (id, button) in buttons {
            let lit = id == selected
            let label = labels[id] ?? id
            let color = lit ? StateLegend.Palette.ink : StateLegend.Palette.hint
            // Through ChromeType.line, not Widgets.letterspaced — the ★ is a
            // MARK (ChromeType.isMark), and letterspaced has no idea marks
            // exist; it draws every character on the same baseline the
            // letters use, which the chrome self-test (`everyMarkComposed`)
            // exists specifically to catch. `line(_:)` is "the one place a
            // glyph meets a word in this app" for exactly this reason.
            button.attributedTitle = id == defaultHarness
                ? ChromeType.line("\(label) ★", font: StateLegend.Face.chrome(9.5),
                                  color: color, tracking: 1.33)
                : Widgets.letterspaced(label, size: 9.5, tracking: 1.33, color: color)
        }
        let viewingDefault = selected == defaultHarness
        makeDefault.isHidden = viewingDefault
        if !viewingDefault {
            makeDefault.attributedTitle = Widgets.letterspaced(
                "MAKE DEFAULT", size: 9.5, tracking: 1.33, color: StateLegend.Palette.accent)
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        selected = id
        paint()
        onSelect?(id)
    }

    @objc private func makeDefaultTapped() { onMakeDefault?(selected) }
}
