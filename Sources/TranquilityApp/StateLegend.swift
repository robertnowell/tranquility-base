import AppKit
import TranquilityCore

/// The single source of truth for how every panel state presents itself.
///
/// Before this file, the state glyphs lived as a dozen scattered string literals
/// inside StatusHUD, and the hint-text chain was pasted verbatim in two places that
/// could only drift apart. This is a centralization pass, not a redesign: every
/// glyph, label, hint and color below is EXACTLY what the panel rendered before the
/// file existed. A later work stream may retune them; this one must not.
///
/// Grep contract: the state glyph characters (◌ ◀ ▶ ⚠ → ● ‹ › ✓ ✗) are
/// defined here and nowhere else in this module.
@MainActor
enum StateLegend {

    // MARK: - Glyphs

    /// Every state glyph in the app, defined once.
    enum Glyph {
        /// Quiet/ambient states: ready, preparing, working, the waiting count, and
        /// the menu-bar placeholder before the SF Symbol loads.
        static let quiet = "◌"
        static let speaking = "◀"
        /// The breadcrumb, on a face that is NOT the speaking card. Same mark,
        /// because it is the same promise — this pill is the door back to the
        /// grid — and the panel has exactly one mark for that promise.
        static let home = "◀"
        /// Menu status lines and the dictation-receipt pill (ui-pass-7,
        /// ruling 5). The reply-send Sent face stays dead.
        static let sent = "▶"
        static let needsYou = "⚠"
        /// Direction of travel: pending sends and dictation destinations.
        static let routing = "→"
        /// The live dot: the listening pill, the busy menu-bar text fallback, and
        /// the onboarding permission dot.
        static let dot = "●"
        static let back = "‹"
        static let forward = "›"
        /// Also the "granted" mark in the menu's permission rows.
        static let confirm = "✓"
        static let denied = "✗"
    }

    // MARK: - Palette (the ruled design: dark console, MOCR identity v1)

    /// The panel's entire palette, defined once. Semantic NSColor is dead in the
    /// panel: the surface is an opaque console on EVERY face, so system
    /// appearance must never flip a text color against it — every color the
    /// panel paints comes from here, in absolute sRGB.
    ///
    /// RE-RULED 09 Aug: the console is dark. The light putty it replaces was not
    /// wrong by taste, it was wrong by arithmetic. On a light panel every element
    /// must be DARKER than the panel to be seen, so the surface's own lightness
    /// is the entire contrast budget, drawn on by the four ink tiers, three lamps
    /// and the amber simultaneously. Measured on the shipping putty (L* 78.6),
    /// `faint` sat at 2.13:1 against a 4.5:1 floor for small text and `fault` at
    /// 1.72:1 against 3:1 — both already failing, unnoticed, for the life of the
    /// build. Dimming the putty for comfort (repeatedly asked for, correctly)
    /// only shortens that budget: 45 points of usable range at L* 78.6, 29 at
    /// L* 60. There is no light surface where the ramp and the lamps both fit.
    ///
    /// On the dark ground the budget sits ABOVE the surface and is larger —
    /// 14.10:1 of room against the bright putty's 1.77:1 — and every floor
    /// clears with margin. See docs/ruling-the-console-goes-dark.md for the
    /// measurements and the experiments they came from.
    ///
    /// The lamp pair is green + blue and stays that way: purple measured further
    /// apart on every discriminability metric and was rejected anyway, because
    /// purple does not read as *becoming* green. Adjacent states in a process
    /// want adjacent hues; the separation is bought in LIGHTNESS, which is the
    /// channel that survives at 9px (ΔE2000 said the old pair was 12× above the
    /// perceptibility threshold while being invisible in practice — at this size
    /// ΔE predicts nothing and ΔL* predicts everything).
    enum Palette {
        private static func hex(_ v: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                    green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
        }

        // Contrast figures below are WCAG ratios against `surface`, measured.

        /// The console housing. Opaque, panel-wide: an instrument guarantees its
        /// own contrast; blur borrowed the desktop's and couldn't.
        static let surface = hex(0x2A2C28)
        /// Text ink — card prose and grid row names. 8.39:1. Deliberately NOT
        /// the brightest available: at 11.15:1 the card read as shouting, and
        /// APCA (which, unlike the WCAG ratio, is polarity-aware) put it at
        /// Lc −86.7 against the light card's Lc 63.4 — 37% more perceptual
        /// contrast, spent only because the budget was there. This value is
        /// Lc −69.0. Also the base every hairline derives from.
        static let ink = hex(0xC9C8BF)
        /// Secondary ink: strip labels, ready-row topics. 6.69:1.
        static let secondary = hex(0xB4B3A9)
        /// Muted: quiet-row topics, retired sessions. 5.30:1.
        ///
        /// Sits between `secondary` and `hint` deliberately. It was 0x93928A at
        /// 4.51:1, which cleared its own floor and still broke the ramp — `hint`
        /// measured 4.57:1, so the two tiers were inverted and "muted" was the
        /// more legible of the pair. Caught by the contrast drill on its first
        /// run, which is the entire argument for having one: every token passed
        /// its individual floor, and the hierarchy was still wrong.
        static let muted = hex(0xA09F96)
        /// The RESTING intensity: any row that is not asking for you — heard,
        /// or with no waiting turn at all. `ink` is reserved for the rows
        /// that are, and that is the whole hierarchy (16 Aug).
        ///
        /// It stays a MODEST step, and that is the ruling rather than an
        /// oversight (16 Aug). Brightness cannot carry the read state alone:
        /// measured off the rendered panel, unread ink is 199 and a row whose
        /// session is GONE is 129, so any dimming strong enough to notice
        /// lands on top of the gone row and the panel starts telling you a
        /// live agent has exited — "turned off is turned off". The visible
        /// half of the read state is therefore the LAMP (solid unread, hollow
        /// opened, see GridRowView), which is orthogonal to death; this ink
        /// step only seconds it. Turning this token down the ladder is the
        /// wrong lever — it was tried at `muted` and rendered a live opened
        /// row dimmer than a dead one.
        static let restingInk = secondary
        /// The hint line and placards — small text, so it owes the 4.5:1 text
        /// floor and now meets it at 4.57:1. Split out of `faint` (09 Aug):
        /// one token was being asked to be both a legible hint and a recessive
        /// decoration, and could not be both. That is why the key line has
        /// always looked mushy.
        static let hint = hex(0x94938A)
        /// Faint — DECORATIVE ONLY, no contrast floor: the gear at rest, rules
        /// and separators. Never small text. 2.18:1 by design.
        static let faint = hex(0x5E5F58)
        /// Hairline — ink at 25%: the strip border and the hint's top rule.
        static let hairline = hex(0xC9C8BF, alpha: 0.25)
        /// Soft hairline — ink at 12%: the rule between grid rows.
        static let hairlineSoft = hex(0xC9C8BF, alpha: 0.12)
        /// Hover row — surface, one step UP. The direction inverts with the
        /// ground: on putty a hover went darker, on housing it goes lighter.
        static let hover = hex(0x343631)

