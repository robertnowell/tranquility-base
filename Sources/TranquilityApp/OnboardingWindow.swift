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
        stack.addArrangedSubview(label("Permissions — each row updates the moment you grant it:",
                                       size: 12, weight: .medium))

        for kind in Permissions.Kind.allCases {
            stack.addArrangedSubview(permissionRow(kind))
        }

        stack.addArrangedSubview(spacer(8))
        let note = label(
            "macOS only lists an app in a Privacy pane after it has asked once — "
            + "Grant does that ask. If a switch is off, flip it; the dot goes green "
            + "within a second.",
            size: 11, secondary: true, width: 420)
        stack.addArrangedSubview(note)

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
    private func permissionRow(_ kind: Permissions.Kind) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline

        let dot = NSTextField(labelWithString: StateLegend.Glyph.dot)
        dot.font = .systemFont(ofSize: 12)
        rows[kind] = dot
        row.addArrangedSubview(dot)

        let name = NSTextField(labelWithString: kind.title + (kind.isRequired ? "" : "  (optional)"))
        name.font = .systemFont(ofSize: 12, weight: .medium)
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

    private func refresh() {
        for (kind, dot) in rows {
            let granted = Permissions.isGranted(kind)
            dot.textColor = granted ? .systemGreen
                : (kind.isRequired ? .tertiaryLabelColor : .quaternaryLabelColor)
            details[kind]?.stringValue = Permissions.statusDescription(kind)
            grantButtons[kind]?.isHidden = granted
        }
        // The required set completes the checklist; the optional row never holds
        // the app hostage. Auto-close only when literally everything is green.
        doneButton?.isEnabled = Permissions.allGranted
        Permissions.log("onboarding: " + Permissions.Kind.allCases
            .map { "\($0.title.prefix(4))=\(Permissions.isGranted($0))" }
            .joined(separator: " "))
        if Permissions.Kind.allCases.allSatisfy({ Permissions.isGranted($0) }), let window {
            window.close()
        }
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
