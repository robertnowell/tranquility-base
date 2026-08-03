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
    private var samples: [CGFloat] = []
    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 2

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    override var isFlipped: Bool { false }

    private var capacity: Int {
        max(1, Int((bounds.width + gap) / (barWidth + gap)))
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
            NSColor.labelColor.withAlphaComponent(0.85 - age * 0.5).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