        /// The quiet lamp's fill — an unlit socket, 1.45:1. Not a compromise:
        /// dark-cockpit doctrine says the panel is dark when all is nominal and
        /// a lit lamp always means deviation. On this ground that falls out of
        /// the arithmetic instead of being imposed on it.
        static let socket = hex(0x43453F)
        /// Ready green — the console "go" lamp. 6.35:1, the brightest lamp on
        /// the panel, because it is the rare one that actually wants you.
        /// Accent = state: this replaces controlAccentColor for the ✓ send
        /// button and the ack pulse.
        static let ready = hex(0x6FBF83)
        /// Working blue — the agent has work in hand. 3.10:1: deliberately the
        /// DIMMEST lamp, clearing its floor and no more. Ruled 09 Aug against
        /// a brighter variant, on the busy panel: working is the state you are
        /// in most of the time, and seven bright dots is a lit-up panel rather
        /// than a hierarchy. Emphasis and calm are opposable on a dark ground
        /// in a way the light ground could not offer — there, contrast only ran
        /// one direction, so dimming a lamp just made it harder to see.
        static let working = hex(0x527A9C)
        /// Fault amber — stopped on something it cannot pass alone. 6.43:1,
        /// up from 1.72:1 on the putty, where the needs-you channel was the
        /// least visible thing on the panel.
        static let fault = hex(0xE0A44A)
        /// Advisory accent for optional affordances — GO TO AGENT. 3.41:1 and
        /// dimmed at the call site: the card's focal point is the prose and the
        /// actions are keyboard, so the one navigation the panel owns is a door,
        /// not a verb. On the dark ground a saturated accent inverts that
        /// hierarchy outright; this one recedes under the text.
        static let accent = hex(0x6E7F8C)
        /// `accent` with the pointer on it. 4.94:1, ΔL* 10.9 above its resting
        /// value — the accent's own rung on the hover ramp, because the ink
        /// ladder below is neutral and stepping a blue-grey control onto it
        /// would change its HUE on hover, which the standard forbids (see
        /// `hovered` and docs/ruling-the-panel-answers-the-pointer.md).
        static let accentHover = hex(0x8B9BA8)

        // MARK: The light console, kept for the swap
        //
        // Not dead code — the measured light half of the same design, held here
        // so the panel can go back or grow a second theme without re-deriving
        // it. These values pass every floor a LIGHT ground can pass; the ones
        // that cannot are called out. Surface is #BCBBB0 (L* 75.7, −3 from the
        // original putty: enough to take the glare off without spending budget
        // the ramp needs).
        //
        //   surface       0xBCBBB0     ink           0x23241F   8.09:1
        //   secondary     0x4A4B43     4.57:1        muted      0x4E4F47
        //   hint          0x494A42     4.52:1        faint      0x7B7C72  deco
        //   hover         0xB4B3A8     socket        0xB4B3A8
        //   ready         0x3F6A4A     3.22:1        working    0x374F67   4.39:1
        //   fault         0x8A5410     3.24:1        accent     0x5A6B7A
        //
        // Two notes for whoever swaps them. The lamp step inverts: on light the
        // working lamp must be DARKER than ready to recede (ΔL* 8.3), on dark it
        // is dimmer, and the hex tables are not interchangeable row for row.
        // And `socket` equals `hover` on light because an unlit lamp against
        // putty has to be carried by its ring — there is no "off" that reads as
        // off on a light ground, which is half of why the console went dark.
    }

    // MARK: - Hover

    /// The ink ladder, dimmest first. Named as a sequence because the hover
    /// standard is expressed as a POSITION on it — "one step up" — and a rule
    /// stated as a lookup table drifts control by control the first time
    /// somebody picks a colour they like.
    ///
    /// `faint` is on the ladder even though it owes no contrast floor: it is a
    /// resting value only, and a control resting there steps onto `hint`, which
    /// does owe one. Nothing rests at `ink` — see the standard's fourth rule.
    static let inkRamp: [NSColor] = [
        Palette.faint, Palette.hint, Palette.muted, Palette.secondary, Palette.ink,
    ]

    /// What an ink becomes while the pointer is on it: one step up its own
    /// ramp, and nothing else — no lozenge, no move, no change of hue.
    ///
    /// Returns the resting value unchanged for an ink with no step above it,
    /// which is the signal that the control is resting too bright. `ink` is
    /// content's; a control that rests there has nowhere to go and gets no
    /// hover at all, so the standard's fourth rule ("no control rests at
    /// `ink`") is enforced by this returning the same colour rather than by
    /// anybody remembering it.
    static func hovered(_ resting: NSColor) -> NSColor {
        if resting == Palette.accent { return Palette.accentHover }
        guard let step = inkRamp.firstIndex(of: resting), step + 1 < inkRamp.count
        else { return resting }
        return inkRamp[step + 1]
    }

