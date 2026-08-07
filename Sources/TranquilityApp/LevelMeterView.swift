import AppKit

/// A live waveform of what the microphone is hearing.
///
/// Two earlier attempts were the wrong shape for the job. Block characters change
/// width as they fill, because U+2588 and U+2591 are not the same width in a
/// proportional font. An NSProgressIndicator is worse: it is a *progress* bar, so it
/// eases smoothly toward a target and reads as a task completing rather than a voice
/// being heard — the animation is fighting the meaning.
///
/// What a level readout has to do is respond instantly and show history, so you can
/// see the shape of what you just said. So: a scrolling column chart, one bar per
/// sample, newest on the right. Fixed geometry, no easing, no font.
final class LevelMeterView: NSView {
    /// Both are kept. `.scrolling` is a good balance if a sense of duration ever
    /// turns out to matter; `.centred` is the default because it does not.
    ///
    /// A scrolling chart with a running clock says "a file is being written, and it
    /// is getting bigger". That is true and completely beside the point — you are
    /// talking to something, not recording an asset, and being shown the cost of
    /// the seconds makes you hurry. Bars pulsing in place say only "I can hear
    /// you", which is the entire question.
    enum Style { case centred, scrolling }
    var style: Style = .centred

    private var samples: [CGFloat] = []
    private let barWidth: CGFloat = 4
    private let gap: CGFloat = 4
    /// Odd, so there is a true middle for the newest sample to sit in.
    private let centredBarCount = 11

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    override var isFlipped: Bool { false }

    private var capacity: Int {
        switch style {
        case .centred: return centredBarCount / 2 + 1
        case .scrolling: return max(1, Int((bounds.width + gap) / (barWidth + gap)))
        }
    }

    func push(_ level: CGFloat) {
        samples.append(max(0, min(1, level)))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        needsDisplay = true
    }

    func reset() {
        samples.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !bounds.isEmpty else { return }
        switch style {
        case .centred: drawCentred()
        case .scrolling: drawScrolling()
        }
    }

    /// Newest sample in the middle bar, older ones spreading symmetrically outward.
    /// The level therefore travels out from the centre as you speak, which reads as
    /// a voice rather than as a queue draining.
    private func drawCentred() {
        let total = CGFloat(centredBarCount) * barWidth + CGFloat(centredBarCount - 1) * gap
        var x = bounds.midX - total / 2
        let midY = bounds.midY
        let middle = centredBarCount / 2

        for index in 0..<centredBarCount {
            let distance = abs(index - middle)
            let sample = distance < samples.count
                ? samples[samples.count - 1 - distance] : 0
            // Taper the outer bars so the shape reads as a single voice rather than
            // as eleven independent readouts.
            let taper = 1 - CGFloat(distance) / CGFloat(middle + 1) * 0.45
            let height = max(3, sample * bounds.height * taper)
            let rect = NSRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            // Palette ink, not labelColor: the surface is the opaque light
            // console on every face, so the bars must not flip white in dark mode.
            StateLegend.Palette.ink.withAlphaComponent(0.9 - CGFloat(distance) * 0.05).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    private func drawScrolling() {
        let midY = bounds.midY
        // A visible floor, so silence still reads as "listening, hearing nothing"
        // rather than as a dead panel.
        let minHeight: CGFloat = 2

        for (index, sample) in samples.enumerated() {
            let x = bounds.maxX - CGFloat(samples.count - index) * (barWidth + gap)
            guard x + barWidth >= bounds.minX else { continue }
            let height = max(minHeight, sample * bounds.height)
            let rect = NSRect(x: x, y: midY - height / 2, width: barWidth, height: height)

            // Older samples fade, which gives the scroll a direction without motion.
            let age = CGFloat(samples.count - index) / CGFloat(max(1, capacity))
            StateLegend.Palette.ink.withAlphaComponent(0.85 - age * 0.5).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
