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
         ("accent", Palette.accent, 3.0)]
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

        var color: NSColor {
            switch self {
            case .chrome: return Palette.secondary
            case .content: return Palette.ink
            // `hint`, not `faint`, since the split (09 Aug): guidance is small
            // TEXT and owes the 4.5:1 floor. Pointing this at `faint` is what
            // shipped the key line at 2.13:1.
            case .guidance: return Palette.hint
            case .action: return Palette.ready
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

        /// Lamp diameter — 9px circle, ruled.
        static let diameter: CGFloat = 9

        var fill: NSColor {
            switch self {
            case .ready: return Palette.ready
            case .working: return Palette.working
            case .running: return Palette.socket
            case .fault: return Palette.fault
            }
        }

        /// The hairline ring; nil when the fill carries the lamp alone.
        var ring: NSColor? {
            switch self {
            case .ready, .fault, .working: return nil
            case .running: return Palette.hairline
            }
        }
    }

    /// One row of the idle grid: a session, its lamp, and its callsign.
    /// Equatable so the intake timer can refresh the grid only when content
    /// actually changed, not on every poll.
    struct SessionRow: Equatable {
        let id: String
        /// The displayed identity: the tab's string (see displayName).
        let name: String
        /// The minted callsign — the word the voice speaks. RE-RULED 05 Aug
        /// (variant C draft): the right column is the callsign, so eye and ear
        /// share one identity — hear "home sessions", find "home sessions".
        /// The brief topic is dead here (it told you nothing the name doesn't);
        /// ⌃⌃ why still carries it. Empty until minted.
        let callsign: String
        let lamp: Lamp
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

    static func row(for situation: Situation) -> Row {
        switch situation {
        case .ready:
            return Row(stateText: "\(Glyph.quiet) Ready", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent)
        case .preparing:
            return Row(stateText: "\(Glyph.quiet) Preparing", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent)
        case .working:
            return Row(stateText: "\(Glyph.quiet) Working", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent)
        case .workingFor(let seconds):
            return Row(stateText: "\(Glyph.quiet) Working · \(seconds)s",
                       glyph: Glyph.quiet, lens: .chrome, speakTier: .silent)
        case .speaking:
            return Row(stateText: "\(Glyph.speaking) Speaking", glyph: Glyph.speaking,
                       lens: .chrome, speakTier: .speaks)
        case .listening(let target):
            return Row(stateText: "\(Glyph.dot) \(target)", glyph: Glyph.dot,
                       lens: .chrome, speakTier: .silent)
        case .delivered:
            return Row(stateText: "\(Glyph.sent) Delivered", glyph: Glyph.sent,
                       lens: .chrome, speakTier: .silent)
        case .needsYou:
            return Row(stateText: "\(Glyph.needsYou) Needs you", glyph: Glyph.needsYou,
                       lens: .chrome, speakTier: .silent)
        case .settings:
            return Row(stateText: "Settings", glyph: "",
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
    static let gridHint = "⌃⌥ hear · hold ⌥ reply · ⌃⌃ why · ⌃⇧ dismiss"
    /// The quiet placard row above the hint. "AGENT", not "SESSION" (ui-pass-7,
    /// ruling 1): every user-facing noun on the panel says agent.
    static let newAgentTitle = "NEW AGENT"

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

    // MARK: - The courtesy check (ruled 08 Aug)

    /// Why the app stayed quiet, in the transient strip line.
    ///
    /// A held hail is otherwise indistinguishable from an agent that never came
    /// back, which is the one thing the panel must never be ambiguous about. So
    /// the suppression announces itself — visually, silently, in the same slot
    /// `noWordsNotice` uses.
    ///
    /// Both name the CONDITION, following `noAudioMessage`'s rule: not a
    /// classification of the agent, and not a transcription outcome. Nothing was
    /// "detected but not understood" — nothing was ever read. The quiet glyph,
    /// not the amber triangle: nothing is wrong and nothing needs the user.
    static let heldMicBusyNotice = "\(Glyph.quiet) Held — the microphone is in use"
    static let heldSpeechNotice = "\(Glyph.quiet) Held — someone was talking"

    // MARK: - The device fault (ruled 08 Aug)

    /// The third tier's placard. It names the CONDITION, not a classification:
    /// no audio arrived. "Needs you" would be true here and still wrong — it is
    /// the pill a waiting agent wears, and no agent is involved in a dead
    /// microphone.
    static let noAudioPlacard = "\(Glyph.needsYou) No audio"
    static let micSettingsTitle = "Microphone settings"

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