    /// Every run of an attributed string, one step up the ink ramp.
    ///
    /// The string form of `hovered(_:)`, for the two hover targets that carry
    /// attributed text rather than a tint: the state pill (whose mark and word
    /// are separate runs, and whose amber must stay amber) and the placard
    /// words. `ConsoleButton` reaches the same ramp through `restingInk`.
    ///
    /// One ramp, deliberately. A second one shipped here for half an hour on
    /// 18 Aug — a 35%-toward-ink blend, written in parallel with this file's
    /// discrete steps by a session that had not seen them — and two definitions
    /// of "one step brighter" is precisely the drift the ramp exists to stop.
    static func hoveredInk(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        out.enumerateAttribute(.foregroundColor,
                               in: NSRange(location: 0, length: out.length)) { value, range, _ in
            let colour = (value as? NSColor) ?? Palette.hint
            out.addAttribute(.foregroundColor, value: hovered(colour), range: range)
        }
        return out
    }

    // MARK: - The palette's own evidence

    /// Contrast arithmetic, so the ruling's numbers are ASSERTED rather than
    /// remembered.
    ///
    /// Every figure in docs/ruling-the-console-goes-dark.md was computed by hand,
    /// once. Hand-computed numbers rot the first time someone warms a hex by four
    /// points to taste — and the failure is invisible, because a colour that has
    /// slipped under its floor still renders. That is exactly how `faint` shipped
    /// at 2.13:1 and `fault` at 1.72:1 for the life of the light console without
    /// anyone noticing.
    ///
    /// `swift test` cannot help here (CLAUDE.md rule 7: it says nothing about the
    /// panel), so the floors ride the launch self-tests, which `relaunch.sh`
    /// already gates on.
    enum Measure {
        /// WCAG relative luminance. Tokens are minted in absolute sRGB, so the
        /// conversion is a formality — but an alpha-blended token has no
        /// meaningful luminance of its own and must never be measured.
        static func relativeLuminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            func channel(_ v: CGFloat) -> CGFloat {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent)
                 + 0.7152 * channel(c.greenComponent)
                 + 0.0722 * channel(c.blueComponent)
        }

