import AppKit

/// Panel geometry: resize-to-content, the collapse/expand morph, and
/// screen positioning. Split out of `StatusHUD.swift` 24 Aug (App-lane
/// P5) — three functions that compute and apply frame math, called from
/// the render path (`resizeToFit`/`position` run together at every face
/// change) but self-contained enough to live apart from it.
extension StatusHUD {
    /// Grow the window to whatever the content needs.
    ///
    /// The first version pinned the panel at 150pt regardless of what was in it, so
    /// a long summary pushed the buttons off the bottom edge — the actions were
    /// literally unreachable. Never ship a fixed-height container around
    /// variable-length text.
    func resizeToFit(_ panel: NSPanel) {
        // Collapsed is a fixed frame, so the column never resizes under the
        // user and the lamps never move. It is also the only face that is
        // FLUSH to the screen edge — `position` gives every other face a
        // margin; a sidebar with a gap behind it is a floating card pretending
        // to be a sidebar.
        if isCollapsed, case .idle = state {
            // A WIDTH change and nothing else. The right edge stays exactly
            // where the grid's right edge was — same 16pt margin every other
            // face gets — the corner radius stays, the panel stays. Ruled after
            // the first attempt swapped content views and went flush to the
            // screen edge: "just make it skinny and keep the right edge in the
            // same place, and animate the collapse."
            NSLayoutConstraint.deactivate(stackEdges)
            NSLayoutConstraint.activate(stripEdges)
            contentStack?.isHidden = true
            strip?.isHidden = false
            // Fixed height as well as fixed width — ruled, and load-bearing for
            // the wordmark: inheriting the grid's height gave the strip 150pt on
            // a quiet day, which left no room below the lamps and silently
            // dropped the wordmark. The strip is the same size every time.
            morph(panel, to: NSSize(width: CollapsedStrip.width,
                                    height: CollapsedStrip.height))
            return
        }
        NSLayoutConstraint.deactivate(stripEdges)
        NSLayoutConstraint.activate(stackEdges)
        strip?.isHidden = true
        contentStack?.isHidden = false

        guard let stack = contentStack else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let needed = stack.fittingSize
        let height = max(needed.height, 90)
        // Against the height we last ASKED for, never the live frame: with an
        // animated resize in flight, `panel.frame.height` is a transient, and
        // comparing to it let a render skip its resize because the panel
        // happened to be passing through the target height at that instant.
        // That is why two identical faces settled 12pt apart (Robert's two
        // screenshots of the same card, 06 Aug).
        // The WIDTH has to be checked too, not just the height. Expanding out of
        // the strip is a width-only change — the grid's height is often exactly
        // what the collapsed panel already had — so a height-only guard skipped
        // the resize entirely and left the panel 40pt wide. `position` then
        // placed it from that 40pt width, and the grid rendered off the right of
        // the display. That is the bug the user reported, and this line is it.
        let widthIsWrong = abs(panel.frame.width - 380) > 1
        if widthIsWrong || abs((intendedHeight ?? panel.frame.height) - height) > 1 {
            intendedHeight = height
            // The top edge holds still and the panel grows downward: origin is
            // bottom-left, so the height delta comes out of origin.y. Animated
            // when already on screen (ruled 06 Aug — the snap between
            // different-sized faces was the jarring half of the border bug);
            // the first paint still snaps, a hidden panel has nothing to ease.
            var frame = panel.frame
            let delta = height - frame.height
            frame.origin.y -= delta
            frame.size.height = height
            frame.size.width = 380
            // The ORIGIN has to be right in the animated frame, not corrected
            // afterwards. `position` runs immediately after this call and does
            // set it — and then the in-flight animation lands 0.12s later with
            // the frame it was handed, stomping the correction. Expanding out of
            // the collapsed strip therefore kept the strip's x and put 340pt of
            // grid off the right of the display: measured
            // {{1672, 751}, {380, 317}} against a screen 1728 wide.
            if let screen = NSScreen.main {
                frame.origin.x = screen.visibleFrame.maxX - frame.size.width - 16
            }
            if panel.isVisible {
                // Through the animator, NOT setFrame(animate:) — that call
                // blocks the main thread for the whole animation, which delays
                // every gesture landing behind it (the ack arriving late was
                // the symptom). This one returns immediately.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
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

    /// Animate the panel between its two widths, holding the right edge still.
    ///
    /// Held, not recomputed: the expanded face sits at `maxX - width - 16`, and
    /// a collapse that recomputes from the NEW width would slide the panel
    /// rightwards as it narrows. Taking the current right edge and keeping it is
    /// what makes this read as one panel getting thinner rather than a second
    /// panel appearing somewhere else.
    func morph(_ panel: NSPanel, to size: NSSize) {
        let width = size.width
        var frame = panel.frame
        guard abs(frame.width - width) > 0.5 || abs(frame.height - size.height) > 0.5
        else { return }
        frame.size.height = size.height
        // The right edge is computed, not inherited. Holding the CURRENT edge
        // reads well while the panel is already placed and fails completely when
        // it is not: a launch that starts collapsed morphs the default
        // {{0,0},{380,150}} rect and lands at {{340, 0}, {40, 150}} — bottom
        // left, off the working area entirely.
        //
        // Every face sits at `visibleFrame.maxX - width - 16`, so its right edge
        // is always `maxX - 16`. Computing that is identical to holding it, and
        // it is also correct before the panel has ever been on screen.
        if let screen = NSScreen.main {
            frame.origin.x = screen.visibleFrame.maxX - width - 16
            frame.origin.y = screen.visibleFrame.maxY - frame.height - 16
        } else {
            frame.origin.x = frame.maxX - width
        }
        frame.size.width = width
        intendedHeight = frame.height
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        // Collapsed owns its own frame, flush to the edge, and `resizeToFit`
        // has already set it. Returning here rather than special-casing the
        // margin below: this runs immediately AFTER that call on every render,
        // so a margin applied here silently undoes it — which is exactly what
        // the flushRight drill caught on the first deploy.
        let margin: CGFloat = 16
        // No special case for the collapsed strip. It is placed from its own
        // width like every other face, which is what makes its right edge line
        // up with the grid's — and, unlike a panel that positions itself, works
        // on the very first paint before it has ever been on screen.
        let size = panel.frame.size
        // Top-right, below the menu bar.
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - margin,
            y: screen.visibleFrame.maxY - size.height - margin)
        panel.setFrameOrigin(origin)
    }
}
