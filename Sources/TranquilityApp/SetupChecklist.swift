import AppKit
import TranquilityCore

/// The setup checklist: every prerequisite, its live state, and the one door
/// that fixes it.
///
/// EXTRACTED, NOT COPIED (29 Aug). This lived inside OnboardingWindow, which is
/// the screen you see once. Robert asked for the same rows in Settings, where
/// you go back deliberately after rotating a key or reinstalling a harness, and
/// was explicit about the shape: "a render of the original, not a duplicate."
///
/// He is right, and the reason is this session's own defect twice over. Two
/// screens each drawing their own version of one checklist disagree inside a
/// fortnight, and the one you are not looking at is the one that is wrong. That
/// is the same failure as a manifest describing one harness on a two-harness
/// machine, and as an audit that called five Codex hooks healthy while none of
/// them could run. So there is one renderer and two hosts.
///
/// The two hosts differ in exactly one way, and it is a callback rather than a
/// branch: onboarding gates its "Start using Tranquility Base" button on
/// whether every required row is satisfied. Settings has nothing to gate.
final class SetupChecklistView: NSStackView {

    /// What this host wants from the same rows.
    ///
    /// Onboarding is a list of things to DO: it hides a healthy hooks row,
    /// because a line reporting that nothing happened is furniture on a screen
    /// someone is trying to finish. Settings is a list of what IS: it shows
    /// every row and keeps every door, for the same reason a satisfied key row
    /// always kept its own — a thing that is fine today is a thing you may
    /// still want to re-run.
    ///
    /// The second difference between the hosts, and like the first it is a
    /// value rather than a branch inside the render.
    enum Mode { case onboarding, reference }

    private let mode: Mode

    /// Fired on every render with whether every REQUIRED row is satisfied.
    /// Onboarding enables its start button from this; Settings ignores it.
    var onReadiness: ((Bool) -> Void)?

    private var prereqDots: [Prerequisites.Item: NSTextField] = [:]
    private var prereqNames: [Prerequisites.Item: NSTextField] = [:]
    private var prereqDetails: [Prerequisites.Item: NSTextField] = [:]
    private var prereqButtons: [Prerequisites.Item: ConsoleButton] = [:]
    private var prereqRows: [Prerequisites.Item: NSView] = [:]
    private var prereqStates: [Prerequisites.State] = []
    private var prereqScanInFlight = false
    private var prereqNote: [Prerequisites.Item: String] = [:]

    init(frame: NSRect, mode: Mode = .onboarding) {
        self.mode = mode
        super.init(frame: frame)
        setUpRows()
    }

    /// IS the stack rather than containing one.
    ///
    /// It held a stack pinned to its own edges, and reported no usable height
    /// to the panel, which sized itself to a single row and clipped the rest
    /// (30 Aug, first two pose-shots). A container that must be told its own
    /// height is a constraint problem waiting to be solved twice; a stack knows
    /// how tall its arranged subviews make it.
    private func setUpRows() {
        orientation = .vertical
        alignment = .leading
        spacing = mode == .reference ? 10 : 14
        translatesAutoresizingMaskIntoConstraints = false
        // Built from the item list, not from a scan: the scan is off-main and
        // has not landed yet on the frame this runs in.
        for (index, item) in Prerequisites.Item.allCases.enumerated() {
            addArrangedSubview(prerequisiteRow(item, step: index + 1))
        }
        // The SETUP tab gets a restart door and onboarding does not.
        //
        // Onboarding already has one, offered at the single moment it is the
        // next action. This pane is the OTHER moment: you came back here
        // deliberately, after granting something in System Settings or
        // rotating a key, and the thing you are missing is the relaunch that
        // makes a running process see it. Ruled 1 Sep, and it is why the row
        // is unconditional here: a door you can only find when the app already
        // agrees you need it is a door for a state the app can detect, and
        // this one it cannot.
        guard mode == .reference else { return }
        addArrangedSubview(restartRow())
    }