        /// WCAG contrast ratio, always ≥ 1 whichever way round the pair is given.
        static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let (x, y) = (relativeLuminance(a), relativeLuminance(b))
            let (hi, lo) = x > y ? (x, y) : (y, x)
            return (hi + 0.05) / (lo + 0.05)
        }

        /// CIE L*. The lamps are separated in LIGHTNESS, not hue — at 9px
        /// ΔE2000 said the old green/blue pair was twelve times above the
        /// perceptibility threshold while being invisible, and ΔL* said 4.2.
        /// So ΔL* is the quantity worth defending.
        static func lightness(_ color: NSColor) -> CGFloat {
            let y = relativeLuminance(color)
            return y > 0.008856 ? 116 * pow(y, 1.0 / 3.0) - 16 : 903.3 * y
        }

        static func lightnessGap(_ a: NSColor, _ b: NSColor) -> CGFloat {
            abs(lightness(a) - lightness(b))
        }
    }

    /// Every contrast floor the ruling bought, as data rather than prose.
    ///
    /// Text floors are WCAG 1.4.3 (4.5:1 at these sizes; 7:1 for the body ink we
    /// chose to hold higher). Lamp floors are 1.4.11's 3:1 for non-text state
    /// information. `faint` is absent on purpose — it is decorative by ruling and
    /// owes nothing, which is the whole reason it was split off `hint`.
    static var contrastFloors: [(name: String, ink: NSColor, floor: CGFloat)] {
        [("ink", Palette.ink, 7.0),
         ("secondary", Palette.secondary, 4.5),
         ("muted", Palette.muted, 4.5),
         ("hint", Palette.hint, 4.5),
         ("ready", Palette.ready, 3.0),
         ("working", Palette.working, 3.0),
         ("fault", Palette.fault, 3.0),
         ("accent", Palette.accent, 3.0),
         // A hover value is read for as long as the pointer sits on it, which
         // is longer than a resting placard is read; it owes the text floor
         // even where its resting value did not.
         ("accentHover", Palette.accentHover, 4.5)]
    }

    /// The lamp separation the busy panel was ruled on. Below this the ready and
    /// working lamps start collapsing into each other at 9px again.
    static let lampLightnessFloor: CGFloat = 6.0

    // MARK: - Lenses

    /// A semantic role, not a color. Each lens maps into the Palette — the one
    /// place the mapping can change. No lens reaches for a semantic NSColor:
    /// the opaque surface must read identically whatever the system appearance
    /// is doing.
    enum Lens {
        /// Chrome: the state pill and secondary controls.
        case chrome
        /// Primary content: titles and body text.
        case content
        /// De-emphasized guidance: the hint line.
        case guidance
        /// Calls to action: state-green controls (accent = state, ruled).
        case action
        /// Something needs you. The amber channel — the silence gate's notice.
        case fault
        /// News you may ignore. MIL-STD-411's advisory channel: not red, not
        /// green, nothing for you to do. The held-hail notice lives here, and
        /// shares the working lamp's blue on purpose — both mean "something is
        /// happening that is not your move."
        case advisory

        var color: NSColor {
            switch self {
            case .chrome: return Palette.secondary
            case .content: return Palette.ink
            // `hint`, not `faint`, since the split (09 Aug): guidance is small
            // TEXT and owes the 4.5:1 floor. Pointing this at `faint` is what
            // shipped the key line at 2.13:1.
            case .guidance: return Palette.hint
            case .action: return Palette.ready
            case .fault: return Palette.fault
            case .advisory: return Palette.working
            }
        }
    }

    /// Whether being in the state involves the app making sound. Descriptive today
    /// (nothing consults it yet); WS-A's announcement tiers will.
    enum SpeakTier {
        /// The app is speaking, or about to.
        case speaks
        /// Visual only.
        case silent
    }

    // MARK: - Rows

    /// One row of the legend: how a display situation presents itself.
    /// `showsControls` is dead (simplification pass): the button row died with
    /// it — the action row's visibility now derives from whether any quiet
    /// action is actually visible, in render().
    struct Row {
        /// Full state-pill text, glyph included, verbatim.
        let stateText: String
        let glyph: String
        let lens: Lens
        let speakTier: SpeakTier
    }

    // MARK: - Session grid (WS-B)

    /// The state lamp on a grid row: a 9px CIRCLE (ruled — squares read as
    /// checkboxes), flat fill, no gradients or shadows. Ready is filled console
    /// green; quiet is the hover putty with a hairline ring so it reads as a
    /// socket, not an absence.
    ///
    /// Mapping is limited to what is derivable today: a session in the waiting set
    /// is `.ready`; any other live session is `.running`. `.fault` is defined so
    /// the seam is complete, but nothing observable emits it yet — inventing a
    /// fault state the app cannot actually see is worse than omitting the color.
    enum Lamp: Equatable {
        /// Green: waiting on you.
        case ready
        /// Advisory blue: the agent has work in hand right now (ruled 06 Aug —
        /// "we have no indicator if the agent is actually working or idle").
        /// Blue because MIL-STD-411's advisory channel is exactly this: news,
        /// nothing for you to do. Solid, never blinking — a room full of
        /// blinking lamps is the opposite of calm.
        case working
        /// Quiet: alive, turn complete, nothing in flight.
        case running
        /// Amber: stopped on something it cannot pass on its own — a usage
        /// limit, a dead API. Amber is the needs-you channel.
        case fault
        /// No lamp at all: the session exited, or the liveness probe could not
        /// say. Ruled 11 Aug — an agent does not stop existing when its process
        /// ends, so it keeps its row; but nothing is running behind that lens,
        /// so nothing lights it.
        ///
        /// Deliberately NOT a fifth colour. v1.1 ruled against a "we don't
        /// know" hue and that stands: this is the ABSENCE of one, an empty
        /// socket against `running`'s unlit-but-seated lamp. That is also the
        /// distinction asked for on 11 Aug between an idle session and an
        /// exited one, and it is drawn in the one channel that cannot be
        /// confused with a state — presence.
        case unlit

        /// Lamp diameter — 9px circle, ruled.
        static let diameter: CGFloat = 9

        var fill: NSColor {
            switch self {
            case .ready: return Palette.ready
            case .working: return Palette.working
            case .running: return Palette.socket
            case .fault: return Palette.fault
            case .unlit: return .clear
            }
        }

        /// The hairline ring; nil when the fill carries the lamp alone.
        var ring: NSColor? {
            switch self {
            case .ready, .fault, .working: return nil
            case .running: return Palette.hairline
            // Fainter than the seated lamp's ring, and with nothing inside it.
            case .unlit: return Palette.hairlineSoft
            }
        }

        /// A row whose session is gone reads at reduced ink. The lamp says
        /// "not running"; the type says "and not now".
        var rowAlpha: CGFloat { self == .unlit ? 0.55 : 1 }

        /// Whether this lamp's row is ASKING the user for something — and so
        /// whether the read state is worth showing on it at all.
        ///
        /// The read state answers "have I heard this thing I owe an answer
        /// to". A row that owes nothing has no such question, and painting one
        /// on it is noise: `working` is defined two dozen lines up as
        /// MIL-STD-411's ADVISORY channel, "news, nothing for you to do", so a
        /// hollow blue ring was the panel contradicting its own legend — an
        /// advisory lamp cannot be read or unread, it is just news. Same for
        /// `running` (alive, nothing in flight) and `unlit` (gone).
        ///
        /// Green and amber are the two channels that ask: `ready` is "waiting
        /// on you", `fault` is the needs-you channel. Only they carry it.
        /// Ruled 16 Aug — "idk that blue should be empty circle?" — and the
        /// legend had said so all along.
        var asksForYou: Bool { self == .ready || self == .fault }
    }

    /// Has this row's turn been heard — and does it even HAVE a turn?
    ///
    /// This was a `Bool` named `unread`, defaulting to true, and the default
    /// was a lie with a visible consequence (16 Aug). A row with no waiting
    /// turn at all — an idle session, a past agent just sitting there — is
    /// not "unread"; it is asking nothing. Defaulting it to unread rendered
    /// it at full attention intensity, so an idle session in Past Agents
    /// outshone an ACTIVE session you had already heard: "the idle sessions
    /// should not be brighter than read active sessions". Two states could
    /// not say that, because the question has three answers.
    enum ReadState {
        /// A turn is waiting and you have not heard it. The only tier that
        /// gets full ink, because it is the only one asking for you.
        case unread
        /// Heard, still owed an answer (read is not answered, 12 Aug).
        case opened
        /// No waiting turn. Renders at the SAME intensity as `opened` — both
        /// mean "nothing new here" — and is separated from it by the lamp
        /// alone, which is the channel that already says what a session is
        /// doing.
        case none

        /// Intensity is a two-tier question even though the state is three:
        /// are you being asked for, or not.
        var isAsking: Bool { self == .unread }
    }

    /// One row of the idle grid: a session, its lamp, and its callsign.
    /// Equatable so the intake timer can refresh the grid only when content
    /// actually changed, not on every poll.
    struct SessionRow: Equatable {
        let id: String
        /// The displayed identity: the tab's string (see displayName).
        let name: String
        /// The right column. RE-RULED 12 Aug: the session's own short id, in
        /// the shape of a commit hash — because the question this column has to
        /// answer changed. It held the minted callsign so eye and ear shared
        /// one identity (05 Aug: hear "home sessions", find "home sessions"),
        /// which is right when every row is a session you are talking to. It is
        /// not right once the panel and its list are full of sessions you are
        /// trying to FIND: "there is a workstream I did a week ago and I don't
        /// know which tab it is in" is answered by an identifier, not a name.
        ///
        /// The callsign is not lost — it is still the spoken identity, still
        /// minted, and still the fallback for `name` when a session has no tab
        /// title yet. It simply stops being the thing this column shows.
        ///
        /// A stopped session shows its REASON here instead. Amber is the
        /// needs-you channel and the reason is the entire message; an id would
        /// be the one row where this column says nothing useful.
        let aux: String
        let lamp: Lamp
        /// Whether tapping this row brings the session back — `claude --resume`
        /// in its own directory.
        ///
        /// NOT simply "the lamp is unlit". It requires POSITIVE evidence the
        /// process is gone, plus a directory that still exists. A probe that
        /// failed proves nothing, and resuming a session that is still running
        /// leaves the original process alive and adds a second live entry under
        /// the same id, which crashed the app twice (06 Aug 14:35, 07 Aug
        /// 17:39). So an unproven row shows unlit and offers nothing, and the
        /// two failure directions are opposite ON PURPOSE: the display fails
        /// toward showing you the work, the verb fails toward doing nothing.
        let revivable: Bool
        /// Where this row sits in the read ladder.
        let read: ReadState

        init(id: String, name: String, aux: String, lamp: Lamp,
             revivable: Bool = false, read: ReadState = .none) {
            self.id = id
            self.name = name
            self.aux = aux
            self.lamp = lamp
            self.revivable = revivable
            self.read = read
        }
    }

    /// Quiet rows sink (ruled 10 Aug). A session that is merely alive never
    /// interleaves with sessions that are doing something.
    ///
    /// The bands above this already had an order — waiting first, then stored
    /// sessions by recency, then the unranked newcomers — but `.running` rows
    /// were scattered through the last two, so an idle session could sit between
    /// two working ones. That reads as a gap rather than a row, and it got worse
    /// when the console went dark: an unlit socket mid-list looks like the grid
    /// dropped a line.
    ///
    /// Deliberately a stable partition and not a `sorted(by:)` — Swift's sort is
    /// not guaranteed stable, and every band above this one is carrying an order
    /// somebody chose (recency, mostly). A comparator that reshuffled ties would
    /// silently spend the ordering the rest of this file works to produce.
    ///
    /// Only `.running` moves. Whether `.fault` should outrank `.working` is a
    /// real question and not this ruling's: nothing here claims the active band
    /// is correctly ordered, only that the quiet band is not part of it.
    /// What a tap on a row does. One tap, two verbs, and a third case that is
    /// the whole safety story.
    ///
    /// Stated as a function rather than as a branch inside the click handler so
    /// it can be asserted by a drill without a window server, which is the only
    /// evidence the panel layer has.
    enum RowAction: Equatable {
        /// Live: hear what it has to say.
        case announce
        /// Amber: stopped on something it cannot pass alone, so the only useful
        /// thing this app can do is put you in front of it (ruled 18 Aug).
        ///
        /// Announcing an amber row was the wrong verb twice over. A blocked
        /// session is not in the waiting set — it has no unread turn — so the
        /// announcement had nothing to say and the panel sat on Preparing; and
        /// even when it did speak, hearing "it cannot reach the API" is not the
        /// move. The reason is already on the row, in the column where every
        /// other row shows its id. What is missing is the tab, and that is the
        /// one thing a tap can hand you.
        case goToAgent
        /// Proven gone, and its directory is still there: bring it back.
        case revive
        /// Unlit but unproven — the probe could not answer, or the directory is
        /// gone. Doing nothing is the correct outcome, NOT falling through to
        /// announce: a `--resume` against a session that is actually alive puts
        /// two processes under one id, and that crashed the app twice.
        case none
    }

    static func action(for row: SessionRow) -> RowAction {
        switch row.lamp {
        case .fault: return .goToAgent
        case .ready, .working, .running: return .announce
        case .unlit: return row.revivable ? .revive : .none
        }
    }

    /// Is there a process behind this row — the question END SESSION and GO TO
    /// AGENT both have to answer.
    ///
    /// Asked through `action(for:)` rather than off the lamp, so the menu and
    /// the left-click can never drift into disagreeing about which rows are
    /// alive. That drift is not hypothetical: offering to kill a process we
    /// cannot see is a control that can only lie, and the menu used to test
    /// `== .announce` — which stopped meaning "live" the moment amber got its
    /// own verb.
    static func isLive(_ row: SessionRow) -> Bool {
        switch action(for: row) {
        case .announce, .goToAgent: return true
        case .revive, .none: return false
        }
    }

    /// Three bands now, not two. Sessions doing something, then sessions merely
    /// alive, then sessions that have exited — which sink below both, because
    /// a row you cannot speak to must never sit between two you can.
    ///
    /// Order WITHIN each band is untouched: the caller has already established
    /// recency, and a stable partition keeps it.
    static func quietRowsLast(_ rows: [SessionRow]) -> [SessionRow] {
        func band(_ lamp: Lamp) -> Int {
            switch lamp {
            case .ready, .working, .fault: return 0
            case .running: return 1
            case .unlit: return 2
            }
        }
        return (0...2).flatMap { rank in rows.filter { band($0.lamp) == rank } }
    }

    /// The one DISPLAYED identity — RE-RULED 05 Aug (twice): the terminal
    /// tab's string wins wherever we have it. The constraint is literal — the
    /// string on screen is the string in the tab, checkable at a glance,
    /// maintained by nobody. `liveName` is therefore the transcript's last
    /// ai-title (TranscriptTitles), NOT `agents --json`'s name: that field is
    /// a derived slug ("robertnowell-90") for unnamed sessions, and the tab
    /// never shows it. The minted callsign is the fallback for display, and
    /// remains the SPOKEN identity outright — a hyphenated slug is
    /// unspeakable, and spoken attribution now also rides the session's
    /// durable voice.
    /// A session id in the shape of a commit hash: the leading eight, which is
    /// what every log line, every trace and `tbase discover` already print, so
    /// a row on screen and a line in the log name the same thing the same way.
    /// The leading group rather than the trailing one for exactly that reason —
    /// GitHub shows a commit's first seven, and this codebase has been printing
    /// `sessionId.prefix(8)` since before the panel had a grid.
    static func shortId(_ sessionId: String) -> String { String(sessionId.prefix(8)) }

    static func displayName(liveName: String? = nil, callsign: String?, fallback: String) -> String {
        if let liveName, !liveName.isEmpty { return liveName }
        if let callsign, !callsign.isEmpty { return callsign }
        return fallback
    }

    /// Display situations. Mostly 1:1 with PanelState; the elapsed-seconds
    /// working pill is a display distinction the enum folds into an associated
    /// value. Dead (simplification, ruled): catch-up (never produced
    /// outside the pose driver), paused (⇧ is an audio behavior; the frozen
    /// speaking card IS the pause indication), sent for REPLIES (send success
    /// says nothing), and sendingTo (the READBACK placard carries that face's
    /// pill). `delivered` is the dictation receipt (ui-pass-7, ruling 5): the
    /// one success card left, because it names where the words went.
    enum Situation {
        case ready
        case preparing
        case working
        /// Sanctioned change (open issue #4): transcription with visible elapsed time.
        case workingFor(seconds: Int)
        case speaking
        case listening(target: String)
        case delivered
        case needsYou
        case settings
    }

    /// The pill is a LEGEND, and legends are set in capitals (ruled 18 Aug).
    ///
    /// It was not a rule, it was two lineages meeting on one pill: the state
    /// placards grew as title case ("Speaking", "Needs you") and the ⌃⌃ ladder
    /// rungs came from `RungKind.rawValue`, which is data and has always been
    /// capitals ("SOLUTION", "WHY"). Same pill, same size, same position, two
    /// cases — "is that intentional?" No.
    ///
    /// Capitals, because this is the one place the standard actually asks for
    /// them: HF-STD-001B §5.6.2.5.8.3 allows capitals for "short items to draw
    /// the user's attention to important text (for example, field labels or a
    /// window title)", and a pill naming the face is exactly that. Everything
    /// you READ stays mixed case — §5.13.3.3.7.6 rules capitals out for text —
    /// so the rule the panel now follows is one line: **labels shout, content
    /// does not.** The face labels (AGENTS, PAST AGENTS) already obeyed it; the
    /// state pills do now; a notice is a sentence and never will.
    static func legend(_ text: String) -> String { text.uppercased() }

    static func row(for situation: Situation) -> Row {
        switch situation {
        case .ready:
            return Row(stateText: "\(Glyph.quiet) \(legend("Ready"))", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent)
        case .preparing:
            // The breadcrumb, not the quiet ◌ (ruled 18 Aug). Preparing was the
            // one face on stage with no way off it: the pill was inert, the ◀
            // was absent, and ⌃⌥ walked to the NEXT agent rather than home —
            // "there is no way to get back to the grid". A wait you cannot
            // leave is a trap, and the mark that says you can leave is ◀.
            return Row(stateText: "\(Glyph.home) \(legend("Preparing"))", glyph: Glyph.home,
                       lens: .chrome, speakTier: .silent)
        case .working:
            return Row(stateText: "\(Glyph.quiet) \(legend("Working"))", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent)
        case .workingFor(let seconds):
            return Row(stateText: "\(Glyph.quiet) \(legend("Working")) · \(seconds)s",
                       glyph: Glyph.quiet, lens: .chrome, speakTier: .silent)
        case .speaking:
            return Row(stateText: "\(Glyph.speaking) \(legend("Speaking"))", glyph: Glyph.speaking,
                       lens: .chrome, speakTier: .speaks)
        case .listening(let target):
            return Row(stateText: "\(Glyph.dot) \(target)", glyph: Glyph.dot,
                       lens: .chrome, speakTier: .silent)
        case .delivered:
            return Row(stateText: "\(Glyph.sent) \(legend("Delivered"))", glyph: Glyph.sent,
                       lens: .chrome, speakTier: .silent)
        case .needsYou:
            return Row(stateText: "\(Glyph.needsYou) \(legend("Needs you"))", glyph: Glyph.needsYou,
                       lens: .chrome, speakTier: .silent)
        case .settings:
            return Row(stateText: "\(legend("Settings"))", glyph: "",
                       lens: .chrome, speakTier: .silent)
        }
    }

    // MARK: - Placards (simplification pass)

    /// The readback face's pill, via the Face placardOverride — same mechanism
    /// as the ⌃⌃ ladder-rung pills ("◀ FINDINGS"). Routing glyph because the
    /// words are about to travel.
    static let readbackPlacard = "\(Glyph.routing) READBACK"

    // MARK: - The grid strip and key line (ruled design)

    /// The grid's top-strip label — small caps, letterspaced. There is no
    /// "Ready" pill and no "N waiting" headline on the grid face: the grid IS
    /// the status, and the count lives in the menu bar.
    static let gridStripTitle = "AGENTS"
    /// The grid's bottom key line, in the hint slot — every gesture the grid
    /// answers to, in order. ON PROBATION (simplification pass): the only hint
    /// line left anywhere; the per-card chord hints are dead with no
    /// replacement. See docs/simplification-pass.md.
    static let controlsTitle = "Controls"

    /// The placard face: the state's own label, one step up in weight from the
    /// row beneath it. Named here because two files draw it and a size that
    /// lives in one of them is a size the other one guesses.
    static let placardFont = ChromeType.mono(ofSize: 10, weight: .medium)

    // MARK: - The bottom line's lexicon (ruled 18 Aug)

    /// One face, one size, one case, for every word on a card's or the grid's
    /// bottom row.
    ///
    /// It had three of each. `OPEN REPORT ›` and `GO TO AGENT ›` were the
    /// SYSTEM font, letterspaced, in capitals; `Controls` was monospaced, plain,
    /// in title case; `Tranquility Base` was the system font again at a third
    /// size and tracking. Three treatments in one row of four words, and the
    /// row read as three unrelated things that happened to be adjacent —
    /// "we need to have a little bit of a design system here, otherwise it's
    /// starting to look a little disjoint."
    ///
    /// The face is MONOSPACED because that is already the panel's chrome voice:
    /// the state placards, the grid's callsigns and the Controls note are all
    /// mono, and it was the letterspaced system font in two widgets that was
    /// the exception. The case is TITLE because the placard beside it says
    /// "Speaking", not "SPEAKING", and because a row shouting four things at
    /// once has no way to say which one matters.
    ///
    /// What is left to carry meaning is WEIGHT and INK, which is the whole
    /// point: medium + steel is a door out of the panel, regular + hint is a
    /// word that explains itself. Nothing on this row is green or amber —
    /// those belong to the lamps, and a chrome word wearing a lamp's colour
    /// would be the instrument lying.
    enum BottomLine {
        static let size: CGFloat = 10
        static let tracking: CGFloat = 0.8
        /// A door out of the panel: Go to Agent, Open Hub, Open Report.
        ///
        /// The colour is a parameter with the resting value as its default, so
        /// the hover step (`StateLegend.hovered`) rebuilds a door's title
        /// through this same function instead of a second copy of its type.
        static func door(_ text: String,
                         color: NSColor = Palette.accent) -> NSAttributedString {
            label(text, weight: .medium, color: color)
        }
        /// A word that explains rather than acts: Controls, the wordmark.
        static func quiet(_ text: String, color: NSColor = Palette.hint) -> NSAttributedString {
            label(text, weight: .regular, color: color)
        }
        static func label(_ text: String, weight: NSFont.Weight,
                          color: NSColor) -> NSAttributedString {
            // Through ChromeType so the trailing chevron sits on the cap line
            // like every other mark in the app — it was 0.40pt low, which on a
            // row of four words is exactly the wonk you notice without being
            // able to name.
            ChromeType.line(
                text,
                font: ChromeType.mono(ofSize: size, weight: weight),
                color: color, tracking: tracking)
        }
    }

    /// Title case, because the row does not shout (ruled 18 Aug).
    static let goToAgentTitle = "Go to Agent"
    static let openHubTitle = "Open Hub"
    static let openReportTitle = "Open Report"

    /// What hovering `Controls` reveals, in order of how often you reach for it.
    ///
    /// Probation ended 10 Aug: the key line — four chords spelled out along the
    /// bottom of every grid, permanently — collapses to one word that reveals
    /// them on hover. A hint that is always on screen is either being read
    /// every time, which means the gestures never stuck, or never, which means
    /// it is decoration billed to the calmest surface the app has. It was the
    /// second. One word holds the door open at the cost of one word.
    ///
    /// Three lines, not four. `⌃⇧` came off the list — "I've never used
    /// Control+Shift to dismiss. What does dismiss even do?" — and the
    /// complaint was right about the LINE while being wrong about the chord,
    /// which is why it stayed confusing. The line advertised the redundant
    /// half: dismissing a card is something you can see and click, and the
    /// click is smarter than the chord (it picks `hide()` from a resting grid
    /// and the full teardown from a live one). The chord's load-bearing half —
    /// cancelling a transcription in flight, the only exit that exists before
    /// the Cancel button appears at ~20s — the line never mentioned at all. So
    /// the word is gone and the key is not. A session that "finishes the
    /// cleanup" by deleting `Bindings.dismiss` re-opens a bug that was closed
    /// on purpose; the honest prerequisite is showing Cancel from the first
    /// second.
    /// Each key is named as well as drawn (ruled 18 Aug). The glyphs are what
    /// is printed on the keyboard and the names are what people call them, and
    /// only one of those two can be READ by someone who has not already learned
    /// the other: ⌃ is widely taken for a caret and ⌥ for a decoration, so a
    /// note whose entire job is teaching three gestures was spelling them in the
    /// alphabet you need the note to learn. Every shortcut UI that works does
    /// this — Wispr Flow prints "^ Ctrl" and "⌘ Cmd" in its key caps — and the
    /// name costs one word on a line that had room for it. `⌃⌃` becomes "twice"
    /// rather than a doubled glyph for the same reason: the repetition was
    /// carrying the meaning "tap it twice" and nothing said so.
    static let controlsNote: [(chord: String, meaning: String)] = [
        ("⌃ Ctrl + ⌥ Option", "hear the next agent update"),
        ("hold ⌥ Option", "speak"),
        ("⌃ Ctrl twice", "hear more"),
    ]

    /// The panel signs its own bottom-right corner (ruled 10 Aug: "subtle but
    /// noticeable"). It balances `Controls` across a line that would otherwise
    /// be a word alone in a corner, and it is the expanded grid's half of the
    /// identity the collapsed strip already carries as a stacked glyph.
    ///
    /// Set in `hint`, the same ink as `Controls`, NOT in `faint`: `faint` is
    /// ruled decorative-only with no contrast floor and explicitly "never small
    /// text", and a wordmark is small text. Subtlety is bought with
    /// letterspacing and stillness instead — `Controls` brightens to `ink`
    /// under the cursor and the signature never does, so the pair reads as one
    /// live thing and one dead one at identical contrast.
    static let wordmark = "Tranquility Base"
    /// The quiet placard row above the hint. "AGENT", not "SESSION" (ui-pass-7,
    /// ruling 1): every user-facing noun on the panel says agent.
    static let newAgentTitle = "NEW AGENT"
    /// The other half of the same row: not starting an agent, but bringing one
    /// back. Ruled 12 Aug.
    static let pastAgentsTitle = "PAST AGENTS"

    /// The empty room's one sentence (ruled 08 Aug). It replaces the grid
    /// outright rather than joining it: with nothing to list, the panel's job is
    /// to teach the one gesture that starts everything, and every other element
    /// on that face — the app's own name, the Ready pill, the key line naming
    /// four chords — is complexity charged to someone who has not yet used one.
    ///
    /// Spelled out, deliberately. The glyph vocabulary (⌃⌥) is compression that
    /// only pays once you already know what it compresses; on the one surface
    /// whose entire purpose is a first press, "Control + Option" is the version
    /// that can be READ. `gridHint` keeps the symbols — by the time the grid has
    /// rows, the reader has pressed the keys.
    static let gettingStartedMessage = "Control + Option to get started"
    /// How long the room stays quietly empty before the sentence appears.
    ///
    /// Not zero: sessions register a beat after launch, and a message teaching
    /// the first press has no business flashing in front of someone whose grid
    /// is about to fill on its own. Ten seconds is long enough that only a
    /// genuinely empty room reaches it.
    static let gettingStartedAfter: TimeInterval = 10

    /// The grid strip's transient amber line, for the refusal that is not a
    /// failure (ruled 08 Aug). It says what happened to the MICROPHONE and
    /// nothing else: no "Nothing sent" (nothing was ever going to be), and no
    /// classification of the agent — "Needs you" is our internal reading of a
    /// session's condition, and no session's condition changed. The triangle
    /// stays: it is the one mark that earns the amber.
    static let noWordsNotice = "\(Glyph.needsYou) No words detected — try again"

    // MARK: - The device fault (ruled 08 Aug)

    /// The third tier's placard. It names the CONDITION, not a classification:
    /// no audio arrived. "Needs you" would be true here and still wrong — it is
    /// the pill a waiting agent wears, and no agent is involved in a dead
    /// microphone.
    static let noAudioPlacard = "\(Glyph.needsYou) No audio"
    static let micSettingsTitle = "Microphone settings"

    // MARK: - The invitation (ruled 10 Aug)

    /// A page outlives the agent that wrote it — after `/clear`, after the tab
    /// closes, and always on someone else's machine. That is not a failure and
    /// must not wear the amber pill: nothing went wrong, and the one thing to
    /// do about it is an offer, not a repair. So the placard is quiet and the
    /// card speaks on the advisory channel.
    static let startSessionPlacard = "\(Glyph.quiet) No agent"
    static let startSessionTitle = "Start a session"

    /// Names the artifact, because that is the whole content of the offer: a
    /// fresh agent is worth starting only if it opens holding the thing you
    /// were reading.
    static func orphanedArtifact(_ name: String, directory: String) -> String {
        "The agent that made \(name) isn't running any more. "
        + "Start one in \(directory) that opens with it?"
    }

    /// Say what to do, not just that something broke — the same rule the
    /// Bluetooth mic-open failure follows, applied to the quieter case where the
    /// device opens successfully and then sends nothing.
    ///
    /// Naming the device is the whole message. "No audio detected" invites you
    /// to blame the app; "Nothing is arriving from AirPods Pro" points at the
    /// thing that is actually wrong, and is usually enough on its own.
    static func noAudioMessage(device: AudioInputDevice.Device?) -> String {
        guard let device else {
            return "The microphone opened, but no input device is bound to it. "
                + "Pick one under Microphone settings."
        }
        if device.isBluetooth {
            return "Nothing arrived from \(device.name) — it opened and then sent "
                + "silence. Bluetooth mics do this when they re-rate themselves; "
                + "switching to the built-in mic is the reliable fix."
        }
        return "Nothing arrived from \(device.name) — the mic was open the whole "
            + "time and the level never moved. Check that it isn't muted, or "
            + "pick a different input."
    }

    // MARK: - Controls

    static let backTitle = "\(Glyph.back) Back"

    // MARK: - Destinations

    /// Dictation destination pills: "→ Terminal", "→ clipboard".
    static func destination(_ name: String) -> String { "\(Glyph.routing) \(name)" }
    static var clipboardDestination: String { destination("clipboard") }

    // MARK: - Slow transcription (sanctioned change: open issue #4)

    static let slowTranscriptionNote = "Taking longer than usual — your audio is safe."
    static let cancelTranscriptionTitle = "Cancel"
    static let retryTranscriptionTitle = "Retry"
    /// After this many seconds of transcribing, say so and offer a way out.
    static let slowTranscriptionThreshold: TimeInterval = 20

    /// What the arrival notification says. One line, no callsign.
    ///
    /// The panel is already on screen with the grid and it names WHICH agent;
    /// repeating that here would be the same information twice, in the louder
    /// channel. This carries one bit — something came back — which is all a
    /// Pavlovian cue can carry anyway.
    static let arrivalChimeTitle = "An agent is ready for you"

    // MARK: - Menu bar

    /// The status item has exactly three states.
    enum MenuBarState { case normal, busy, permissionWarning }

    struct MenuBarAppearance {
        let symbol: String
        /// Used only when the SF Symbol fails to load.
        let textFallback: String
    }

    static func menuBar(_ state: MenuBarState) -> MenuBarAppearance {
        switch state {
        case .normal:
            return MenuBarAppearance(symbol: "waveform.circle", textFallback: "VD")
        case .busy:
            return MenuBarAppearance(symbol: "waveform.circle.fill",
                                     textFallback: "VD\(Glyph.dot)")
        case .permissionWarning:
            return MenuBarAppearance(symbol: "exclamationmark.bubble", textFallback: "VD")
        }
    }

    /// Shown in the instant before the first SF Symbol is set.
    static let menuBarPlaceholder = Glyph.quiet

    /// The annunciator at rest (ruled): the menu-bar item carries the waiting
    /// count as its title next to the symbol; quiet (image only) when nothing is.
    /// The count is always the liveness-filtered one — dead sessions are not
    /// counted anywhere.
    static func menuBarCount(_ waiting: Int) -> String {
        waiting > 0 ? " \(waiting)" : ""
    }

    // MARK: - Readiness, in plain words (sanctioned change b)

    /// User-facing wording for why a session cannot take a reply right now.
    ///
    /// The mapping, case by case:
    /// - `.notRegistered` — alive but absent from `claude agents --json`, which
    ///   verifiably means it is blocked on a dialog (trust/permission prompt) or
    ///   still starting. Injecting would answer the dialog.
    /// - `.targetGone` — the process is gone; there is no tab to type into.
    /// - `.busy` / `.waiting` — these normally dispatch (`canDispatch` is true) and
    ///   should not reach a refusal, but they are named honestly if they ever do.
    /// - `.ready` — unreachable via `sessionNotReady`; named for completeness.
    static func plainWords(for readiness: Readiness) -> String {
        switch readiness {
        case .ready: return "it looks ready"
        case .notRegistered: return "it's blocked on a dialog or still starting up"
        case .busy: return "it's still working on its current turn"
        case .waiting(let what):
            if let what, !what.isEmpty { return "it's waiting on \(what)" }
            return "it's waiting on something in its tab"
        case .targetGone: return "its tab is gone"
        }
    }
}
