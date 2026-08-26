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

    func show(onDone: @escaping () -> Void) {
        self.onDone = onDone
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 430),
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
        window.contentView = buildContent()
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
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
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

        let done = door("Start using Tranquility Base", ink: StateLegend.Palette.ready,
                        action: #selector(doneTapped))
        done.keyEquivalent = "\r"
        done.isEnabled = false
        doneButton = done
        stack.addArrangedSubview(done)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 430))
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

        let name = NSTextField(labelWithString:
            "\(step). " + kind.title + (kind.isRequired ? "" : "  (optional)"))
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
        let states = Permissions.Kind.allCases.map { ($0, Permissions.state($0)) }

        // The one step to do NOW is the first that is not finished. Everything
        // after it is dimmed: a checklist that shouts every line at once is the
        // thing the user said was unclear.
        let current = states.first { $0.1 != .active }?.0

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
                case .denied, .notAsked: return StateLegend.Palette.fault
                }
            }()
            details[kind]?.textColor = state == .active
                ? StateLegend.Palette.hint : StateLegend.Palette.secondary
            details[kind]?.stringValue = Self.detail(kind, state)
            grantButtons[kind]?.isHidden = (state == .active || state == .pendingRestart)
            if let button = grantButtons[kind] as? ConsoleButton {
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
        let pending = Permissions.pendingRestart
        let everythingElseDone = states.allSatisfy { $0.1 == .active || $0.1 == .pendingRestart }
        let readyToRestart = !pending.isEmpty && everythingElseDone
        restartNote?.isHidden = pending.isEmpty
        restartButton?.isHidden = !readyToRestart
        if !pending.isEmpty {
            let names = pending.map(\.title).joined(separator: " and ")
            restartNote?.stringValue = readyToRestart
                ? "Last step: restart, and \(names) comes with you."
                : "\(names) needs a restart. Finish the list first, then restart once."
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

        // Auto-close only when literally everything is finished — including the
        // optional row, and including anything that would need a restart.
        if states.allSatisfy({ $0.1 == .active }), let window {
            window.close()
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
