import AppKit
import VoiceDispatchCore

/// The floating panel in the top-right corner.
///
/// This is the actual interface. The menu bar was never enough — on a full menu bar
/// macOS silently drops status items, and even when visible it can't show which
/// session is talking or what was said. Without this the app is a voice with no face:
/// you hear something, and have no way to see what it was, which session it came
/// from, or how to get there.
///
/// Non-activating: it takes no focus from whatever you're working in, so it can
/// appear mid-typing without stealing a keystroke.
///
/// It never auto-hides. The first version dismissed the idle state after four
/// seconds, which meant the only evidence the app was alive flashed up and vanished
/// before anyone looked at it — indistinguishable, again, from the app being broken.
/// A status indicator that disappears is not a status indicator. It stays until
/// superseded by the next state or explicitly dismissed.
@MainActor
final class StatusHUD: NSObject {
    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var stateLabel: NSTextField!
    private var goButton: NSButton!
    private var replyButton: NSButton!
    private var hintLabel: NSTextField!
    /// Set by the app so the panel can start and stop a recording itself. Without
    /// this the only way to answer was a hotkey that appears nowhere in the UI —
    /// the panel asked a question and offered no way to answer it.
    var onReply: (() -> Void)?
    var onStopReply: (() -> Void)?
    private var isRecording = false
    private var hideWorkItem: DispatchWorkItem?
    private var contentStack: NSStackView?
    private var identity: String?

    private var currentTarget: (sessionId: String, pid: Int?, label: String)?

    // MARK: - Public surface

    func showListening() {
        show(state: "● Listening…", title: currentTarget?.label ?? "Voice Dispatch",
             body: "Speak your reply, then let go of ⌃⌥.", autoHideAfter: nil)
    }

    func showAnnouncement(topic: String, spoken: String, sessionId: String, pid: Int?, project: String) {
        currentTarget = (sessionId, pid, project)
        // Only prefix when the topic adds something. A topic equal to the project
        // rendered as "promotions — promotions", which names the folder twice and
        // tells you nothing.
        let headline = topic.caseInsensitiveCompare(project) == .orderedSame || topic.isEmpty
            ? project : "\(project) — \(topic)"
        identity = Self.identify(pid: pid)
        show(state: "◀ Speaking", title: headline, body: spoken, autoHideAfter: nil)
    }

    /// The concrete tab this is about: working directory and tty. Without it you
    /// cannot tell whether "Go to session" opened the right one — a project name is
    /// not an address, and several tabs share it.
    private static func identify(pid: Int?) -> String? {
        guard let pid else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "tty=,cwd="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let fields = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let tty = fields.first else { return nil }
        let dir = fields.count > 1
            ? String(fields[1]).replacingOccurrences(of: NSHomeDirectory(), with: "~") : ""
        return dir.isEmpty ? "tty \(tty)" : "\(dir) · tty \(tty)"
    }

    func showWorking(_ message: String) {
        show(state: "◌ Working", title: currentTarget?.label ?? "Voice Dispatch",
             body: message, autoHideAfter: nil)
    }

    func showResult(_ message: String, ok: Bool) {
        show(state: ok ? "▶ Sent" : "⚠ Needs you",
             title: currentTarget?.label ?? "Voice Dispatch",
             body: message, autoHideAfter: nil)
    }

    func showIdle(_ message: String) {
        show(state: "◌ Ready", title: "Voice Dispatch", body: message, autoHideAfter: nil)
    }

    func hide() {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
    }

    // MARK: - Rendering

