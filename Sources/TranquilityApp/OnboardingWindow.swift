import AppKit
import TranquilityCore

/// A real window for first run.
///
/// The menu bar cannot be relied on for this. On a full menu bar macOS silently
/// drops status items with no room, so a menu-bar-only app can be running perfectly
/// and be completely invisible — which is indistinguishable from broken. First run
/// therefore puts a window on screen and walks through what is missing.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var rows: [Permissions.Kind: NSTextField] = [:]
    private var details: [Permissions.Kind: NSTextField] = [:]
    private var grantButtons: [Permissions.Kind: NSButton] = [:]
    private var doneButton: NSButton?
    private var restartButton: NSButton?
    private var progressLabel: NSTextField?
    private var restartNote: NSTextField?
    private var nameLabels: [Permissions.Kind: NSTextField] = [:]
    private var refreshTimer: Timer?
    private var onDone: (() -> Void)?

    /// Two screens, in the order the work actually happens.
    ///
    /// Permissions first, because until macOS has answered nothing else can be
    /// tried. Then, and only then, what the loop runs on. Ruled 26 Aug: "after
    /// permissions you move on, you hit next, and it checks your tmux and your
    /// API keys." One long list would have put five optional-looking rows under
    /// four blocking ones and asked the user to work out which was which.
    private enum Stage { case permissions, prerequisites }
    private var stage: Stage = .permissions

    // Stage two.
    private var prereqDots: [Prerequisites.Item: NSTextField] = [:]
    private var prereqNames: [Prerequisites.Item: NSTextField] = [:]
    private var prereqDetails: [Prerequisites.Item: NSTextField] = [:]
    private var prereqButtons: [Prerequisites.Item: ConsoleButton] = [:]
    private var prereqRows: [Prerequisites.Item: NSView] = [:]
    private var prereqProgress: NSTextField?
    private var startButton: ConsoleButton?
    /// Last computed off-main. Empty until the first scan lands, which is why the
    /// rows render from it rather than probing inline.
    private var prereqStates: [Prerequisites.State] = []
    private var prereqScanInFlight = false
    /// Set by a fix button to say what just happened; cleared by the next scan.
    private var prereqNote: [Prerequisites.Item: String] = [:]

    func show(onDone: @escaping () -> Void) {
        self.onDone = onDone
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 446),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // The first thing anyone sees of this app must look like this app.
        // Ruled 26 Aug: the stock-AppKit checklist "has a completely different
        // colour scheme from the rest of the app", which on a first impression
        // is the whole impression. Same ground, same face, same ink ramp as the
        // panel — `StateLegend.Palette` and `ChromeType`, not system defaults.
        window.title = "Tranquility Base"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = StateLegend.Palette.surface
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Stage two is otherwise reachable only by finishing four TCC grants and
        // a restart, which makes the screen most likely to be wrong the screen
        // hardest to look at. Same reasoning as Clicky's reset-to-first-run
        // button: a first run you cannot replay is a first run nobody checks.
        if CommandLine.arguments.contains("--show-prerequisites") {
            stage = .prerequisites
        }
        window.contentView = stage == .permissions
            ? buildContent() : buildPrerequisitesContent()
        self.window = window

        // The app is an accessory (no dock icon), so it must be activated explicitly
        // or the window opens behind whatever the user is looking at.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The gate half of "please do these things first".
    ///
    /// Dismissing the checklist with the microphone or the hotkeys still missing
    /// leaves an app that looks running and answers nothing — the failure the
    /// first external user hit from the other direction. So the window declines
    /// to close until the required rows are active, and says why rather than
    /// just ignoring the click.
    ///
    /// The optional row (Speech Recognition) never holds the gate: the app works
    /// without it, and a blocker on a permission that does not block is exactly
    /// the mistake ruled against on 10 Aug.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Stage two has its own required set, and permissions are behind it.
        if stage == .prerequisites {
            if Prerequisites.allRequiredSatisfied(prereqStates) { return true }
            Permissions.log("onboarding: close refused — prerequisites unfinished")
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "tmux is still missing"
            alert.informativeText =
                "Replies are typed into a session through tmux, so without it "
                + "Tranquility Base can announce a turn and then has nowhere to "
                + "put your answer. The row has the command, one paste."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: sender) { _ in }
            return false
        }
        if Permissions.allActive { return true }
        Permissions.log("onboarding: close refused — required set unfinished")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "A couple of things still to do"
        let (done, total) = Permissions.progress
        alert.informativeText =
            "\(done) of \(total) done. Tranquility Base cannot hear you or see the "
            + "hotkeys until the required rows are green, so this stays up until "
            + "they are. It takes about a minute."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: sender) { _ in }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window = nil
        // Back to menu-bar-only once the user is done here.
        NSApp.setActivationPolicy(.accessory)
        onDone?()
    }

    // MARK: - Content

    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        // Top clearance for the traffic lights, not just the corner radius.
        // `fullSizeContentView` + a transparent title bar means our content's
        // top edge IS the window's top edge, and the close button sits
        // there too (`.closable`, `windowShouldClose`'s own gate). 24pt put
        // the wordmark almost directly under the lights, reported live 26
        // Aug ("the TRANQUILITY BASE text looks janky against the traffic
        // light [buttons]"). 40pt clears the standard ~28pt titlebar band
        // with room to spare.
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(wordmark())

        // What the app IS, before anything about how to drive it. The controls
        // note that used to open this window is the LAST thing in onboarding,
        // not the first: nobody needs the chord vocabulary before they have
        // decided the thing is worth setting up.
        stack.addArrangedSubview(label(
            "Manage a team of coding agents with your voice and two keys.",
            size: 15, weight: .medium, width: 560))

        // Every mark is named. Ruled 26 Aug, and already half-written at
        // `StateLegend.controlsNote`: a bare glyph is a shape most people
        // cannot say out loud, and a key you cannot name is a key you cannot
        // press. The mark earns its place by sitting NEXT TO the word, never
        // instead of it.
        stack.addArrangedSubview(keycaps())

        stack.addArrangedSubview(spacer(10))
        let progress = sectionLabel("")
        progressLabel = progress
        stack.addArrangedSubview(progress)

        for (index, kind) in Permissions.Kind.allCases.enumerated() {
            stack.addArrangedSubview(permissionRow(kind, step: index + 1))
        }

        stack.addArrangedSubview(spacer(8))
        // No standing note at all.
        //
        // It said "Grant is what makes macOS ask, until an app has asked it is
        // not listed in the Privacy pane at all", which is a true fact about
        // TCC and an unreadable sentence, and it was explaining a mechanism
        // nobody on this screen has asked about. The rows say what to do and
        // the doors say how. Ruled 26 Aug: delete it.

        let restartNote = label("", size: 11, secondary: true, width: 560)
        restartNote.isHidden = true
        self.restartNote = restartNote
        stack.addArrangedSubview(restartNote)

        let restart = door("Restart Tranquility Base", ink: StateLegend.Palette.fault,
                           action: #selector(restartTapped))
        restart.isHidden = true
        restartButton = restart
        stack.addArrangedSubview(restart)

        // "Next", not "Start". The permissions being green is not the app being
        // ready, and a door that says Start here would be the second lie this
        // screen used to tell (the first was closing itself while tmux was
        // missing). Stage two carries the Start door.
        let done = door("Next", ink: StateLegend.Palette.ready,
                        action: #selector(nextTapped))
        done.keyEquivalent = "\r"
        done.isEnabled = false
        doneButton = done
        stack.addArrangedSubview(done)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 446))
        container.wantsLayer = true
        container.layer?.backgroundColor = StateLegend.Palette.surface.cgColor
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    /// Clicky's checklist shape: a status dot, the name and why, live state text,
    /// and a Grant button that disappears once its job is done. The button's
    /// behaviour is two-state — request when never asked (which also registers the
    /// app in the pane), deep-link to the exact pane when previously denied — so it
    /// never sends anyone hunting through Settings.
    private func permissionRow(_ kind: Permissions.Kind, step: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline

        let dot = NSTextField(labelWithString: StateLegend.Glyph.dot)
        dot.font = ChromeType.mono(ofSize: 11, weight: .regular)
        dot.drawsBackground = false
        rows[kind] = dot
        row.addArrangedSubview(dot)

        // No suffix, because there is no second class of row any more.
        //
        // This label went "(optional)" → "(fallback)" → nothing, and each step
        // was the same complaint getting sharper. 26 Aug, first: "that's not
        // optional, that's a critical fallback, why are we calling that
        // optional?" Then, later the same day, on the replacement: "we either
        // need them or we don't" — and we do, so every row is required and
        // there is nothing left to qualify. A parenthesis that quietly tells
        // the reader a step is skippable is how one of them ended up with no
        // row at all.
        let name = NSTextField(labelWithString: "\(step). " + kind.title)
        name.font = ChromeType.mono(ofSize: 12, weight: .medium)
        name.textColor = StateLegend.Palette.ink
        name.drawsBackground = false
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 250).isActive = true
        nameLabels[kind] = name
        row.addArrangedSubview(name)

        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = ChromeType.mono(ofSize: 11, weight: .regular)
        detail.textColor = StateLegend.Palette.hint
        detail.drawsBackground = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.widthAnchor.constraint(equalToConstant: 215).isActive = true
        details[kind] = detail
        row.addArrangedSubview(detail)

        // The door wears the same colour as the lamp beside it, because it IS
        // the action that lamp is asking for. Accent blue-grey made the one
        // thing you are supposed to press the quietest thing in the row.
        let button = door("Grant", ink: StateLegend.Palette.fault,
                          action: #selector(grantTapped(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(kind.title)
        grantButtons[kind] = button
        row.addArrangedSubview(button)

        return row
    }

    @objc private func grantTapped(_ sender: NSButton) {
        guard let kind = Permissions.Kind.allCases
            .first(where: { $0.title == sender.identifier?.rawValue }) else { return }
        Task { @MainActor in
            // Ask first — this both prompts when undetermined and, crucially,
            // registers the app in the Settings pane so it can be toggled at all.
            if await Permissions.request(kind) { refresh(); return }
            Permissions.openSettings(for: kind)
            refresh()
        }
    }

    @objc private func doneTapped() { window?.close() }

    // MARK: - Stage two: what the loop runs on

    @objc private func nextTapped() {
        stage = .prerequisites
        prereqStates = []
        window?.contentView = buildPrerequisitesContent()
        Permissions.log("onboarding: advanced to prerequisites")
        refresh()
    }

    private func buildPrerequisitesContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(wordmark())
        stack.addArrangedSubview(label(
            "macOS is done asking. These are the parts that are not its to give.",
            size: 15, weight: .medium, width: 560))

        stack.addArrangedSubview(spacer(10))
        let progress = sectionLabel("STEP 2 OF 2 \u{00B7} WHAT IT RUNS ON")
        prereqProgress = progress
        stack.addArrangedSubview(progress)

        // Built from the item list, not from a scan: the scan is off-main and
        // has not landed yet on the frame this runs in. `hooks` is in the list
        // and hidden below whenever it is healthy, which is almost always.
        for (index, item) in Prerequisites.Item.allCases.enumerated() {
            stack.addArrangedSubview(prerequisiteRow(item, step: index + 1))
        }

        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(label(
            "The keys are optional and the app runs without them. Anthropic is the "
            + "one worth having: it is what turns a finished turn into a sentence "
            + "worth hearing, at about a tenth of a cent each.",
            size: 11, secondary: true, width: 560))

        let start = door("Start using Tranquility Base", ink: StateLegend.Palette.ready,
                         action: #selector(doneTapped))
        start.keyEquivalent = "\r"
        start.isEnabled = false
        startButton = start
        stack.addArrangedSubview(start)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 446))
        container.wantsLayer = true
        container.layer?.backgroundColor = StateLegend.Palette.surface.cgColor
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    /// The permission row's shape, with a different verb.
    ///
    /// Same lamp, same numbering, same door. To the person reading this there is
    /// one list of things that are not ready; that macOS owns four of them and
    /// Homebrew owns another is our problem, not theirs.
    private func prerequisiteRow(_ item: Prerequisites.Item, step: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline

        let dot = NSTextField(labelWithString: StateLegend.Glyph.dot)
        dot.font = ChromeType.mono(ofSize: 11, weight: .regular)
        dot.drawsBackground = false
        prereqDots[item] = dot
        row.addArrangedSubview(dot)

        // "recommended", never "(optional)". Same ruling as the permission
        // screen's "(fallback)": a word that undermines a row is worse than no
        // word, and these rows have to survive being skimmed by someone who has
        // already spent a minute on permissions.
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
        name.widthAnchor.constraint(equalToConstant: 215).isActive = true
        prereqNames[item] = name
        row.addArrangedSubview(name)
        prereqRows[item] = row

        let detail = NSTextField(wrappingLabelWithString: item.why)
        detail.font = ChromeType.mono(ofSize: 11, weight: .regular)
        detail.textColor = StateLegend.Palette.secondary
        detail.drawsBackground = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.widthAnchor.constraint(equalToConstant: 205).isActive = true
        prereqDetails[item] = detail
        row.addArrangedSubview(detail)

        let button = door(item.fixLabel, ink: StateLegend.Palette.fault,
                          action: #selector(fixTapped(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("prereq." + item.rawValue)
        prereqButtons[item] = button
        row.addArrangedSubview(button)

        return row
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
        if !failed.isEmpty { return failed.joined(separator: "; ") }
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
    private func scanPrerequisites() {
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
                    hooksProblem: { "hooks: 2 not installed" },
                    hasSecret: { _ in false }))
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

    private func renderPrerequisites() {
        let shownStates = Prerequisites.visible(prereqStates)
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
            let suffix = item.isRecommended ? "  (recommended)" : ""
            prereqNames[item]?.stringValue =
                "\(position[item] ?? 1). " + item.title + suffix
            // A satisfied tmux or hooks row has nothing left to do; a key row
            // keeps its door, because a key is a thing you rotate.
            prereqButtons[item]?.isHidden = state.satisfied && item.secret == nil

            // The panel's lamp vocabulary, same meanings as stage one. Amber is
            // "needs action", so an unmet REQUIRED row is amber. An unmet key is
            // not amber: it is not waiting on anybody, and colouring it the same
            // as a blocker is how "optional" stops meaning anything.
            prereqDots[item]?.textColor = state.satisfied
                ? StateLegend.Palette.ready
                : (item.isRequired ? StateLegend.Palette.fault : StateLegend.Palette.faint)
            prereqDetails[item]?.textColor = state.satisfied
                ? StateLegend.Palette.hint : StateLegend.Palette.secondary
            prereqDetails[item]?.stringValue = prereqNote[item] ?? state.detail
        }
        startButton?.isEnabled = !prereqStates.isEmpty
            && Prerequisites.allRequiredSatisfied(prereqStates)
    }

    // MARK: - Chrome

    /// The panel signs the top of this window the way it signs its own corner.
    private func wordmark() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        let font = ChromeType.mono(ofSize: 10, weight: .regular)
        field.attributedStringValue = ChromeType.line(
            "TRANQUILITY BASE", font: font,
            color: StateLegend.Palette.hint, tracking: 2.2)
        field.font = font
        field.drawsBackground = false
        return field
    }

    /// The two keys, each mark beside its name.
    private func keycaps() -> NSView {
        let font = ChromeType.mono(ofSize: 12, weight: .regular)
        let field = NSTextField(labelWithString: "")
        // Through the composer, for the same reason `Controls` goes through it:
        // a line that is nothing but marks beside words is the last place that
        // should be setting a plain string and hoping the glyphs sit straight.
        field.attributedStringValue = ChromeType.line(
            "⌃ Control     ⌥ Option", font: font,
            color: StateLegend.Palette.ink, tracking: 0.4)
        field.font = font
        field.drawsBackground = false
        return field
    }

    /// A quiet section rule, in the panel's smallest voice.
    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = ChromeType.mono(ofSize: 10, weight: .regular)
        field.textColor = StateLegend.Palette.hint
        field.drawsBackground = false
        return field
    }

    /// A door, not a bezel. The panel has no filled buttons anywhere; a chrome
    /// button here would be the same mistake as a light window.
    private func door(_ title: String, ink: NSColor, action: Selector) -> ConsoleButton {
        let button = ConsoleButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        let font = ChromeType.mono(ofSize: 11, weight: .medium)
        button.font = font
        button.reink = { [weak button] color in
            button?.attributedTitle = ChromeType.line(
                title + " ›", font: font, color: color)
        }
        button.restingInk = ink
        return button
    }

    /// One restart at the end, never one per permission — and the count is read
    /// from the system, never stored.
    ///
    /// Two decisions live in this function. First: a grant that needs a restart
    /// does not interrupt the run. The user finishes the whole list and restarts
    /// once, because a restart per permission means up to three of them, each
    /// one throwing the user back to a window they thought they had finished.
    /// One restart clears every pending row at once — that is what makes batching
    /// safe rather than merely nicer.
    ///
    /// Second: progress is `Permissions.progress`, which counts live TCC state.
    /// Nothing is written to disk and nothing is remembered across launches,
    /// because the system already remembers — so the app that comes back from
    /// the restart it just asked for opens saying "3 of 4 done" without having
    /// kept a note. A stored counter would be a second source of truth about
    /// something the first source already knows, and the two would drift the
    /// first time a user changed a switch in Settings while the app was closed.
    private func refresh() {
        switch stage {
        case .permissions: refreshPermissions()
        case .prerequisites: scanPrerequisites()
        }
    }

    private func refreshPermissions() {
        let states = Permissions.Kind.allCases.map { ($0, Permissions.state($0)) }

        // The one step to do NOW is the first that is not finished. Everything
        // after it is dimmed: a checklist that shouts every line at once is the
        // thing the user said was unclear.
        // `opensTheGate`, so a row the app merely could not READ is never
        // presented as the step you are on. It stays undimmed below — `live`
        // is true for anything that is not `active` — but it does not claim
        // to be what the checklist is waiting for, because it is not.
        let current = states.first { !Permissions.opensTheGate($0.1) }?.0

        for (kind, state) in states {
            // The panel's own lamp vocabulary, and one meaning per colour.
            //
            // AMBER IS "NEEDS ACTION", so every untouched row starts amber.
            // They were sockets, on the reasoning that an ungranted permission
            // is an unlit lamp. That reads as "nothing here" when the truth is
            // "all of this is waiting on you", which on a setup screen is the
            // one thing the colour must not say. Ruled 26 Aug.
            //
            // Green is done. Blue is underway with nothing to do, which is why
            // `pendingRestart` is blue and not amber: it is the batching
            // decision stated in colour rather than only in a note.
            //
            // `denied` is amber too. It needs action exactly as much as an
            // untouched row does; what differs is WHICH action, and the detail
            // and the door beside it already say so.
            rows[kind]?.textColor = {
                switch state {
                case .active: return StateLegend.Palette.ready
                case .pendingRestart: return StateLegend.Palette.working
                case .restricted: return StateLegend.Palette.faint
                // `stale` is amber, not blue. Blue means underway with nothing
                // for you to do, and a restart that already failed is the exact
                // opposite of that.
                case .denied, .notAsked, .stale: return StateLegend.Palette.fault
                // Faint, with `restricted`, and specifically NOT amber. Amber
                // is this window's word for "needs action", and there is no
                // action — nothing the user does to a toggle changes whether
                // the app can take the reading. Painting it amber is what put
                // an alarm colour on a permission that was already granted.
                case .unknowable: return StateLegend.Palette.faint
                }
            }()
            details[kind]?.textColor = state == .active
                ? StateLegend.Palette.hint : StateLegend.Palette.secondary
            details[kind]?.stringValue = Self.detail(kind, state)
            grantButtons[kind]?.isHidden = (state == .active || state == .pendingRestart)
            if let button = grantButtons[kind] as? ConsoleButton {
                // `stale` keeps the Grant label, and the note tells you to press
                // it by name. Briefly this said Open Settings on the reasoning
                // that Grant was the thing that had just failed. The note is
                // what carries the meaning here, and a note that says "click
                // Grant" beside a door that says something else is worse than a
                // door whose label is merely imprecise.
                let title = state == .denied ? "Open Settings" : "Grant"
                let font = ChromeType.mono(ofSize: 11, weight: .medium)
                button.reink = { [weak button] color in
                    button?.attributedTitle = ChromeType.line(
                        title + " ›", font: font, color: color)
                }
                button.restingInk = StateLegend.Palette.fault
            }

            // Dim what is not the user's business yet, and never dim the row
            // they are on or a row that still needs them.
            let live = (kind == current) || state != .active
            nameLabels[kind]?.alphaValue = live ? 1.0 : 0.45
            details[kind]?.alphaValue = live ? 1.0 : 0.45
        }

        let (done, total) = Permissions.progress
        progressLabel?.stringValue = "SETUP · \(done) OF \(total) DONE"

        // The restart is offered as an ACTION only when it is genuinely the next
        // one — every row either finished or waiting on the relaunch. Offering
        // it earlier is the batching decision arguing with itself: the note says
        // "finish the rest first" while a default-styled blue button says "press
        // me now", and the button wins. So before that point the note explains
        // the orange row and nothing invites a premature restart.
        // A row that already survived a restart is never offered another one.
        let staleRows = Permissions.stale
        let pending = Permissions.pendingRestart
        let everythingElseDone = states.allSatisfy {
            Permissions.opensTheGate($0.1) || $0.1 == .pendingRestart
        }
        let readyToRestart = !pending.isEmpty && everythingElseDone
        restartNote?.isHidden = pending.isEmpty && staleRows.isEmpty
        restartButton?.isHidden = !readyToRestart
        if !staleRows.isEmpty {
            // The sentence that ends the loop: what is wrong, then what to
            // press, in that order and nothing else.
            //
            // It used to carry a middle sentence explaining that macOS was
            // listing the app as allowed while not acting on it. True, and
            // ruled out on 28 Aug: "that doesn't make any sense." It described
            // the mechanism to someone who wants the fix, and the fix is three
            // clicks that the last sentence now names outright.
            let names = staleRows.map(\.title).joined(separator: " and ")
            let verb = staleRows.count == 1 ? "is" : "are"
            restartNote?.stringValue =
                "\(names) still \(verb) not working after a restart. "
                + Self.staleRemedy(staleRows)
            restartNote?.textColor = StateLegend.Palette.fault
        } else if !pending.isEmpty {
            let names = pending.map(\.title).joined(separator: " and ")
            restartNote?.stringValue = readyToRestart
                ? "Last step: restart, and \(names) comes with you."
                : "\(names) needs a restart. Finish the list first, then restart once."
            restartNote?.textColor = StateLegend.Palette.hint
        }

        // The required set completes the checklist; the optional row never holds
        // the app hostage. `allActive`, not `allGranted` — a row that is granted
        // but unusable must not open the gate.
        doneButton?.isEnabled = Permissions.allActive
        // Exactly one default button, and only when there is a right answer to
        // pressing Return.
        restartButton?.keyEquivalent = readyToRestart ? "\r" : ""
        doneButton?.keyEquivalent = (Permissions.allActive && !readyToRestart) ? "\r" : ""

        Permissions.log("onboarding: " + states
            .map { "\($0.0.title.prefix(4))=\($0.1)" }
            .joined(separator: " ") + " progress=\(done)/\(total)")

        // Deliberately does NOT auto-advance, where it used to auto-close.
        //
        // Closing itself was right when this was the whole of setup. It is wrong
        // now for two reasons: there is a second screen behind it that the user
        // has never seen, and skipping them past it silently is how tmux stayed
        // invisible in the first place. Advancing automatically would be its own
        // version of the same mistake, yanking the screen out from under someone
        // mid-grant. The Next door lights up; they press it.
    }

    /// What to actually DO about a row that survived a restart — which is not
    /// the same sentence for every row, and used to be.
    ///
    /// One string served all of them: "Click Grant, remove Tranquility Base
    /// with the minus button, and then add it back with plus." True for
    /// Accessibility and Input Monitoring, whose panes are hand-edited lists
    /// with a + and a − under them. False for Automation, reported 29 Aug:
    /// "there is no minus button here." There is not. That pane is a generated
    /// list of app-to-app pairs — nothing can be added to it by hand, and the
    /// only real reset is `tccutil`. An instruction naming a control that does
    /// not exist is worse than no instruction: it reads as the user's failure
    /// to find it.
    /// Not private: `permissionSurfacesDrill` pins the Automation sentence,
    /// because the thing that went wrong here was the WORDS, and words with no
    /// test are the part of a fix that quietly comes undone.
    static func staleRemedy(_ kinds: [Permissions.Kind]) -> String {
        // Mixed sets get the general door rather than a merged instruction that
        // is half wrong for each row. Grant is the one action every row has.
        guard kinds.count == 1, let kind = kinds.first else {
            return "Click Grant on each and follow what Settings shows."
        }
        switch kind {
        case .automation:
            return "Click Grant, then switch Terminal off and back on under "
                + "Tranquility Base. If that changes nothing, run "
                + "`tccutil reset AppleEvents com.robertnowell.voice-dispatch` "
                + "and grant it again — that pane has no minus button."
        case .accessibility, .inputMonitoring:
            return "Click Grant, remove Tranquility Base with the minus button, "
                + "and then add it back with plus."
        case .microphone, .speechRecognition:
            return "Click Grant, then switch Tranquility Base off and back on "
                + "in Settings."
        }
    }

    /// The live state text, in the user's terms rather than the API's.
    private static func detail(_ kind: Permissions.Kind, _ state: Permissions.State) -> String {
        switch state {
        case .active: return "done"
        case .pendingRestart: return "granted, restart to finish"
        case .denied: return "denied earlier"
        case .restricted: return "restricted by policy"
        case .notAsked: return "needs action"
        // Never "restart to finish" a second time. The restart is the thing
        // that just failed, and repeating it is what made this a loop.
        case .stale: return "restarted, still not working"
        // Says what is true and what would fix it, and blames neither the user
        // nor the permission. The app cannot see this one from here; opening a
        // terminal is what lets it look.
        case .unknowable: return "can't check while Terminal is closed"
        }
    }

    /// Relaunch, because the permission the user just granted only reaches a
    /// process that starts up holding it.
    ///
    /// The new instance is launched before this one exits and `stop()` runs on
    /// the way out, so the two never overlap on the global hotkey — two live
    /// instances racing for one chord is a failure this app has had before.
    @objc private func restartTapped() {
        let url = Bundle.main.bundleURL
        Permissions.log("onboarding: restarting to pick up "
                        + Permissions.pendingRestart.map(\.title).joined(separator: ","))
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // Without this, the new process's OWN single-instance guard
        // (main.swift's applicationDidFinishLaunching) sees THIS process
        // still alive at its own launch, reads it as an accidental double
        // launch, and refuses outright before showing anything -- found
        // live, 26 Aug: "I clicked restart and the app did not restart, it
        // just closed." The log confirmed it exactly: the new pid logged
        // `launch: REFUSED, instance already running (pid <this one>)`,
        // and this process then terminated a moment later per the
        // completion handler below, leaving nothing running. This restart
        // is a deliberate, sequenced handoff, not the accidental
        // double-launch that guard exists to catch, so it gets the same
        // exemption the self-test path already has.
        config.arguments = ["--allow-second-instance"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Render the checklist to a PNG without putting it on screen.
    ///
    /// A visual change to this window used to be reviewable only by launching
    /// the app and looking, which needs a second instance (the single-instance
    /// guard exists for good reason) and a screen-recording grant that a build
    /// machine or an agent does not have. Both of those are reasons to skip
    /// looking, and "measurements alone" is exactly how a spacing regression
    /// ships.
    ///
    /// `cacheDisplay(in:)` draws the real view tree through the real layout
    /// pass, in-process, so what lands in the file is what the window would
    /// show — not a mock of it.
    func writePreview(to path: String) {
        let content = buildContent()
        refresh()
        content.layoutSubtreeIfNeeded()
        let stackSize = content.subviews.first?.fittingSize ?? content.frame.size
        content.frame = NSRect(origin: .zero,
                               size: NSSize(width: max(stackSize.width, 640),
                                            height: max(stackSize.height, 430)))
        content.layoutSubtreeIfNeeded()

        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            Permissions.log("onboarding preview: could not make a bitmap rep")
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Permissions.log("onboarding preview: could not encode PNG")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        Permissions.log("onboarding preview: wrote \(path) "
                        + "\(Int(content.bounds.width))x\(Int(content.bounds.height))")
    }

    // MARK: - Helpers

    private func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
        secondary: Bool = false, width: CGFloat? = nil
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = ChromeType.mono(ofSize: size, weight: weight)
        field.textColor = secondary ? StateLegend.Palette.hint : StateLegend.Palette.ink
        field.drawsBackground = false
        field.isSelectable = false
        if let width {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return field
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}
