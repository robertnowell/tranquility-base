import AppKit
import TranquilityCore

/// The agents you can pick, as a grid of tiles.
///
/// Ruled 14 Sep 2026, replacing a row of two words with the thing Robert
/// actually described: *"we can actually compress this to an actual grid, not a
/// list. Open columns. Just the agent. The agent name, the icon. And either
/// check or grade. And if you click on it, it takes you through the
/// install/sign-in."*
///
/// So a tile is a logo, a name, and a tick — and nothing else. No status
/// sentence, no "checked 2m ago", no sweep button. **A tick has no age**: you
/// have signed in or you have not, and if you have not, tapping is what fixes
/// it.
///
/// What is IN the grid is `AgentRoster.validated`, filtered to the ones this
/// app can actually drive. That filter is the promise: a tile that signs you
/// in to something TB cannot then use is worse than no tile.
final class AgentGridRow: NSView {

    /// **Four across, so today's four agents are one row.**
    ///
    /// Three columns wrapped the fourth onto a second row and doubled the
    /// grid's height, which pushed LAUNCH and DIRECTORY off the bottom of the
    /// panel. Robert, with the screenshot: *"the UI is getting cut off at the
    /// bottom."*
    static let columns = 4
    static let tileHeight: CGFloat = 64
    static let markSize: CGFloat = 26

    private var tiles: [String: NSButton] = [:]
    private var agents: [AgentRoster.Agent] = []
    private(set) var selected: String

    /// Picking one. The panel decides what that means — it is the same verb
    /// whether the agent is a harness or a provider, which is the ruling.
    var onSelect: ((String) -> Void)?
    /// Tapping one that is not set up. Takes the user to the install or the
    /// sign-in, which is the only thing a greyed tile is for.
    var onSetUp: ((String, AgentRoster.Step) -> Void)?

    init(width: CGFloat, agents: [AgentRoster.Agent], selected: String) {
        self.selected = selected
        self.agents = agents
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rows = max(1, Int(ceil(Double(agents.count) / Double(Self.columns))))
        let tileWidth = width / CGFloat(Self.columns)

        for (index, agent) in agents.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(tapped(_:)))
            button.isBordered = false
            button.imagePosition = .imageAbove
            button.identifier = NSUserInterfaceItemIdentifier(agent.id)
            button.translatesAutoresizingMaskIntoConstraints = false
            // The vendor's own mark, at the tile's size. A missing one draws
            // nothing rather than a placeholder: a hole is honest and a grey
            // box pretending to be a logo is not.
            if let png = AgentMarks.png(agent.id), let image = NSImage(data: png) {
                image.size = NSSize(width: Self.markSize, height: Self.markSize)
                button.image = image
                // Without this the cell draws the mark at its own pixel size
                // and the tile grows past the height it was given.
                button.imageScaling = .scaleProportionallyDown
            }
            addSubview(button)
            tiles[agent.id] = button

            let column = CGFloat(index % Self.columns)
            let row = CGFloat(index / Self.columns)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: tileWidth),
                button.heightAnchor.constraint(equalToConstant: Self.tileHeight),
                button.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                constant: column * tileWidth),
                button.topAnchor.constraint(equalTo: topAnchor,
                                            constant: row * Self.tileHeight),
            ])
            // **The last row pins the bottom, so this view's height is DERIVED
            // rather than asserted.** It used to carry a constant of
            // `rows * tileHeight` while each tile laid out taller than that
            // constant, so the view reported one height and drew another and
            // the panel sized itself to the lie. A view whose height is a
            // claim can disagree with itself; one whose height comes from its
            // own content cannot.
            if row == CGFloat(rows - 1) {
                button.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
        ])
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(agents: [AgentRoster.Agent], selected: String) {
        self.agents = agents
        self.selected = selected
        paint()
    }

    /// The whole visual language, in one place.
    ///
    /// A tile carries its name and, when it is set up, a tick. The tick is
    /// green because green already means "ready for you" everywhere else on
    /// this panel; a tile that needs setting up wears the amber arrow, because
    /// amber already means "something for you to do". Nothing new is invented
    /// — the three-lamp ruling covers this surface too.
    private func paint() {
        for agent in agents {
            guard let button = tiles[agent.id] else { continue }
            let picked = agent.id == selected
            let ready = agent.standing.isReady
            let mark: String = ready ? "✓" : "→"
            let ink: NSColor = ready
                ? (picked ? StateLegend.Palette.ready : StateLegend.Palette.ink)
                : StateLegend.Palette.fault

            // **Through `ChromeType.line`, not `Widgets.letterspaced`.** The
            // tick and the arrow are MARKS (`ChromeType.isMark`), and
            // `letterspaced` has no idea marks exist — it draws every
            // character on the baseline the letters use, which the chrome
            // self-test (`everyMarkComposed`) exists specifically to catch.
            // `line(_:)` is "the one place a glyph meets a word in this app",
            // and this row shipped red for ignoring it.
            button.attributedTitle = ChromeType.line(
                "\(agent.name.uppercased()) \(mark)",
                font: StateLegend.Face.chrome(9), color: ink, tracking: 1.1)
            // An agent that is not set up reads back, so the eye lands on the
            // ones that are. It is still legible and still tappable: being
            // signed out is an ordinary state, not a disabled control.
            button.alphaValue = ready ? 1.0 : 0.62
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let agent = agents.first(where: { $0.id == id }) else { return }
        switch agent.standing {
        case .ready:
            selected = id
            paint()
            onSelect?(id)
        case .needsSetup(let step):
            // NOT a selection. Picking an agent you cannot use would leave the
            // panel pointing at something that cannot answer, which is the
            // failure this whole surface exists to prevent.
            onSetUp?(id, step)
        case .notOffered:
            return
        }
    }
}

extension StatusHUD {

    /// The tiles, assembled from what is on disk and nothing else.
    ///
    /// Only agents the app can actually DRIVE are offered. `AgentRoster` keeps
    /// the others listed with their limit stated, which is useful to us and
    /// not to the person choosing one.
    static func agentTiles() -> [AgentRoster.Agent] {
        let offerable = Set(AgentRoster.validated.filter { $0.reach.isOfferable }.map(\.id))
        return AgentRoster.grid(
            installed: { id in
                // A harness is installed if its binary resolves; a provider is
                // installed if it has been configured at all, which is what
                // having a base URL means.
                if let adapter = KnownHarnesses.all.first(where: { $0.id == id }) {
                    return adapter.pathCandidates.contains {
                        FileManager.default.isExecutableFile(atPath: $0)
                    }
                }
                return ProviderConfig.baseURL(id) != nil
            },
            credentialed: { id in
                KnownHarnesses.all.contains { $0.id == id } || ProviderConfig.baseURL(id) != nil
            })
            .filter { offerable.contains($0.id) }
    }
}
