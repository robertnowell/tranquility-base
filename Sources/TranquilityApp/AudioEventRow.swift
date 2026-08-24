import AppKit

/// One audio event the pane can show: a capture over a second, with the
/// FULL transcript it has (nil = none — a row that failed every provider,
/// or was cancelled before one answered). Full, not pre-truncated: the
/// label truncates visually, and the ⋯ menu's Copy hands over the whole
/// thing — the pane is where a clipped transcript gets un-clipped.
///
/// Hoisted out of StatusHUD (App-lane P3, 23 Aug, "leaf views out") —
/// named explicitly in the original spec alongside DroppedItem. Was
/// `StatusHUD.AudioEventRow`; external references (main.swift) updated to
/// the bare name.
struct AudioEventRow {
    let id: String
    let timeLabel: String
    let durationLabel: String
    let transcript: String?
    var playing = false
    var retrying = false
}

/// One capture in the recent-audio log: when, how long, what it said — or
/// that it said nothing the chain could hear. Play sits on the row because
/// it has state a menu cannot show (▶ while stopped, ■ while playing —
/// ruled 13 Aug); everything stateless lives behind ⋯ — Copy transcript,
/// Retry transcription, Show in Finder.
final class AudioEventRowView: NSControl, NSMenuDelegate {
    static let height: CGFloat = 34
    /// Trailing gutter the row's controls never enter. `scrollerStyle` is
    /// `.overlay` on the list, but macOS substitutes legacy bars when a mouse
    /// is connected or "Show scroll bars: Always" is set — which parked a
    /// scroller exactly on top of the old ↻ (reported 13 Aug, unclickable).
    /// The gutter is reserved unconditionally; against an overlay bar it is
    /// just breathing room.
    static let scrollerGutter: CGFloat = 16

    let eventId: String
    private let event: AudioEventRow
    private let onPlay: () -> Void
    private let onRetry: () -> Void
    private let onReveal: () -> Void
    private let hairline = CALayer()
    private var playButton: ConsoleButton!
    private var menuButton: ConsoleButton!

    var playButtonTitle: String { playButton.title }
    var controlsClearTheScroller: Bool {
        menuButton.frame.maxX <= bounds.width - Self.scrollerGutter
    }
    /// The ⋯ menu's Retry item state, for the drill: present unless the row
    /// is already retrying.
    var retryEnabled: Bool { !event.retrying }

    init(event: AudioEventRow,
         onPlay: @escaping () -> Void,
         onRetry: @escaping () -> Void,
         onReveal: @escaping () -> Void) {
        self.eventId = event.id
        self.event = event
        self.onPlay = onPlay
        self.onRetry = onRetry
        self.onReveal = onReveal
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hairline.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        layer?.addSublayer(hairline)

        let when = NSTextField(labelWithString: event.timeLabel)
        when.font = ChromeType.mono(ofSize: 10, weight: .regular)
        when.textColor = StateLegend.Palette.secondary
        when.translatesAutoresizingMaskIntoConstraints = false

        let duration = NSTextField(labelWithString: event.durationLabel)
        duration.font = ChromeType.mono(ofSize: 10, weight: .regular)
        duration.textColor = StateLegend.Palette.faint
        duration.alignment = .right
        duration.translatesAutoresizingMaskIntoConstraints = false

        // The transcript is the row's name; its absence is stated in the
        // hint colour rather than left as a blank, because an empty slot
        // reads as a rendering bug and a stated absence reads as a fact.
        let snippet = NSTextField(labelWithString: event.transcript ?? "no transcript")
        snippet.font = ChromeType.mono(ofSize: 11, weight: .regular)
        snippet.textColor = event.transcript == nil
            ? StateLegend.Palette.hint : StateLegend.Palette.ink
        snippet.lineBreakMode = .byTruncatingTail
        snippet.translatesAutoresizingMaskIntoConstraints = false
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playButton = ConsoleButton(title: event.playing ? "■" : "▶",
                                   target: self, action: #selector(playTapped))
        playButton.isBordered = false
        playButton.font = ChromeType.mono(ofSize: 12, weight: .regular)
        if event.playing {
            // Playing is a STATE, and it is already wearing `ink`. Hover does
            // not overwrite a louder signal with a quieter one, so a playing
            // row answers the pointer with the cursor alone — the same carve-out
            // the settings tabs take.
            playButton.contentTintColor = StateLegend.Palette.ink
        } else {
            playButton.restingInk = StateLegend.Palette.secondary
        }
        playButton.translatesAutoresizingMaskIntoConstraints = false

        menuButton = ConsoleButton(title: "⋯", target: self, action: #selector(menuTapped))
        menuButton.isBordered = false
        menuButton.font = ChromeType.mono(ofSize: 12, weight: .semibold)
        menuButton.restingInk = StateLegend.Palette.secondary
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        for view in [when, duration, snippet, playButton!, menuButton!] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            when.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            when.widthAnchor.constraint(equalToConstant: 74),
            when.centerYAnchor.constraint(equalTo: centerYAnchor),
            duration.leadingAnchor.constraint(equalTo: when.trailingAnchor, constant: 2),
            duration.widthAnchor.constraint(equalToConstant: 44),
            duration.centerYAnchor.constraint(equalTo: centerYAnchor),
            snippet.leadingAnchor.constraint(equalTo: duration.trailingAnchor, constant: 8),
            snippet.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: snippet.trailingAnchor, constant: 6),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.leadingAnchor.constraint(
                equalTo: playButton.trailingAnchor, constant: 8),
            menuButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.scrollerGutter),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    /// The stateless verbs. Built fresh per click so the items reflect the
    /// row as it is now, not as it was rendered.
    func rowMenu() -> NSMenu {
        let menu = NSMenu()
        if event.transcript != nil {
            menu.addItem({ let i = NSMenuItem(
                title: "Copy transcript", action: #selector(copyTranscript),
                keyEquivalent: ""); i.target = self; return i }())
        }
        let retry = NSMenuItem(
            title: event.retrying ? "Retrying…" : "Retry transcription",
            action: event.retrying ? nil : #selector(retryFromMenu), keyEquivalent: "")
        retry.target = event.retrying ? nil : self
        menu.addItem(retry)
        menu.addItem({ let i = NSMenuItem(
            title: "Show audio in Finder", action: #selector(revealFromMenu),
            keyEquivalent: ""); i.target = self; return i }())
        return menu
    }

    var menuTitlesForSelfTest: [String] { rowMenu().items.map(\.title) }
    func performRetryForSelfTest() { retryFromMenu() }
    func tapPlayForSelfTest() { playButton.performClick(nil) }

    @objc nonisolated private func playTapped() {
        MainActor.assumeIsolated { onPlay() }
    }

    @objc nonisolated private func menuTapped() {
        MainActor.assumeIsolated {
            let menu = rowMenu()
            menu.popUp(positioning: nil,
                       at: NSPoint(x: menuButton.frame.minX,
                                   y: menuButton.frame.minY - 4),
                       in: self)
        }
    }

    @objc nonisolated private func copyTranscript() {
        MainActor.assumeIsolated {
            guard let text = event.transcript else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Permissions.log("recent-audio: copied \(text.count) chars from \(eventId.prefix(8))")
        }
    }

    @objc nonisolated private func retryFromMenu() {
        MainActor.assumeIsolated { onRetry() }
    }

    @objc nonisolated private func revealFromMenu() {
        MainActor.assumeIsolated { onReveal() }
    }
}
