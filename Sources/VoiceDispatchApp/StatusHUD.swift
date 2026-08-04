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
    /// Where dictation will land ("→ Terminal", "→ clipboard"), probed at mic-open
    /// so the pill names the real destination, not the fallback.
    var dictationDestination: String?
    /// The event the panel is currently about, so Dismiss can retire it.
    private(set) var currentEventId: String?
    private var countdownTimer: Timer?
    private var onCancelSend: ((_ restartListening: Bool) -> Void)?
    private var progressBar: NSProgressIndicator!
    private var meter: LevelMeterView!
    private var discardButton: NSButton!
    private var sendCheckButton: NSButton!
    private var voicePicker: NSPopUpButton!
    private var settingsVoices: [Voice] = []
    private var gearButton: NSButton!
    private var backButton: NSButton!
    private var stateButton: NSButton!
    private var waitingRows: NSStackView!
    var onPickWaiting: ((String) -> Void)?
    private var actionRow: NSStackView!
    private static let spokenMark = NSAttributedString.Key("vdSpoken")

    private var currentTarget: (sessionId: String, pid: Int?, label: String)?

    // MARK: - Public surface

    /// While you are talking, the panel's whole job is to prove it can hear you.
    ///
    /// It previously showed the same identity line, the same "hold ⌥ to speak" hint
    /// you were already obeying, and three buttons for actions unrelated to
    /// speaking. A live level meter answers the only question you actually have.
    /// A deep link hands the panel its session before the mic opens, so Listening
    /// can show who the reply is addressed to.
    func adoptTarget(sessionId: String, pid: Int?, label: String, cwd: String?) {
        currentTarget = (sessionId, pid, label)
        currentEventId = sessionId
        identity = Self.identify(pid: pid, cwd: cwd)
    }

    func showListening(level: @escaping () -> Float, handsFree: Bool = false) {
        transition(to: .listening(eventId: currentEventId), because: "recording started")
        awaitingConfirm = false
        isListening = true
        levelSource = level
        listenStartedAt = Date()
        show(state: "● \(currentTarget?.label ?? dictationDestination ?? "→ clipboard")\(handsFree ? "  ·  hands-free" : "")",
             title: "", body: "", autoHideAfter: nil)
        // A pill: target name plus waveform, nothing else. Hands-free flanks the
        // waveform with ✕ and ✓, so the controls sit where your eyes already are.
        // The name stays (unlike Wispr) because our destination is a terminal
        // somewhere else, not the focused field on this screen.
        titleLabel.isHidden = true
        hintLabel.stringValue = ""
        actionRow.isHidden = true
        discardButton.isHidden = !handsFree
        sendCheckButton.isHidden = !handsFree
        if let panel { resizeToFit(panel); position(panel) }
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
        isCatchUp: Bool = false,
        topic: String, spoken: String, sessionId: String, pid: Int?, project: String,
        cwd: String?, eventId: String? = nil
    ) {
        awaitingConfirm = false
        currentEventId = eventId
        currentTarget = (sessionId, pid, project)
        // Only prefix when the topic adds something. A topic equal to the project
        // rendered as "promotions — promotions", which names the folder twice and
        // tells you nothing.
        let headline = topic.caseInsensitiveCompare(project) == .orderedSame || topic.isEmpty
            ? project : "\(project): \(topic)"
        identity = Self.identify(pid: pid, cwd: cwd)
        transition(to: .speaking(eventId: eventId, catchUp: isCatchUp), because: "audio starting")
        show(state: isCatchUp ? "↺ Catching up" : "◀ Speaking",
             title: headline, body: spoken, autoHideAfter: nil)
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
        transition(to: .pendingSend(utteranceId: ""), because: "undo window open")
        show(state: "→ Sending to \(label)", title: "Your reply",
             body: "\u{201C}\(text)\u{201D}", autoHideAfter: nil)
        // After show(), never before: the state entry points clear this flag, and
        // setting it first meant the countdown was uncancellable from the moment it
        // appeared.
        awaitingConfirm = true
        replyButton.title = "Don't send"
        replyButton.isHidden = false

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

    /// Settings, in the same panel rather than a second window.
    ///
    /// One setting today. It lives here because the panel is already the place you
    /// look, and a preferences window for a single dropdown is furniture.
    var onChooseVoice: ((String) -> Void)?

    func showSettings(voices: [Voice], selected: String, previewNote: String) {
        awaitingConfirm = false
        currentTarget = nil
        identity = nil
        settingsVoices = voices
        transition(to: .settings, because: "settings opened")

        show(state: "Settings", title: "Voice", body: previewNote, autoHideAfter: nil)
        backButton.isHidden = false
        gearButton.isHidden = true
        actionRow.isHidden = true
        hintLabel.stringValue = ""
        stateLabel.stringValue = ""

        voicePicker.removeAllItems()
        for group in ["cloned", "generated", "professional", "premade"] {
            let inGroup = voices.filter { $0.category == group }.sorted { $0.name < $1.name }
            guard !inGroup.isEmpty else { continue }
            voicePicker.menu?.addItem(.separator())
            let header = NSMenuItem(title: group.capitalized, action: nil, keyEquivalent: "")
            header.isEnabled = false
            voicePicker.menu?.addItem(header)
            for voice in inGroup {
                let item = NSMenuItem(title: voice.name, action: nil, keyEquivalent: "")
                item.representedObject = voice.id
                voicePicker.menu?.addItem(item)
            }
        }
        if let match = voicePicker.menu?.items.first(where: {
            ($0.representedObject as? String) == selected
        }) {
            voicePicker.select(match)
        }
        voicePicker.isHidden = false
    }

    var voicePickerItemCount: Int { voicePicker.numberOfItems }
    var backButtonHidden: Bool { backButton.isHidden }
    var gearHidden: Bool { gearButton.isHidden }
    var actionRowHidden: Bool { actionRow.isHidden }
    var voicePickerHidden: Bool { voicePicker.isHidden }
    var voicePickerSelection: String? { voicePicker.selectedItem?.title }

    @objc nonisolated private func voicePicked() {
        MainActor.assumeIsolated {
            guard let id = voicePicker.selectedItem?.representedObject as? String else { return }
            onChooseVoice?(id)
        }
    }

    func showWorking(_ message: String) {
        transition(to: .transcribing(startedAt: Date()), because: "working")
        awaitingConfirm = false
        show(state: "◌ Working", title: currentTarget?.label ?? "Voice Dispatch",
             body: message, autoHideAfter: nil)
    }

    /// A receipt, not a state you live in.
    ///
    /// A success needs nothing from you, so it says what happened and gets out of
    /// the way. "It's mid-turn, so it sends when that finishes" is worth a few
    /// seconds because it is not something you could otherwise know, but leaving it
    /// on screen with buttons implies there is something left to do. A failure is
    /// the opposite and stays until dismissed.
    func showResult(_ message: String, ok: Bool) {
        transition(to: .result(ok: ok), because: "reply resolved")
        awaitingConfirm = false
        // Reply and Go to session are about the announcement, not the receipt, and
        // offering them here suggests the send is still in your hands. It is not.
        currentTarget = ok ? nil : currentTarget
        show(state: ok ? "▶ Sent" : "⚠ Needs you",
             title: ok ? "Voice Dispatch" : (currentTarget?.label ?? "Voice Dispatch"),
             body: message, autoHideAfter: ok ? 6 : nil)
    }

    /// `note` is a prefix about what just happened ("Stopped."). The sentence about
    /// what is waiting is always derived from `waiting`, never passed in — the two
    /// were computed at different call sites and drifted, so the panel showed
    /// "2 waiting" directly above "Nothing waiting".
    /// True when the panel is showing the passive idle state and nothing else.
    ///
    /// Used to decide whether an arriving turn may refresh the panel underneath. It
    /// must never redraw over speech, a recording, a countdown or a failure notice:
    /// those are conversations in progress, and a background update that interrupts
    /// one is worse than a stale count.
    private(set) var state: PanelState = .hidden

    /// The only way state changes. Every transition is logged, which is the whole
    /// point: when the panel gets stuck, the log says exactly which state it is in
    /// and what put it there, instead of leaving five booleans to be inferred.
    private func transition(to next: PanelState, because reason: String) {
        guard next != state else { return }
        Permissions.log("state: \(state.name) -> \(next.name)  (\(reason))")
        state = next
    }

    /// Kept as a computed view over the state so existing call sites keep working.
    var isIdle: Bool { state.allowsAmbientSurface }

    func showIdle(note: String? = nil, waiting: Int, unsentReplies: Int = 0) {
        awaitingConfirm = false
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

        show(state: waiting > 0 ? "" : "◌ Ready",
             title: "Voice Dispatch", body: body, autoHideAfter: nil)
        // Clickable when there is something behind it.
        stateButton.title = waiting > 0 ? "◌ \(waiting) waiting  ›" : ""
        stateButton.isHidden = waiting == 0
        stateLabel.isHidden = waiting > 0
        transition(to: .idle(waiting: waiting), because: "idle repaint")
    }

    /// True when the panel is visible and doing something worth stopping. Escape is
    /// a key with a job in every terminal app, so it only acts here when there is
    /// speech, a countdown, or a recording to interrupt.
    var isBusyOnScreen: Bool {
        guard panel?.isVisible == true else { return false }
        return state.acceptsEscape
    }

    var isCapturingAudio: Bool { state.isCapturingAudio }
    var canStartReply: Bool { state.canStartReply }

    /// Set by the app; the HUD cannot see the speech chain itself.
    var isSpeakingNow = false

    /// Same path as the Dismiss button, so both can never drift apart.
    func dismiss() { dismissTapped() }

    func hide() {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
        // Hidden still allows ambient surfacing, which is the property that broke
        // when this left a non-idle flag behind: after one Dismiss the app went
        // silent for the rest of the session.
        transition(to: .hidden, because: "panel hidden")
        currentTarget = nil
        currentEventId = nil
        identity = nil
    }

    /// Whether an arriving turn may raise the panel right now.
    ///
    /// Anything mid-conversation says no: speech, a recording, a send countdown, or
    /// a failure still waiting to be read. Everything else, hidden included, is a
    /// moment where showing up is welcome rather than an interruption.
    var canSurfaceAmbiently: Bool { state.allowsAmbientSurface }

    var isOnScreen: Bool { panel?.isVisible ?? false }

    // MARK: - Rendering

    private func show(state: String, title: String, body: String, autoHideAfter: TimeInterval?) {
        Permissions.log("HUD.show state=\(state) title=\(title)")
        // Deliberately NOT inferred from the state text: it was, the text changed,
        // and the countdown silently stopped being cancellable. Each state that
        // should end a pending send now says so itself.
        if voicePicker != nil, state != "Settings" {
            voicePicker.isHidden = true
            titleLabel.isHidden = false
            discardButton?.isHidden = true
            sendCheckButton?.isHidden = true
            waitingRows?.isHidden = true
            stateButton?.isHidden = true
            stateLabel?.isHidden = false
            backButton.isHidden = true
            gearButton.isHidden = false
            actionRow.isHidden = false
        }
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
        // Go to session stays available while listening — knowing which terminal
        // your words are about to land in is exactly when you want to check.

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

        // Frames live in each view's own superview, and the header is a nested
        // stack, so comparing raw minX values across rows compares nothing. Convert
        // into the panel's space before drawing any conclusion about alignment.
        if let root = panel.contentView {
            func box(_ v: NSView) -> NSRect { v.convert(v.bounds, to: root) }
            Permissions.log(
                "HUD chrome: state.x=\(Int(box(stateLabel).minX)) "
                + "title.x=\(Int(box(titleLabel).minX)) body.x=\(Int(box(bodyLabel).minX)) "
                + "gear.maxX=\(Int(box(gearButton).maxX)) panelW=\(Int(panel.frame.width)) "
                + "rightMargin=\(Int(panel.frame.width - box(gearButton).maxX))")
        }
        Permissions.log(
            "HUD layout: needed=\(Int(needed.height)) frame=\(Int(panel.frame.height)) "
            + "buttonsFit=\(buttonsFit) textFits=\(textFits) "
            + "labelH=\(Int(bodyLabel.bounds.height)) naturalH=\(Int(natural))")
    }

    /// Shown the instant ⌃⌥ is tapped, so the gap before audio isn't dead air.
    /// Summarizing and fetching the voice take a few seconds; without this the app
    /// looks broken for the whole of it.
    /// A visible pulse the instant a gesture registers.
    ///
    /// The gap between pressing and anything happening is where the app feels
    /// broken: summarizing takes seconds, and with no acknowledgment a registered
    /// press and a missed press look identical, so you press again — which is how
    /// every double-trigger bug this weekend started. The pulse says "heard you"
    /// before any work begins.
    /// Our own overlay layer, not the NSVisualEffectView's.
    ///
    /// The first version set a border on the effect view's backing layer and
    /// nothing appeared: that layer is privately managed and does not render
    /// externally-set borders reliably. A plain CALayer we own, sitting above the
    /// content, has no such opinions.
    private var ackLayer: CALayer?

    func flashAcknowledge() {
        guard let host = panel?.contentView, let hostLayer = host.layer else { return }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }

        let layer: CALayer
        if let existing = ackLayer {
            layer = existing
        } else {
            layer = CALayer()
            layer.borderColor = NSColor.controlAccentColor.cgColor
            layer.borderWidth = 3
            layer.cornerRadius = 12
            layer.opacity = 0
            hostLayer.addSublayer(layer)
            ackLayer = layer
        }
        layer.frame = host.bounds

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.0
        pulse.duration = 0.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.removeAnimation(forKey: "ack")
        layer.add(pulse, forKey: "ack")
        Permissions.log("ack: pulsed (visible=\(panel?.isVisible == true))")
    }

    func showPreparing() {
        transition(to: .preparing, because: "announce requested")
        show(state: "◌ Preparing", title: "Voice Dispatch",
             body: "Writing the summary and fetching the voice…", autoHideAfter: nil)
    }

    /// Prove a pending send can be stopped for its whole life.
    ///
    /// It could not: the flag was inferred from the state text, the text changed,
    /// and cancelling silently became a no-op. Asserted here rather than trusted.
    func selfTestPendingSend() {
        var sent = false
        var cancelled = false
        currentTarget = ("selftest", 1, "promotions")
        showPendingSend(text: "words that should never be sent", label: "promotions",
                        seconds: 4, send: { sent = true }, cancel: { _ in cancelled = true })

        let cancellable = cancelPendingSend(restartListening: false)
        Permissions.log("selftest pendingSend: cancellable=\(cancellable) "
                        + "cancelled=\(cancelled) sent=\(sent)")

        // And it must stay stopped: the timer should be dead, not merely ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Permissions.log("selftest pendingSend: after the window, sent=\(sent)")
        }
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
            ("settings", {
                self.showSettings(
                    voices: [Voice(id: "a", name: "Archer", category: "professional"),
                             Voice(id: "b", name: "My Clone", category: "cloned"),
                             Voice(id: "c", name: "Sarah", category: "premade")],
                    selected: "c",
                    previewNote: "Pick a voice and it reads your most recent summary.")
                self.panel?.contentView?.layoutSubtreeIfNeeded()
                Permissions.log("settings chrome: picker=\(self.voicePickerItemCount) "
                                + "back=\(!self.backButtonHidden) gear=\(!self.gearHidden) "
                                + "actions=\(!self.actionRowHidden) "
                                + "selected=\(self.voicePickerSelection ?? "nil")")
            }),
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
        stateButton = NSButton(title: "", target: self, action: #selector(stateTapped))
        stateButton.isBordered = false
        stateButton.controlSize = .small
        stateButton.isHidden = true
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

        gearButton = NSButton(title: "⚙", target: self, action: #selector(gearTapped))
        gearButton.isBordered = false
        gearButton.controlSize = .small
        gearButton.font = .systemFont(ofSize: 12)
        gearButton.contentTintColor = .secondaryLabelColor

        // A breadcrumb, not a button in a row of actions: it says where you are and
        // the only way out is back the way you came.
        backButton = NSButton(title: "‹ Back", target: self, action: #selector(backTapped))
        backButton.isBordered = false
        backButton.controlSize = .small
        backButton.font = .systemFont(ofSize: 11, weight: .medium)
        backButton.contentTintColor = .secondaryLabelColor
        backButton.isHidden = true

        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissTapped))
        dismiss.bezelStyle = .rounded
        dismiss.controlSize = .small
        dismiss.font = .systemFont(ofSize: 11)

        hintLabel = NSTextField(labelWithString: "")
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor

        let buttons = NSStackView(views: [replyButton, goButton, dismiss])
        actionRow = buttons
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

        discardButton = NSButton(title: "✕", target: self, action: #selector(dismissTapped))
        discardButton.isBordered = false
        discardButton.font = .systemFont(ofSize: 15, weight: .medium)
        discardButton.contentTintColor = .secondaryLabelColor
        discardButton.isHidden = true

        sendCheckButton = NSButton(title: "✓", target: self, action: #selector(checkTapped))
        sendCheckButton.isBordered = false
        sendCheckButton.font = .systemFont(ofSize: 15, weight: .semibold)
        sendCheckButton.contentTintColor = .controlAccentColor
        sendCheckButton.isHidden = true

        voicePicker = NSPopUpButton()
        voicePicker.controlSize = .small
        voicePicker.font = .systemFont(ofSize: 11)
        voicePicker.target = self
        voicePicker.action = #selector(voicePicked)
        voicePicker.isHidden = true

        waitingRows = NSStackView()
        waitingRows.orientation = .vertical
        waitingRows.alignment = .leading
        waitingRows.spacing = 2
        waitingRows.isHidden = true

        let stack = NSStackView(views: [backButton, stateButton, stateLabel, titleLabel,
                                        waitingRows, bodyLabel,
                                        progressBar, meter, voicePicker, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        background.addSubview(gearButton)
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bodyLabel.widthAnchor.constraint(equalToConstant: 348),
            hintLabel.widthAnchor.constraint(equalToConstant: 348),
            titleLabel.widthAnchor.constraint(equalToConstant: 348),
            stateLabel.widthAnchor.constraint(equalToConstant: 348),
            // Same margin as every text row, so the eye reads one column.
            gearButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            gearButton.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),
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
        dictationDestination = nil
        isRecording = false
        isListening = false
        meterTimer?.invalidate()
        meterTimer = nil
        meter?.isHidden = true
        replyButton?.title = "Reply"
    }

    /// Set by the app so Dismiss can silence the voice, not just hide the panel.
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onLeaveSettings: (() -> Void)?

    @objc nonisolated private func checkTapped() {
        MainActor.assumeIsolated {
            if isRecording { isRecording = false }
            onStopReply?()
        }
    }

    @objc nonisolated private func gearTapped() {
        MainActor.assumeIsolated { onOpenSettings?() }
    }

    @objc nonisolated private func stateTapped() {
        MainActor.assumeIsolated { onOpenWaitingList?() }
    }

    /// A list of what is waiting, so the count can be opened rather than believed.
    func showWaitingList(_ items: [(id: String, label: String, topic: String)]) {
        transition(to: .settings, because: "waiting list opened")
        show(state: "", title: "\(items.count) waiting", body: "", autoHideAfter: nil)
        stateLabel.stringValue = ""
        backButton.isHidden = false
        gearButton.isHidden = true
        actionRow.isHidden = true
        hintLabel.stringValue = ""
        bodyLabel.stringValue = ""

        waitingRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items.prefix(8) {
            let row = NSButton(title: "\(item.label): \(item.topic)",
                               target: self, action: #selector(waitingRowTapped(_:)))
            row.isBordered = false
            row.alignment = .left
            row.font = .systemFont(ofSize: 12)
            row.identifier = NSUserInterfaceItemIdentifier(item.id)
            row.lineBreakMode = .byTruncatingTail
            waitingRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 348).isActive = true
        }
        waitingRows.isHidden = false
        if let panel { resizeToFit(panel); position(panel) }
    }

    @objc nonisolated private func waitingRowTapped(_ sender: NSButton) {
        MainActor.assumeIsolated {
            guard let id = sender.identifier?.rawValue else { return }
            onPickWaiting?(id)
        }
    }

    var onOpenWaitingList: (() -> Void)?

    @objc nonisolated private func backTapped() {
        MainActor.assumeIsolated {
            // Leaving settings stops whatever the preview was saying. Walking away
            // from a screen should not leave its sound running.
            onLeaveSettings?()
        }
    }

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
