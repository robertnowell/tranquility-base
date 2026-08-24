import AppKit
import TranquilityCore

/// One grid row, in the ruled three-column geometry: a 26px lamp column, a
/// 148px callsign column, and the topic in whatever remains — at a fixed 31px
/// height with single-line tail-truncating labels, so a row can never be taller
/// or shorter than its neighbors and no text fragment can wrap between rows.
///
/// A control with real frames, not a bezel-less NSButton: an attributed title
/// can only flow its runs inline, and columns need columns. Hover paints the
/// row in the palette's hover putty, exactly like the mock.
final class GridRowView: NSControl {
    // Variant C metrics (ruled 05 Aug, from the accepted draft render, scaled
    // from its 640px frame to the panel's 352): taller rows, the name in the
    // larger mono with NO added tracking, the callsign right-aligned and
    // muted. The fixed 148px name column is dead — the name owns the row up
    // to the shared callsign column (`auxWidth`, measured by the grid over
    // every shown row, capped at `auxFraction`), so all names truncate at ONE
    // vertical boundary instead of each row's own rag.
    static let height: CGFloat = 40
    // 26 → 20 (ruled 05 Aug): the 17pt lamp-to-name gap read as dead air at
    // the new row height; 11pt keeps the lamp clear of the type and hands the
    // difference to the name column.
    static let lampColumn: CGFloat = 20
    /// The lamp's click target. Equal to the column ON PURPOSE, after trying
    /// wider and backing it out.
    ///
    /// The target is already 20 × 40 — the full row height, not the 9pt dot —
    /// so it is far larger than it looks and past the usual 24pt guidance by
    /// area. Widening it in x has nowhere to go: the name begins at
    /// `lampColumn`, so 28 would have swallowed the name's first 8pt and made
    /// clicking a session's title MUTE it, and buying that space back by
    /// pushing `lampColumn` out would reverse the 05 Aug ruling that tightened
    /// 26 → 20 — with an argument, which rule 4 does not accept. The
    /// discoverability this was reaching for is the hover pill's job instead.
    static let lampHitWidth: CGFloat = lampColumn
    /// How far the hover highlight reaches PAST the row's content on each side.
    ///
    /// The row's content box starts exactly where the lamp starts — the lamp is
    /// pinned flush to `leadingAnchor` — so a highlight drawn to the row's own
    /// bounds put a hard edge against the lamp with no air at all. The panel's
    /// stack already holds 14pt of inset on either side; the highlight borrows
    /// 8 of it so the lamp sits INSIDE the lit area rather than on its border.
    /// Nothing that is drawn moves: this widens the lit rectangle only.
    static let hoverBleed: CGFloat = 8
    static let auxFraction: CGFloat = 0.38
    static let auxFont = ChromeType.mono(ofSize: 11, weight: .regular)

