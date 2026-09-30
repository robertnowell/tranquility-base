import AppKit
import WebKit

/// ⌘F in the Hub window: a find bar above the page, the way Safari has one.
///
/// WebKit gives a Mac app no find bar of its own: sending the web view
/// `performTextFinderAction:` raises "unrecognized selector" (probed 30 Sep
/// 2026), and NSTextFinder cannot see into it. What WebKit does give is
/// `find(_:configuration:)`, which searches the whole page, frames included,
/// selects the match and scrolls to it. This bar is the field around that.
///
/// Return finds the next match, Shift-Return the previous, ⌘G and ⇧⌘G the
/// same from anywhere in the window, and Escape or Done closes the bar.
@MainActor
public final class HubFindBar: NSView, NSSearchFieldDelegate {
    public let field = NSSearchField()
    public let status = NSTextField(labelWithString: "")
    private weak var web: WKWebView?
    /// The last search, so ⌘G works after the bar has closed.
    public private(set) var query = ""

    init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        field.placeholderString = "Find in page"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = self
        field.target = self
        field.action = #selector(submitted)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.controlSize = .small
        let line = NSBox()
        line.boxType = .separator

        for v in [field, status, done, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 280),
            status.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Called when the bar should go away; the window collapses it.
    var onClose: () -> Void = {}

    @objc private func submitted() { Task { await find(backwards: NSEvent.modifierFlags.contains(.shift)) } }
    @objc private func close() { onClose() }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose(); return true }
        return false
    }

    /// Find the next (or previous) match of the field's text, or of the last
    /// search when the field is empty. Says so when there is none.
    @discardableResult
    public func find(backwards: Bool = false) async -> Bool {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { query = text }
        guard !query.isEmpty, let web else { status.stringValue = ""; return false }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        let found = (try? await web.find(query, configuration: config).matchFound) ?? false
        status.stringValue = found ? "" : "Not found"
        return found
    }
}