    /// The relaunch door, in the pane where you go looking for it.
    private func restartRow() -> NSView {
        let button = ConsoleButton.door("Restart Tranquility Base",
                                        ink: StateLegend.Palette.working,
                                        target: self, action: #selector(restartTapped))
        button.identifier = NSUserInterfaceItemIdentifier("prereq.restart")
        let note = NSTextField(wrappingLabelWithString:
            "a permission granted while the app is running only reaches it after this")
        note.font = ChromeType.mono(ofSize: 11, weight: .regular)
        note.textColor = StateLegend.Palette.secondary
        note.drawsBackground = false
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let stacked = NSStackView(views: [button, note])
        stacked.orientation = .vertical
        stacked.alignment = .leading
        stacked.spacing = 2
        return stacked
    }

    @objc private func restartTapped() {
        AppRelaunch.restart(reason: "a restart asked for from Settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The lamp glyph, composed. Colour changes go through here rather than
    /// `textColor`, which an attributed string ignores.
    private static func paint(_ field: NSTextField, _ color: NSColor) {
        field.attributedStringValue = ChromeType.line(
            StateLegend.Glyph.dot,
            font: ChromeType.mono(ofSize: 11, weight: .regular), color: color)
    }

    /// How many prerequisite rows exist, for the launch drill. Counting the
    /// rows rather than exposing the dictionaries: the drill's question is
    /// "is the shared checklist really what this pane is showing", and a count
    /// answers it without handing anyone a way to mutate the state.
    var rowCountForSelfTest: Int { prereqRows.count }

    /// Whether the off-main scan has landed. The preview waits on this: the
    /// first frame of this view is always the pre-scan one, and a photograph of
    /// it shows rows that have not measured anything yet.
    var hasScannedForSelfTest: Bool { !prereqStates.isEmpty }

    /// Whether the SETUP tab's restart door is here. Rule 7: the panel's
    /// evidence is a drill, and this door exists precisely for a state the app
    /// cannot detect, so nothing else would ever notice it going missing.
    var hasRestartDoorForSelfTest: Bool {
        subviewTree(self).contains {
            ($0 as? NSButton)?.identifier?.rawValue == "prereq.restart"
        }
    }

    /// Every row's visible text, for the drill that asserts what is NOT said.
    var rowTextForSelfTest: String {
        subviewTree(self).compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: " ")
    }

    private func subviewTree(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { subviewTree($0) }
    }

    /// Kick a scan and paint whatever is already known. Both hosts call this
    /// when they appear.
    func refresh() {
        renderPrerequisites()
        scanPrerequisites()
    }

    /// The permission row's shape, with a different verb.
    ///
    /// Same lamp, same numbering, same door. To the person reading this there is
    /// one list of things that are not ready; that macOS owns four of them and
    /// Homebrew owns another is our problem, not theirs.
    func prerequisiteRow(_ item: Prerequisites.Item, step: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline

        // Composed, not just coloured. This view used to live in its own
        // window, where nothing checked; inside the panel the `chrome` drill
        // walks the tree and requires every MARK to carry a baseline offset,
        // because an uncomposed glyph sits a hair off the line that every
        // other mark in the app sits on. It caught this the first time the
        // pane rendered.
        let dot = NSTextField(labelWithString: StateLegend.Glyph.dot)
        dot.font = ChromeType.mono(ofSize: 11, weight: .regular)
        dot.drawsBackground = false
        Self.paint(dot, StateLegend.Palette.faint)
        prereqDots[item] = dot
        row.addArrangedSubview(dot)

        // The number is set at RENDER time, not here. `hooks` is hidden whenever
        // it is healthy, and a number baked in at build time counts a row the
        // user cannot see: the first look at this screen read "1. tmux, 3.
        // Anthropic, 4. ElevenLabs" and invited everyone to hunt for step 2.
        _ = step
        let name = NSTextField(labelWithString: item.title)
        name.font = ChromeType.mono(ofSize: 12, weight: .medium)
        name.textColor = StateLegend.Palette.ink
        name.drawsBackground = false
        name.translatesAutoresizingMaskIntoConstraints = false
        // The onboarding window is 640pt wide and the panel is 352. One row
        // cannot use one set of fixed widths in both, and trying shipped a
        // SETUP tab whose doors were simply off the right edge, twice: 268 +
        // 205 + a button is about 500pt of content in a 352pt panel, and a
        // leading-aligned stack puts the overflow where nobody can see it.
        //
        // So the narrow host gets a taller row instead of a clipped one: the
        // name and its door on the first line, the detail wrapping underneath.
        // Nothing is hidden and nothing is truncated, which is the property
        // that matters on a screen whose whole job is telling you the state.
        name.widthAnchor.constraint(
            equalToConstant: mode == .reference ? 150 : 268).isActive = true
        prereqNames[item] = name
        row.addArrangedSubview(name)
        prereqRows[item] = row

        let detail = NSTextField(wrappingLabelWithString: item.why)
        detail.font = ChromeType.mono(ofSize: 11, weight: .regular)
        detail.textColor = StateLegend.Palette.secondary
        detail.drawsBackground = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.widthAnchor.constraint(
            equalToConstant: mode == .reference ? 300 : 205).isActive = true
        prereqDetails[item] = detail

        let button = ConsoleButton.door(item.fixLabel, ink: StateLegend.Palette.fault,
                                        target: self, action: #selector(fixTapped(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("prereq." + item.rawValue)
        prereqButtons[item] = button

        guard mode == .reference else {
            row.addArrangedSubview(detail)
            row.addArrangedSubview(button)
            return row
        }
        // Narrow host: name and door on the line, detail beneath it.
        row.addArrangedSubview(button)
        // Indented to sit under the NAME, not under the lamp: the detail
        // belongs to the row above it, and a second line starting at the panel
        // edge reads as a new item.
        let indent = NSStackView(views: [detail])
        indent.orientation = .horizontal
        indent.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)

        let stacked = NSStackView(views: [row, indent])
        stacked.orientation = .vertical
        stacked.alignment = .leading
        stacked.spacing = 2
        prereqRows[item] = stacked
        return stacked
    }

    /// Every row carries its own fix. None of them points at a document.
    @objc private func fixTapped(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        guard raw.hasPrefix("prereq."),
              let item = Prerequisites.Item(rawValue: String(raw.dropFirst(7)))
        else { return }

        switch item {
        case .tmux:
            // The clipboard, not a subprocess. Installing software into
            // somebody's machine unasked is not a thing a setup window gets to
            // do, and `brew` may not be there either -- in which case the pasted
            // command reports that far better than we could.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install tmux", forType: .string)
            prereqNote[item] = "copied. Paste it in a terminal"
            renderPrerequisites()

        case .hooks:
            // Off-main: this parses and rewrites a file (rule 9).
            prereqNote[item] = "wiring..."
            renderPrerequisites()
            Task.detached {
                // Every harness on this machine, so one press wires Claude Code
                // and Codex alike. Before 28 Aug this repaired one hardcoded
                // file and the row read "already wired" on a machine whose
                // Codex sessions had never had a hook.
                let outcomes = HookManifest.repairAll()
                // Wiring is half the job on a harness with a review gate, and
                // the half the user cannot see. Codex declines unreviewed
                // hooks in silence, so a button that stops at "wired" leaves
                // someone believing setup is done while nothing fires.
                //
                // Pressing that menu here is allowed for one reason and it is
                // worth stating: the user asked. `neverAutoAcceptNeedles`
                // still keeps the LAUNCH watcher off this screen, and that
                // rule is untouched. A launcher pressing a security prompt on
                // its own and a person clicking Approve in a setup window are
                // different acts; only the second carries consent.
                for (harness, _) in outcomes
                where HookManifest.approval(for: harness) == .pending {
                    await MainActor.run {
                        self.prereqNote[item] = "approving \(harness.label)..."
                        self.renderPrerequisites()
                    }
                    let outcome = CodexHookApproval.grantByDrivingCodex(
                        harness: harness,
                        command: AgentDefaults.load(for: harness.id),
                        directory: AgentDefaults.directory(for: harness.id),
                        trace: { Permissions.log($0) })
                    Permissions.log(
                        "onboarding: hook approval \(harness.id) -- \(outcome)")
                }
                await MainActor.run {
                    self.prereqNote[item] = Self.hookRepairNote(outcomes)
                    for (harness, outcome) in outcomes {
                        Permissions.log(
                            "onboarding: hook repair \(harness.id) -- \(outcome)")
                    }
                    self.renderPrerequisites()
                }
            }

        case .anthropicKey, .elevenLabsKey, .assemblyAIKey:
            promptForKey(item)
        }
    }


    /// One line for the checklist row, naming the harnesses it actually
    /// touched. "wired 5" on a two-harness machine cannot say which half moved,
    /// and the half that did not is exactly the failure this pass exists to
    /// close.
    static func hookRepairNote(
        _ outcomes: [(harness: HookManifest.Harness, outcome: HookManifest.RepairOutcome)]
    ) -> String {
        guard !outcomes.isEmpty else { return "no agent directories found" }
        var wired: [String] = [], failed: [String] = []
        for (harness, outcome) in outcomes {
            switch outcome {
            case .healthy: continue
            case .repaired(let rewired, let added):
                wired.append("\(harness.label) \(rewired + added)")
            case .unavailable(let reason):
                failed.append("\(harness.label): \(reason)")
            }
        }
        // BOTH halves, never just the broken one. Returning only the failures
        // is the same omission the row itself had: press Wire them on a machine
        // where Claude Code takes it and Codex does not, and the note reported
        // the Codex failure alone, so the repair that DID happen was invisible
        // at the exact moment somebody was watching for it. Ruled 1 Sep.
        if !failed.isEmpty {
            let worked = wired.map { "wired " + $0 }
            return (worked + failed).joined(separator: "; ")
        }
        // Writing the file is not the same as the harness agreeing to run it.
        // Codex asks once and fails silent until it is answered, so a row that
        // says "wired" and stops there sends someone away believing the setup
        // is done. Whatever is still owed is said here, in Core's words.
        let owed = outcomes.compactMap { HookManifest.nextStep(for: $0.harness) }
        if !owed.isEmpty { return owed.joined(separator: " Also: ") }
        if wired.isEmpty {
            return "already wired ("
                + outcomes.map(\.harness.label).joined(separator: ", ") + ")"
        }
        return "wired " + wired.joined(separator: ", ") + ". Restart your sessions"
    }

    /// The shared sheet. Onboarding and the menu must offer the same thing:
    /// a key you can only set during first run is a key you cannot rotate.
    private func promptForKey(_ item: Prerequisites.Item) {
        guard let secret = item.secret else { return }
        KeySheet.prompt(for: secret) { [weak self] status in
            guard let self else { return }
            self.prereqNote[item] = status
            self.renderPrerequisites()
        }
    }

    /// Re-read the dependencies off the main actor.
    ///
    /// Rule 9. A hooks audit parses a file, a keychain read is a round trip, and
    /// the tmux probe's uncached path can spawn a login shell that has taken
    /// seconds. None of that may sit on a 1 Hz timer. Single-flighted, because a
    /// slow scan on a repeating timer must not stack.
    func scanPrerequisites() {
        guard !prereqScanInFlight else { return }
        prereqScanInFlight = true
        let demo = ProcessInfo.processInfo.environment["TB_PREREQ_DEMO"] != nil
        Task.detached {
            // The state a NEW user sees is the one worth looking at, and it is
            // the one a developer machine can never show: tmux is installed and
            // the keys are in the login keychain, which `bundle-test.sh --reset`
            // rightly does not touch (they are the real ones). Rather than
            // delete somebody's credentials to photograph a screen, inject a
            // snapshot where nothing is present. Reads nothing, writes nothing.
            let states = demo
                ? Prerequisites.snapshot(Prerequisites.Probes(
                    tmuxPath: { nil },
                    // The LONGEST true detail this row can carry, not the
                    // shortest. A shipped install's failure text is a path
                    // (`scripts missing at /Applications/Tranquility
                    // Base.app/Contents/Resources/hooks`), it wraps to six
                    // lines in the onboarding window, and those six lines are
                    // what pushed the Start door off the bottom edge on 1 Sep.
                    // A demo that photographs the short message photographs the
                    // case that never broke.
                    // A MIXED machine, which is the state worth photographing
                    // and the one a developer's Mac never shows: one harness
                    // wired, one not. Both-broken and both-fine each have an
                    // obvious rendering; the half-and-half is where a single
                    // row and a single lamp used to lose the good news.
                    hooksProblem: {
                        "hooks: Codex: scripts missing at /Applications/"
                        + "Tranquility Base.app/Contents/Resources/hooks"
                    },
                    hasSecret: { _ in false },
                    hooksDetail: {
                        "Claude Code wired; Codex: scripts missing at "
                        + "/Applications/Tranquility Base.app/Contents/"
                        + "Resources/hooks"
                    }))
                : Prerequisites.snapshot()
            await MainActor.run {
                self.prereqScanInFlight = false
                guard states != self.prereqStates else { return }
                // A row that changed has superseded whatever its own button last
                // said, so the transient note goes.
                for state in states where !self.prereqStates.contains(state) {
                    self.prereqNote[state.item] = nil
                }
                self.prereqStates = states
                self.renderPrerequisites()
            }
        }
    }

    func renderPrerequisites() {
        // Before the first scan lands there are no states, and hiding every
        // row on that frame is why the pane photographed as a single line:
        // the scan is off-main by design, so the first paint always happens
        // without it. An empty list is not "nothing to show", it is "not
        // measured yet", and the rows can carry their own static text until
        // it is. Same distinction the rest of this app makes between `gone`
        // and `unknown`.
        guard !prereqStates.isEmpty else {
            for (_, row) in prereqRows { row.isHidden = false }
            return
        }
        let shownStates = mode == .reference
            ? prereqStates : Prerequisites.visible(prereqStates)
        let visible = Set(shownStates.map(\.item))
        // Hiding the ROW, not its contents. Hiding the labels individually left
        // the row in the stack at zero height but still carrying the stack's
        // spacing, so a hidden hooks row showed up as an unexplained gap.
        // NSStackView collapses a hidden arranged subview; it cannot collapse a
        // visible one full of hidden labels.
        for (item, row) in prereqRows { row.isHidden = !visible.contains(item) }

        // Numbered over what is actually on screen, so the sequence never skips.
        let position = Dictionary(uniqueKeysWithValues:
            shownStates.enumerated().map { ($0.element.item, $0.offset + 1) })

        for state in shownStates {
            let item = state.item
            // A NAME, and nothing else. The "(recommended)" suffix that used to
            // ride this line is gone (1 Sep): see `Item.isRecommended`. It had
            // already cost two layout passes chasing somewhere to put it, which
            // is usually the sign that a thing does not belong on the row.
            prereqNames[item]?.stringValue =
                "\(position[item] ?? 1). " + item.title
            // A satisfied tmux or hooks row has nothing left to do; a key row
            // keeps its door, because a key is a thing you rotate.
            prereqButtons[item]?.isHidden =
                mode != .reference && state.satisfied && item.secret == nil

            // The panel's lamp vocabulary, same meanings as stage one. Amber is
            // "needs action", so an unmet REQUIRED row is amber. An unmet key is
            // not amber: it is not waiting on anybody, and colouring it the same
            // as a blocker is how "optional" stops meaning anything.
            if let dot = prereqDots[item] {
                // Three states, not two. Green is satisfied. Amber is "this is
                // yours to fix now", which covers an unmet REQUIRED row and
                // also a stored key the provider refused, and the second one is
                // new: before 1 Sep a rejected key kept a green lamp because
                // the lamp only ever asked whether a key was stored. Grey stays
                // what it always meant, an optional row nobody has filled in,
                // which is not a problem and must not look like one.
                Self.paint(dot, state.satisfied
                    ? StateLegend.Palette.ready
                    : (item.isRequired || state.attention
                        ? StateLegend.Palette.fault
                        : StateLegend.Palette.faint))
            }
            prereqDetails[item]?.textColor = state.satisfied
                ? StateLegend.Palette.hint : StateLegend.Palette.secondary
            prereqDetails[item]?.stringValue = prereqNote[item] ?? state.detail
        }
        onReadiness?(!prereqStates.isEmpty
            && Prerequisites.allRequiredSatisfied(prereqStates))
    }

}