    init(item: SessionRow, auxWidth: CGFloat,
         target: AnyObject, action: Selector) {
        nameLabel = NSTextField(labelWithString: item.name)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        identifier = NSUserInterfaceItemIdentifier(item.id)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // Rest the pointer and read the whole thing. Both halves of this row
        // truncate, so until 18 Aug the end of an error or a stall lived only
        // in the log: "there's no way to see the full message."
        toolTip = SessionRow.hoverText(for: item)

        let ready = item.lamp == .ready

        // The lamp: a 9px CIRCLE (ruled — squares read as checkboxes), flat
        // fill, no gradients or shadows. Quiet lamps get the hairline ring.
        let lamp = NSView()
        lamp.translatesAutoresizingMaskIntoConstraints = false
        lamp.wantsLayer = true
        // READ STATE GETS ITS OWN CHANNEL: a lit lamp is SOLID while unread
        // and a RING once opened, in the same state colour (16 Aug).
        //
        // Brightness alone could not do this job. Measured on the rendered
        // panel: unread ink 199, a gone row 129, and any opened step strong
        // enough to see lands on top of the gone row — so read would have been
        // borrowing the death channel, which is the collision behind "turned
        // off is turned off". Fill-vs-ring is orthogonal: colour still says
        // WHICH state (green ready, blue working), the fill says whether you
        // have heard it, and a gone row is a grey socket, a different colour
        // entirely. It is also the oldest unread idiom there is — a solid dot
        // that hollows out once you have looked.
        let hollow = item.read == .opened && item.lamp.asksForYou
        lampLayer = lamp.layer
        lamp.layer?.backgroundColor = hollow ? NSColor.clear.cgColor : item.lamp.fill.cgColor
        lamp.layer?.cornerRadius = Lamp.diameter / 2
        if hollow {
            // 1.5pt, not the quiet ring's 1pt: at 9px a hairline ring reads as
            // a smudge rather than a deliberate outline.
            lamp.layer?.borderWidth = 1.5
            lamp.layer?.borderColor = item.lamp.fill.cgColor
        } else if let ring = item.lamp.ring {
            lamp.layer?.borderWidth = 1
            lamp.layer?.borderColor = ring.cgColor
        }

        // The type ramp: both columns monospaced (one family, two sizes — the
        // callsign is an identity, not prose). Semibold is the UNREAD weight
        // (ruled 13 Aug): a ready row drops to medium once its turn has been
        // opened, the iOS Messages move — the lamp stays lit because read is
        // not answered, but the weight stops claiming there is something you
        // have not been told.
        //
        // A row whose session has exited is drawn at reduced ink (ruled 11 Aug:
        // "they should be shown that they are not alive"). The dimming is the
        // second half of a two-channel statement, and both channels are about
        // presence rather than state: an empty socket where a lamp would be,
        // and type that has stepped back. No new colour is spent on it.
        let ink = item.lamp.rowAlpha
        let name = nameLabel
        // Unread is BRIGHT AND HEAVY; opened steps back on both channels.
        //
        // Weight alone shipped on 13 Aug and could not be seen: semibold
        // against medium at 13pt mono is a few hundredths of a stem width,
        // and the report was immediate — "it doesn't decrease the brightness
        // of the text or anything". Brightness is the channel a person
        // actually reads a list by, so the ink steps `ink -> secondary` (a
        // Palette step the callsign column already uses, not a new colour and
        // not an alpha fade — a fade is how a LIVE opened row would start
        // impersonating a dead one, which `rowAlpha` owns).
        // NO BOLD. Hierarchy is intensity plus the lamp, never weight.
        //
        // This is the AmberConsole law the MOCR research adopted and the panel had
        // been quietly breaking since the grid was built: "single hue at
        // multiple intensities; hierarchy via size/intensity/inverse-video,
        // NO BOLD; flat by philosophy" (2026-08-04-mocr-brand-aesthetic,
        // Established). Ready rows were semibold, and the 13 Aug read state
        // made it worse by recruiting weight to mean unread as well. A
        // console does not shout in a heavier cut of the same face; it
        // burns brighter.
        //
        // So intensity answers one question — is this row asking for you —
        // and it is the SAME answer on every face. A row that is merely
        // alive rests at the same level as one you have already heard,
        // because neither is asking; only their lamps differ.
        name.font = ChromeType.mono(ofSize: 13, weight: .medium)
        // FULL INK IS RESERVED FOR ROWS THAT WANT YOU, and after this change
        // that is exactly the green and amber ones you have not heard.
        //
        // Dark-cockpit doctrine, which this palette already states: the panel
        // is dark when all is nominal and a lit lamp always means deviation.
        // An advisory row rendered at full attention ink broke it — the agent
        // is working, there is nothing to do, and the brightest thing on the
        // panel was saying otherwise. It comes back the moment the agent
        // stops: the lamp returns to green, the turn is still unread, and the
        // row lights up on its own.
        name.textColor = (item.read.isAsking && item.lamp.asksForYou
                          ? StateLegend.Palette.ink
                          : StateLegend.Palette.restingInk).withAlphaComponent(ink)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let callsign = NSTextField(labelWithString: item.aux)
        callsign.font = Self.auxFont
        callsign.textColor = (ready ? StateLegend.Palette.secondary : StateLegend.Palette.muted)
            .withAlphaComponent(ink)
        callsign.lineBreakMode = .byTruncatingTail
        callsign.alignment = .right
        callsign.translatesAutoresizingMaskIntoConstraints = false

        // Behind everything: the hover pill. A view rather than the row's own
        // layer, because it has to reach wider than the row's content box —
        // see `hoverBleed`. Neither the row nor the stack masks to bounds, so
        // it renders into the panel's inset as intended.
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        addSubview(highlight)
        addSubview(lamp); addSubview(name); addSubview(callsign)
        // A grid with no minted callsigns collapses the column entirely —
        // no phantom 12pt gutter on the right.
        let gutter: CGFloat = auxWidth > 0 ? 12 : 0
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            // Wider than the row on both sides, and inset vertically so it
            // reads as a pill between the rules rather than a band welded to
            // them. The 2pt keeps the hairline rule visible under a hovered row.
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: -Self.hoverBleed),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                constant: Self.hoverBleed),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            lamp.widthAnchor.constraint(equalToConstant: Lamp.diameter),
            lamp.heightAnchor.constraint(equalToConstant: Lamp.diameter),
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor),
            lamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: Self.lampColumn),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: callsign.leadingAnchor,
                                           constant: -gutter),
            callsign.trailingAnchor.constraint(equalTo: trailingAnchor),
            callsign.centerYAnchor.constraint(equalTo: centerYAnchor),
            callsign.widthAnchor.constraint(equalToConstant: auxWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    /// The hover pill. Held so hover can paint it rather than the row's layer,
    /// which could only ever be exactly as wide as the content.
    private let highlight = NSView()

    /// Held so the drill can read the read-state channel back off a built
    /// row: fill present means unread, absent means opened.
    private(set) var lampLayer: CALayer?

    /// Held so the launch drill can read the weight back off a built row —
    /// the weight IS the read state now (unread semibold, opened medium),
    /// and a drill that cannot see it would be asserting a sort order about
    /// pixels it never checks.
    let nameLabel: NSTextField
    /// The name's ink at rest, so the hover step has something to return to.
    /// Read once at build: a row is rebuilt whenever its state changes, so a
    /// stale value cannot outlive the ink it describes.
    private lazy var restingName: NSColor = nameLabel.textColor ?? StateLegend.Palette.ink

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// A row lights in BOTH registers (ruled 18 Aug): the wash says which
    /// region the click lands in, and the name steps one hover distance so the
    /// row reads as LIT rather than as a grey box with the same words on it.
    ///
    /// Measured, because the question was whether the wash is enough: the wash
    /// is ΔL* 4.6 from the surface — the same distance a hovered word travels —
    /// so its advantage over text was never contrast, it was area. Area alone
    /// is what makes a hover feel cheap.
    ///
    /// The wash stays, though, and not out of taste: this is a non-activating
    /// panel, cursor rects only fire while the app is active, and on the common
    /// path — you in Terminal, the panel on screen — the pointer never becomes
    /// a hand. On that path the wash is the only cue there is, and a region is
    /// what it is cueing.
    /// The row lights its WORDS, and nothing else (ruled 18 Aug — "let's prefer
    /// that text hover on the agent grid list").
    ///
    /// The wash is gone. What it bought was area, not contrast — measured at
    /// ΔL* 4.6 from the surface, the same distance the name travels — and the
    /// cost was that a list of eight rows answered the pointer with a grey box
    /// instead of with the row.
    ///
    /// Worth knowing, because it is the one thing this treatment gives up: ink
    /// brightness on this grid ALSO carries read state — an unread row rests at
    /// full ink, an opened one below it — so a hovered opened row now lands
    /// about where an unread row rests. The lamp still separates them (solid
    /// unread, hollow opened) and the hover is transient, so it reads as
    /// pointer feedback rather than as a state; if it ever reads as ambiguous,
    /// the answer is an underline — a shape rather than a tier, which is what
    /// the card title already does at the top of the ramp.
    func setHovered(_ on: Bool) {
        nameLabel.textColor = on ? StateLegend.hovered(restingName) : restingName
    }

    /// Rule 1 of the hover standard: the wash says WHICH row the pointer is on,
    /// and the cursor says the row is a control at all. The wash alone cannot —
    /// the list has always lit its rows, and a lit row still reads as a
    /// read-state change to anyone who has not already learned otherwise.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// "Mischief managed" (ruled 06 Aug): clicking a lit lamp switches it off —
    /// marks the turn heard without inviting the session. Set only on rows
    /// whose lamp is lit; nil means the lamp column is just part of the row.
    var onLampTap: (() -> Void)?

    // A cell-less NSControl tracks nothing by default; the whole row is the
    // hit target, and the tap lands on mouse-up like any button's would.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // The lamp is its own target when it is live: `lampHitWidth` at full
        // row height, not the 9px dot — a click target the size of the glyph
        // would be a trap, and this is the switch that mutes an agent.
        if let onLampTap, point.x <= Self.lampHitWidth {
            onLampTap()
            return
        }
        sendAction(action, to: target)
    }
}
