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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Tranquility Base"
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

        stack.addArrangedSubview(label("Tranquility Base", size: 18, weight: .semibold))
        stack.addArrangedSubview(label(
            "When a coding session finishes: tap ⌃⌥ to hear what happened, hold ⌥ to "
            + "reply out loud (⌥⌥ locks hands-free), ⇧ pauses, ⌃⇧ dismisses.",
            size: 12, secondary: true, width: 420))

        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(label("Please do these first — in order. The app is not "
                                       + "usable until the required ones are done.",
                                       size: 12, weight: .medium, width: 420))
        let progress = label("", size: 11, secondary: true, width: 420)
        progressLabel = progress
        stack.addArrangedSubview(progress)

        for (index, kind) in Permissions.Kind.allCases.enumerated() {
            stack.addArrangedSubview(permissionRow(kind, step: index + 1))
        }

        stack.addArrangedSubview(spacer(8))
        let note = label(
            "macOS only lists an app in a Privacy pane after it has asked once, and "
            + "Grant is what does that ask. If a switch is off, flip it. Most rows go "
            + "green within a second; one that needs the app to restart says so, and "
            + "waits for the rest of the list before asking.",
            size: 11, secondary: true, width: 420)
        stack.addArrangedSubview(note)

        let restartNote = label("", size: 11, secondary: true, width: 420)
        restartNote.isHidden = true
        self.restartNote = restartNote
        stack.addArrangedSubview(restartNote)

        let restart = NSButton(title: "Restart Tranquility Base",
                               target: self, action: #selector(restartTapped))
        restart.bezelStyle = .rounded
        restart.isHidden = true
        restartButton = restart
        stack.addArrangedSubview(restart)

        let done = NSButton(title: "Start using Tranquility Base",
                            target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.isEnabled = false
        doneButton = done
        stack.addArrangedSubview(done)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
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
        row.spacing = 8
        row.alignment = .firstBaseline

        let dot = NSTextField(labelWithString: StateLegend.Glyph.dot)
        dot.font = .systemFont(ofSize: 12)
        rows[kind] = dot
        row.addArrangedSubview(dot)

        let name = NSTextField(labelWithString:
            "\(step). " + kind.title + (kind.isRequired ? "" : "  (optional)"))
        name.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabels[kind] = name
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: 190).isActive = true
        row.addArrangedSubview(name)

        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.widthAnchor.constraint(equalToConstant: 190).isActive = true
        details[kind] = detail
        row.addArrangedSubview(detail)

        let button = NSButton(title: "Grant", target: self, action: #selector(grantTapped(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
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
        }
    }

    @objc private func doneTapped() { window?.close() }

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
            rows[kind]?.textColor = {
                switch state {
                case .active: return .systemGreen
                case .pendingRestart: return .systemOrange
                case .restricted, .denied: return .systemRed
                case .notAsked: return kind.isRequired ? .tertiaryLabelColor
                                                       : .quaternaryLabelColor
                }
            }()
            details[kind]?.stringValue = Self.detail(kind, state)
            grantButtons[kind]?.isHidden = (state == .active || state == .pendingRestart)
            grantButtons[kind]?.title = state == .denied ? "Open Settings" : "Grant"

            // Dim what is not the user's business yet, and never dim the row
            // they are on or a row that still needs them.
            let live = (kind == current) || state != .active
            nameLabels[kind]?.alphaValue = live ? 1.0 : 0.45
            details[kind]?.alphaValue = live ? 1.0 : 0.45
        }

        let (done, total) = Permissions.progress
        progressLabel?.stringValue = "\(done) of \(total) done"

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
            let subject = "\(names) \(pending.count == 1 ? "is" : "are") granted, but macOS "
                + "only hands it to an app that starts up with it."
            restartNote?.stringValue = readyToRestart
                ? subject + " That is the last step — one restart and you are done."
                : subject + " Finish the rest of the list first; one restart at the "
                          + "end picks up everything at once."
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
        case .pendingRestart: return "granted — restart to finish"
        case .denied: return "denied earlier. Switch it on in Settings"
        case .restricted: return "restricted by policy"
        case .notAsked: return "not done yet. Click Grant"
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
                               size: NSSize(width: max(stackSize.width, 500),
                                            height: max(stackSize.height, 360)))
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
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
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
