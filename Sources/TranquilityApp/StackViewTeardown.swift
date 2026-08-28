import AppKit

extension NSStackView {

    /// Empty the stack, without detaching views out from under AppKit.
    ///
    /// Replaces `arrangedSubviews.forEach { $0.removeFromSuperview() }`, which
    /// was written five times in this app and is wrong three ways at once:
    ///
    ///  1. `arrangedSubviews` is LIVE. `removeFromSuperview()` mutates it, so the
    ///     `forEach` is iterating a collection that is changing underneath it.
    ///  2. `removeFromSuperview()` alone does not unregister the view from the
    ///     stack view's own arrangement — `removeArrangedSubview(_:)` is the half
    ///     that does, and skipping it leaves AppKit holding arrangement state for
    ///     a view that has left the tree.
    ///  3. Nothing holds the views alive across the loop. Each one can deallocate
    ///     the moment its superview drops it, while AppKit is still walking the
    ///     dependency set that mentions it.
    ///
    /// Snapshotting fixes all three: the loop iterates a stable copy, the array
    /// keeps every view alive until this function returns, and each view leaves
    /// the arrangement before it leaves the tree.
    ///
    /// The crash this comes from, three times now, most recently 28 Aug at
    /// 12:01:20 after six minutes of uptime — SIGBUS / KERN_PROTECTION_FAILURE on
    /// the main thread:
    ///
    ///     TrayRowView.apply -> forEach -> NSView.removeFromSuperview
    ///       -[NSView _setSuperview:] -> CFSetApplyFunction (dependency sets)
    ///         -[NSTextField didChangeValueForKey:] -> ... semantic context ...
    ///           objc_getAssociatedObject -> objc_retain -> BAD ACCESS
    ///
    /// AppKit is messaging something in that dependency walk which is no longer
    /// valid memory. The precise internal is not proven from a crash report and
    /// is not claimed here; what IS certain is that the construct at the faulting
    /// line does all three things above, and this does none of them.
    func removeAllArrangedSubviews() {
        let existing = arrangedSubviews
        for view in existing {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