    private func show(state: String, title: String, body: String, autoHideAfter: TimeInterval?) {
        Permissions.log("HUD.show state=\(state) title=\(title)")
        let panel = panel ?? build()
        stateLabel.stringValue = state
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        goButton.isHidden = currentTarget?.pid == nil
        replyButton.title = isRecording ? "Send reply" : "Reply"
        let action = isRecording
            ? "Listening — click Send, or let go of ⌃⌥."
            : "Click Reply, or hold ⌃⌥ to speak."
        hintLabel.stringValue = identity.map { "\($0)\n\(action)" } ?? action
        replyButton.isHidden = currentTarget == nil

        resizeToFit(panel)
        position(panel)
        panel.orderFrontRegardless()
        Permissions.log("HUD frame=\(panel.frame) visible=\(panel.isVisible) screen=\(NSScreen.main?.visibleFrame.debugDescription ?? "nil")")

        hideWorkItem?.cancel()
        if let autoHideAfter {
            let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: work)
        }
    }

    /// Grow the window to whatever the content needs.
    ///
    /// The first version pinned the panel at 150pt regardless of what was in it, so
    /// a long summary pushed the buttons off the bottom edge — the actions were
    /// literally unreachable. Never ship a fixed-height container around
    /// variable-length text.
    private func resizeToFit(_ panel: NSPanel) {
        guard let stack = contentStack else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize
        let height = max(needed.height, 90)
        if abs(panel.frame.height - height) > 1 {
            panel.setContentSize(NSSize(width: 380, height: height))
        }
        // Assert the actions are actually on screen. "Buttons cut off" is a bug the
        // code can check for itself; it should never reach a person's eyes.
        let buttonsFit = panel.contentView.map { $0.bounds.height + 0.5 >= needed.height } ?? false

        // Does the label actually show all of its text? Comparing the rendered
        // height to the text's natural height at this width is the only way to
        // see truncation from code — the panel happily fits a clipped label, so
        // the previous check passed while four lines of every summary were lost.
        let width = bodyLabel.bounds.width
        let natural = (bodyLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyLabel.font ?? .systemFont(ofSize: 12)]).height
        let textFits = bodyLabel.bounds.height + 1 >= natural

        Permissions.log(
            "HUD layout: needed=\(Int(needed.height)) frame=\(Int(panel.frame.height)) "
            + "buttonsFit=\(buttonsFit) textFits=\(textFits) "
            + "labelH=\(Int(bodyLabel.bounds.height)) naturalH=\(Int(natural))")
    }

    /// Shown the instant ⌃⌥ is tapped, so the gap before audio isn't dead air.
    /// Summarizing and fetching the voice take a few seconds; without this the app
    /// looks broken for the whole of it.
    func showPreparing() {
        show(state: "◌ Preparing", title: "Voice Dispatch",
             body: "Writing the summary and fetching the voice…", autoHideAfter: nil)
    }

    /// Render every state with worst-case text and confirm nothing is clipped.
    /// Run with `--selftest-hud`.
    func selfTest() {
        let long = String(repeating: "Product image binding is fixed across the stack. ", count: 8)
        currentTarget = ("selftest", 1, "promotions")
        for (label, block) in [
            ("idle", { self.showIdle(long) }),
            ("announcement", { self.showAnnouncement(
                topic: "Product image binding fix validation", spoken: long,
                sessionId: "s", pid: 1, project: "promotions") }),
            ("listening", { self.showListening() }),
            ("result", { self.showResult(long, ok: false) }),
        ] as [(String, () -> Void)] {
            Permissions.log("selftest state=\(label)")
            block()
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 16
        let size = panel.frame.size
        // Top-right, below the menu bar.
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - margin,
            y: screen.visibleFrame.maxY - size.height - margin)
        panel.setFrameOrigin(origin)
    }

    private func build() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            // .nonactivatingPanel is the key flag: the panel can show without the app
            // becoming frontmost, so it never steals a keystroke mid-sentence.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        stateLabel = NSTextField(labelWithString: "")
        stateLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .labelColor
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.isSelectable = true

        goButton = NSButton(title: "Go to session", target: self, action: #selector(goToSession))
        goButton.bezelStyle = .rounded
        goButton.controlSize = .small
        goButton.font = .systemFont(ofSize: 11)

        replyButton = NSButton(title: "Reply", target: self, action: #selector(replyTapped))
        replyButton.bezelStyle = .rounded
        replyButton.controlSize = .small
        replyButton.font = .systemFont(ofSize: 11)
        replyButton.keyEquivalent = "\r"

        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissTapped))
        dismiss.bezelStyle = .rounded
        dismiss.controlSize = .small
        dismiss.font = .systemFont(ofSize: 11)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor

        let buttons = NSStackView(views: [replyButton, goButton, dismiss])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        hintLabel.maximumNumberOfLines = 0
        let stack = NSStackView(views: [stateLabel, titleLabel, bodyLabel, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bodyLabel.widthAnchor.constraint(equalToConstant: 348),
        ])
        self.contentStack = stack

        panel.contentView = background
        self.panel = panel
        return panel
    }

    // MARK: - Actions

    /// Bring the originating terminal tab to the front.
    ///
    /// Same addressing chain the dispatcher uses — pid to tty to tab — so "go to
    /// session" lands on exactly the tab a reply would be typed into, rather than
    /// merely activating Terminal and leaving you to find it.
    @objc private func goToSession() {
        guard let pid = currentTarget?.pid else {
            bodyLabel.stringValue = "That session is no longer running, so there's no tab to open."
            return
        }
        guard let tty = ProcessProbe.tty(of: pid) else {
            bodyLabel.stringValue = "Couldn't find a terminal for process \(pid) — it may have exited."
            Permissions.log("goToSession: no tty for pid \(pid)")
            return
        }
        let script = """
            tell application "Terminal"
              activate
              repeat with w in windows
                repeat with t in tabs of w
                  if (tty of t) as text is "\(tty)" then
                    set selected tab of w to t
                    set index of w to 1
                    return "ok"
                  end if
                end repeat
              end repeat
              return "notfound"
            end tell
            """
        switch AppleScript.run(script: script) {
        case .success(let out) where out.contains("notfound"):
            bodyLabel.stringValue = "That session's tab isn't open in Terminal any more (\(tty))."
            Permissions.log("goToSession: tab not found for \(tty)")
        case .success:
            Permissions.log("goToSession: focused \(tty)")
        case .failure(let error):
            bodyLabel.stringValue = "Couldn't control Terminal: \(error.message)"
            Permissions.log("goToSession FAILED: \(error.message)")
        }
    }

    /// Advance the highlight to the character range currently being spoken.
    ///
    /// Everything up to the cursor is shown at full strength and the rest dimmed, so
    /// the eye can follow the voice without the jitter of a per-word box.
    func highlight(upTo index: Int) {
        guard let body = bodyLabel?.stringValue, !body.isEmpty else { return }
        let clamped = max(0, min(index, body.count))
        let attributed = NSMutableAttributedString(string: body)
        let full = NSRange(location: 0, length: (body as NSString).length)
        attributed.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: full)
        attributed.addAttribute(
            .foregroundColor, value: NSColor.labelColor,
            range: NSRange(location: 0, length: min(clamped, full.length)))
        attributed.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 12), range: full)
        bodyLabel.attributedStringValue = attributed
    }

    @objc private func replyTapped() {
        if isRecording { isRecording = false; onStopReply?() }
        else { isRecording = true; onReply?() }
        replyButton.title = isRecording ? "Send reply" : "Reply"
        let action = isRecording
            ? "Listening — click Send, or let go of ⌃⌥."
            : "Click Reply, or hold ⌃⌥ to speak."
        hintLabel.stringValue = identity.map { "\($0)\n\(action)" } ?? action
    }

    func recordingEnded() {
        isRecording = false
        replyButton?.title = "Reply"
    }

    @objc private func dismissTapped() { hide() }
}
