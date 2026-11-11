import AppKit
import TranquilityCore

/// Real tiles and pointer actions, isolated from the running application's services.
@MainActor
enum SavedAccountsDrill {
    static func run() -> Bool {
        let support = QueueStore.supportDirectory.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard ProcessInfo.processInfo.environment["VOICE_DISPATCH_SUPPORT_DIR"] != nil,
              support.path.hasPrefix(temporary + "/") else {
            print("FAIL saved-account UI requires an isolated temporary support directory")
            return false
        }
        var checks: [(String, Bool)] = []
        func check(_ name: String, _ passed: Bool) { checks.append((name, passed)) }
        let original = StatusHUD.agentTiles()
        check("one account retains original label", !original.contains { $0.name == "Claude · Main" })
        let grid = AgentGridRow(width: 600, agents: original, selected: ClaudeCodeAdapter().id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Saved account UI drill"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 160))
        content.addSubview(grid)
        grid.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
        grid.topAnchor.constraint(equalTo: content.topAnchor).isActive = true
        window.contentView = content
        defer { window.orderOut(nil) }
        do {
            let account = SavedAccount(label: "Personal", configDirectory: support.appendingPathComponent("profile").path)
            try SavedAccountStore.shared.save(account)
            let updated = StatusHUD.agentTiles()
            grid.update(agents: updated, selected: account.id)
            let buttons = grid.subviews.compactMap { $0 as? NSButton }
            check("new account creates a real tile", buttons.count == original.count + 1)
            check("both saved accounts are named", updated.contains { $0.name == "Claude · Main" }
                  && updated.contains { $0.name == "Claude · Personal" })
            var picked: String?
            grid.onSelect = { picked = $0; AgentDefaults.defaultTarget = $0 }
            buttons.first { $0.identifier?.rawValue == account.id }?.performClick(nil)
            check("pointer selects the account ID", picked == account.id && AgentDefaults.defaultTarget == account.id)
            check("default retains integration kind", AgentDefaults.defaultHarness == ClaudeCodeAdapter().id)
            let destinations = AgentHandoff.destinations(ready: updated)
            check("continue choices distinguish same-backend accounts", destinations.contains { $0.id == account.id && $0.harness == ClaudeCodeAdapter().id }
                && destinations.contains { $0.id == ClaudeCodeAdapter().id })
            window.orderFront(nil)
            window.layoutIfNeeded()
            check("all account tiles have usable bounds", buttons.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 && $0.frame.maxX <= grid.bounds.width + 1 })
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: support.appendingPathComponent("account-grid.png"))
            }
        } catch { check("account setup fixture", false); print(error.localizedDescription) }
        for (name, passed) in checks { print("\(passed ? "PASS" : "FAIL") \(name)") }
        return checks.allSatisfy(\.1)
    }
}
