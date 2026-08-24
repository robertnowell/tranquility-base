import AppKit

/// The readback countdown, drawn by Core Animation instead of a ticking
/// NSProgressIndicator: one linear animation across the whole window (ruled —
/// tick steps read as a stutter), the fill in the palette's go green. The send
/// itself is fired by a one-shot timer in render(); this view is pixels only.
final class CountdownBarView: NSView {
    private let fill = CALayer()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = StateLegend.Palette.hairlineSoft.cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        fill.backgroundColor = StateLegend.Palette.ready.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0)
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fill from empty to full over the window, continuously. Called after
    /// layout, so bounds are real.
    func begin(seconds: TimeInterval) {
        fill.removeAllAnimations()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let sweep = CABasicAnimation(keyPath: "bounds.size.width")
        sweep.fromValue = 0
        sweep.toValue = bounds.width
        sweep.duration = seconds
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(sweep, forKey: "sweep")
    }

    /// Pin the fill at a fraction with no animation — the pose driver's frozen
    /// mid-window photograph.
    func freeze(fraction: CGFloat) {
        fill.removeAllAnimations()
        fill.frame = CGRect(x: 0, y: 0,
                            width: bounds.width * fraction, height: bounds.height)
    }
}
