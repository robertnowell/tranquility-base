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
    private var awaitingConfirm = false
    private var isListening = false
    private var meterTimer: Timer?
    private var levelSource: (() -> Float)?
    private var listenStartedAt: Date?
    /// The event the panel is currently about, so Dismiss can retire it.
    private(set) var currentEventId: String?
    private var countdownTimer: Timer?
    private var onCancelSend: ((_ restartListening: Bool) -> Void)?
    private var progressBar: NSProgressIndicator!
    private var meter: LevelMeterView!
    private static let spokenMark = NSAttributedString.Key("vdSpoken")

    private var currentTarget: (sessionId: String, pid: Int?, label: String)?

    // MARK: - Public surface

    /// While you are talking, the panel's whole job is to prove it can hear you.
    ///
    /// It previously showed the same identity line, the same "hold ⌥ to speak" hint
    /// you were already obeying, and three buttons for actions unrelated to
    /// speaking. A live level meter answers the only question you actually have.
    func showListening(level: @escaping () -> Float) {
        isListening = true
        levelSource = level
        listenStartedAt = Date()
        show(state: "● Listening", title: "Replying to \(currentTarget?.label ?? "this session")",
             body: "", autoHideAfter: nil)
        meter.isHidden = false
        meter.reset()

        meterTimer?.invalidate()
        // 20Hz: fast enough that the waveform tracks syllables rather than words.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, self.isListening else { return timer.invalidate() }
            self.meter.push(CGFloat(Self.meterFraction(self.levelSource?() ?? 0)))
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    /// RMS for speech is small, so it is square-rooted and scaled. The old factor of
    /// 3.2 pinned the bar at full for ordinary talking, which reads as clipping and
    /// makes you drop your voice to compensate; 2.0 leaves normal speech around
    /// two-thirds and keeps headroom visible.
    nonisolated private static func meterFraction(_ level: Float) -> Double {
        min(1, sqrt(max(0, Double(level))) * 2.0)
    }

    func showAnnouncement(
        topic: String, spoken: String, sessionId: String, pid: Int?, project: String,
        cwd: String?, eventId: String? = nil
    ) {
        currentEventId = eventId
        currentTarget = (sessionId, pid, project)
        // Only prefix when the topic adds something. A topic equal to the project
        // rendered as "promotions — promotions", which names the folder twice and
        // tells you nothing.
        let headline = topic.caseInsensitiveCompare(project) == .orderedSame || topic.isEmpty
            ? project : "\(project): \(topic)"
        identity = Self.identify(pid: pid, cwd: cwd)
        show(state: "◀ Speaking", title: headline, body: spoken, autoHideAfter: nil)
    }

    /// The concrete tab this is about: working directory and tty. Without it you
    /// cannot tell whether "Go to session" opened the right one — a project name is
    /// not an address, and several tabs share it.
    private static func identify(pid: Int?, cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let parts = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }

        // Worktrees nest the real name under .claude/worktrees/<name>/<project>, so
        // the last component alone is ambiguous — every one of them ends in the same
        // project directory. The component before the plumbing is the one you named.
        if let marker = parts.firstIndex(of: "worktrees"), marker + 1 < parts.count {
            return "worktree: \(parts[marker + 1])"
        }
        return parts.suffix(2).joined(separator: "/")
    }

    /// The first reply to a session asks once, showing the words that are about to
    /// be typed and the tab they are going into. Approving here enrols it, so this
    /// appears once per session and never again.
    var onConfirmSend: (() -> Void)?

    /// Show what is about to be typed, and send it when the bar runs out.
    ///
    /// The bar is the whole design. A dialog asking permission taxes every correct
    /// transcript to catch the occasional wrong one; a countdown reverses that —
    /// doing nothing is doing the right thing, and stopping it costs one click on
    /// the rare occasion you need to.
    func showPendingSend(
        text: String, label: String, seconds: TimeInterval,
        send: @escaping () -> Void, cancel: @escaping (_ restartListening: Bool) -> Void
    ) {
        countdownTimer?.invalidate()
        onCancelSend = cancel
        awaitingConfirm = true
        show(state: "→ Sending to \(label)", title: "Your reply",
             body: "\u{201C}\(text)\u{201D}", autoHideAfter: nil)

        progressBar.isHidden = false
        progressBar.doubleValue = 0
        let started = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let elapsed = Date().timeIntervalSince(started)
            self.progressBar.doubleValue = min(elapsed / seconds, 1) * 100
            guard elapsed >= seconds else { return }
            timer.invalidate()
            self.countdownTimer = nil
            self.awaitingConfirm = false
            self.progressBar.isHidden = true
            send()
        }
        // .common so the countdown keeps running while a menu or drag is tracking —
        // otherwise it silently stalls and the reply never goes.
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    /// Stop a pending send. Safe to call when nothing is pending.
    ///
    /// `restartListening` is false when the caller is already starting a new
    /// recording of its own — holding ⌥ during the window is itself the instruction
    /// to say it again, so restarting from here as well would double-start.
    @discardableResult
    func cancelPendingSend(restartListening: Bool = true) -> Bool {
        guard awaitingConfirm else { return false }
        countdownTimer?.invalidate()
        countdownTimer = nil
        awaitingConfirm = false
        progressBar.isHidden = true
        let cancel = onCancelSend
        onCancelSend = nil
        cancel?(restartListening)
        return true
    }

    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func cancelPendingSendTapped() {
        MainActor.assumeIsolated { cancelPendingSend(restartListening: true) }
    }

    /// Reflect a pause without rebuilding the panel — the spoken text and its
    /// highlight must stay exactly where they are.
    func setPaused(_ paused: Bool) {
        stateLabel.stringValue = paused ? "❙❙ Paused" : "◀ Speaking"
        hintLabel.stringValue = paused
            ? "Tap ⇧ to carry on, or Dismiss to be done with it."
            : (identity.map { "\($0)\nTap ⇧ to pause, hold ⌥ to reply." }
                ?? "Tap ⇧ to pause, hold ⌥ to reply.")
    }

    /// Append a line to the current panel without disturbing what it is showing.
    func note(_ message: String) {
        hintLabel.stringValue = [message, hintLabel.stringValue]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if let panel { resizeToFit(panel); position(panel) }
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

    /// `note` is a prefix about what just happened ("Stopped."). The sentence about
    /// what is waiting is always derived from `waiting`, never passed in — the two
    /// were computed at different call sites and drifted, so the panel showed
    /// "2 waiting" directly above "Nothing waiting".
    func showIdle(note: String? = nil, waiting: Int, unsentReplies: Int = 0) {
        currentTarget = nil
        identity = nil
        currentEventId = nil

        let status = waiting > 0
            ? "Tap ⌃⌥ for the most recent, hold ⌥ to reply."
            : "Nothing waiting. Sessions appear here as they finish."
        // Unconfirmed replies are deliberately NOT shown here. A count you cannot
        // act on is clutter, and naming a CLI command from a floating panel asks
        // you to go somewhere else to do something you did not ask to do. They are
        // still recorded, and `vdctl utterances` still lists them.
        _ = unsentReplies
        let body = [note, status].compactMap { $0 }.joined(separator: " ")

        show(state: waiting > 0 ? "◌ \(waiting) waiting" : "◌ Ready",
             title: "Voice Dispatch", body: body, autoHideAfter: nil)
    }

    /// True when the panel is visible and doing something worth stopping. Escape is
    /// a key with a job in every terminal app, so it only acts here when there is
    /// speech, a countdown, or a recording to interrupt.
    var isBusyOnScreen: Bool {
        guard panel?.isVisible == true else { return false }
        return awaitingConfirm || isRecording || isSpeakingNow
    }

    /// Set by the app; the HUD cannot see the speech chain itself.
    var isSpeakingNow = false

    /// Same path as the Dismiss button, so both can never drift apart.
    func dismiss() { dismissTapped() }

    func hide() {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
    }

    // MARK: - Rendering

    private func show(state: String, title: String, body: String, autoHideAfter: TimeInterval?) {
        Permissions.log("HUD.show state=\(state) title=\(title)")
        if state != "⌁ Send this?" { awaitingConfirm = false }
        let panel = panel ?? build()
        stateLabel.stringValue = state
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        goButton.isHidden = currentTarget?.pid == nil
        replyButton.title = awaitingConfirm ? "Don't send"
            : (isRecording || isListening ? "Send now" : "Reply")
        let action: String
        if isListening {
            action = "Let go of ⌥ to send, or Dismiss to throw it away."
        } else if awaitingConfirm {
            action = "Sending in a moment. Stop it if that isn't what you said."
        } else {
            if currentTarget == nil {
                action = ""
            } else if isRecording {
                action = "Listening. Click Send, or let go of ⌥."
            } else {
                action = "Click Reply, or hold ⌥ to speak."
            }
        }
        hintLabel.stringValue = identity.map { "\($0)\n\(action)" } ?? action
        replyButton.isHidden = awaitingConfirm ? false : (currentTarget == nil)
        // With no session in hand, Dismiss is the only honest control.
        if currentTarget == nil, !awaitingConfirm { goButton.isHidden = true }
        // Nothing about another session matters while you are mid-sentence.
        if isListening { goButton.isHidden = true }

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
        // The exact path that drew past the panel edge.
        identity = Self.identify(
            pid: 1,
            cwd: NSHomeDirectory()
                + "/Projects/kopi/promotions/.claude/worktrees/"
                + "product-image-binding-oracle/promotions")
        Permissions.log("selftest identity=\(identity ?? "nil")")
        for (label, block) in [
            ("idle", { self.showIdle(note: long, waiting: 3) }),
            ("announcement", { self.showAnnouncement(
                topic: "Product image binding fix validation", spoken: long,
                sessionId: "s", pid: 1, project: "promotions", cwd: "/tmp/promotions") }),
            ("listening", {
                var t = 0.0
                self.showListening(level: {
                    t += 0.05
                    return Float(0.25 + 0.25 * sin(t * 6))  // something speech-shaped
                })
                // Fill the history so the drawing path runs against real geometry.
                for i in 0..<80 { self.meter.push(CGFloat(0.2 + 0.6 * abs(sin(Double(i) / 4)))) }
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                Permissions.log(
                    "meter frame=\(self.meter.frame) hidden=\(self.meter.isHidden) style=centred")
            }),
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
        // NSWindow defaults isReleasedWhenClosed to true, which predates ARC: closing
        // the window performs a manual release while `panel` still holds a strong
        // reference. The result is an over-release, and the panel's content — the
        // buttons among it — becomes freed memory that AppKit still hands mouse
        // events to. Clicking Reply then crashed inside the executor check on a
        // garbage object pointer, taking the window with it.
        panel.isReleasedWhenClosed = false
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
        hintLabel.lineBreakMode = .byTruncatingMiddle
        progressBar = NSProgressIndicator()
        progressBar.isIndeterminate = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.controlSize = .small
        progressBar.isHidden = true

        meter = LevelMeterView()
        meter.isHidden = true

        let stack = NSStackView(views: [stateLabel, titleLabel, bodyLabel, progressBar, meter,
                                        hintLabel, buttons])
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
            hintLabel.widthAnchor.constraint(equalToConstant: 348),
            titleLabel.widthAnchor.constraint(equalToConstant: 348),
            stateLabel.widthAnchor.constraint(equalToConstant: 348),
            meter.widthAnchor.constraint(equalToConstant: 348),
            meter.heightAnchor.constraint(equalToConstant: 28),
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
    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func goToSession() {
        MainActor.assumeIsolated {
            guard let pid = currentTarget?.pid else {
                bodyLabel.stringValue = "That session is no longer running, so there's no tab to open."
                return
            }
            guard let tty = ProcessProbe.tty(of: pid) else {
                bodyLabel.stringValue = "Couldn't find a terminal for process \(pid). It may have exited."
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
    }

    /// Advance the highlight to the character range currently being spoken.
    ///
    /// Everything up to the cursor is shown at full strength and the rest dimmed, so
    /// the eye can follow the voice without the jitter of a per-word box.
    func highlight(upTo index: Int) {
        guard let body = bodyLabel?.stringValue, !body.isEmpty else {
            Permissions.log("highlight upTo=\(index) SKIPPED: no body text")
            return
        }
        Permissions.log("highlight upTo=\(index) of \(body.count) thread=\(Thread.isMainThread)")
        let clamped = max(0, min(index, body.count))
        let attributed = NSMutableAttributedString(string: body)
        let full = NSRange(location: 0, length: (body as NSString).length)
        attributed.addAttribute(
            .foregroundColor, value: NSColor.labelColor.withAlphaComponent(0.35), range: full)
        let spokenRange = NSRange(location: 0, length: min(clamped, full.length))
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: spokenRange)
        attributed.addAttribute(Self.spokenMark, value: true, range: spokenRange)
        attributed.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 12), range: full)
        bodyLabel.attributedStringValue = attributed

        var bright = 0
        bodyLabel.attributedStringValue.enumerateAttribute(Self.spokenMark, in: full) { value, range, _ in
            if value != nil { bright += range.length }
        }
        Permissions.log("highlight rendered bright=\(bright)/\(full.length)")
    }

    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func replyTapped() {
        MainActor.assumeIsolated {
            if awaitingConfirm {
                cancelPendingSendTapped()
                return
            }
            if isRecording { isRecording = false; onStopReply?() }
            else { isRecording = true; onReply?() }
            replyButton.title = isRecording ? "Send reply" : "Reply"
            let action: String
            if isListening {
                action = "Let go of ⌥ to send, or Dismiss to throw it away."
            } else if awaitingConfirm {
                action = "Sending in a moment. Stop it if that isn't what you said."
            } else {
                if currentTarget == nil {
                    action = ""
                } else if isRecording {
                    action = "Listening. Click Send, or let go of ⌥."
                } else {
                    action = "Click Reply, or hold ⌥ to speak."
                }
            }
            hintLabel.stringValue = identity.map { "\($0)\n\(action)" } ?? action
        }
    }

    func recordingEnded() {
        isRecording = false
        isListening = false
        meterTimer?.invalidate()
        meterTimer = nil
        meter?.isHidden = true
        replyButton?.title = "Reply"
    }

    /// Set by the app so Dismiss can silence the voice, not just hide the panel.
    var onDismiss: (() -> Void)?

    // AppKit guarantees target/action runs on the main thread. The implicit
    // executor check that Swift emits for an @objc method on a @MainActor class is
    // therefore redundant, and it was not free: it crashed in swift_getObjectType
    // on a bad executor pointer, killing the app on a button press. `nonisolated`
    // plus assumeIsolated keeps the isolation guarantee without the check.
    @objc nonisolated private func dismissTapped() {
        MainActor.assumeIsolated {
            countdownTimer?.invalidate()
            countdownTimer = nil
            awaitingConfirm = false
            onDismiss?()
            hide()
        }
    }
}
