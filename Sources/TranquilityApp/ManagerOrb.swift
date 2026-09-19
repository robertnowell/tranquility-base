import AppKit

/// The manager's face: one orb, four states, one line of text.
///
/// Idle breathes slowly and dim. Heard flashes once (a turn the manager kept
/// as context). Addressed goes bright. Speaking rings outward. Stage tints
/// green and writes the session's goal underneath, because the goal is the
/// name a stranger understands. Nothing here is interactive; it is a lamp.
@MainActor
final class ManagerOrb {
    enum State { case idle, heard, addressed, speaking, stage }

    private let panel: NSPanel
    private let view: OrbView
    private let label = NSTextField(labelWithString: "")

    init() {
        let frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        view = OrbView(frame: frame)
        view.wantsLayer = true
        panel.contentView = view
        label.frame = NSRect(x: 8, y: 6, width: 224, height: 18)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.lineBreakMode = .byTruncatingTail
        view.addSubview(label)
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - frame.width - 16, y: v.maxY - frame.height - 16))
        }
    }

    func show() { panel.orderFrontRegardless(); view.start() }
    func hide() { view.stop(); panel.orderOut(nil) }

    func set(_ state: State, line: String? = nil) {
        view.state = state
        if let line { label.stringValue = line }
    }
}

@MainActor
final class OrbView: NSView {
    var state: ManagerOrb.State = .idle { didSet { flash = state == .heard ? 1 : flash } }
    private var timer: Timer?
    private var phase: CGFloat = 0
    private var flash: CGFloat = 0

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase += 0.05
                self.flash = max(0, self.flash - 0.04)
                if self.state == .heard, self.flash == 0 { self.state = .idle }
                self.needsDisplay = true
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 12)
        let breath = 0.5 + 0.5 * sin(phase)
        let (base, radius, alpha): (NSColor, CGFloat, CGFloat)
        switch state {
        case .idle:      (base, radius, alpha) = (.systemGray, 18 + 2 * breath, 0.35 + 0.15 * breath)
        case .heard:     (base, radius, alpha) = (.systemGray, 20 + 4 * flash, 0.45 + 0.4 * flash)
        case .addressed: (base, radius, alpha) = (.white, 24 + 2 * breath, 0.95)
        case .speaking:  (base, radius, alpha) = (.white, 22, 0.9)
        case .stage:     (base, radius, alpha) = (NSColor(calibratedRed: 0.24, green: 0.44, blue: 0.28, alpha: 1), 24 + 2 * breath, 0.95)
        }
        if state == .speaking {
            for i in 0..<3 {
                let r = radius + 10 + CGFloat(i) * 9 + 6 * breath
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                base.withAlphaComponent(0.25 / CGFloat(i + 1)).setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
        let glow = NSBezierPath(ovalIn: NSRect(x: center.x - radius - 8, y: center.y - radius - 8,
                                               width: 2 * radius + 16, height: 2 * radius + 16))
        base.withAlphaComponent(alpha * 0.25).setFill()
        glow.fill()
        let orb = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                              width: 2 * radius, height: 2 * radius))
        base.withAlphaComponent(alpha).setFill()
        orb.fill()
    }
}
