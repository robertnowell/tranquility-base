import AppKit

/// KEEP THE GLASS DARK (2 Oct 2026).
///
/// The panel's text is light, so a light panel is never a valid state. On 2 Oct
/// the regular Liquid Glass drew in its LIGHT appearance for hours after a
/// display sleep and wake (screenshots 2:52 to 3:07 pm; reproduced with the real
/// glass: dark 41, light 181, live 208), although the panel was pinned to dark
/// at launch and nothing in the app ever changed it. macOS 26 glass is reported
/// to keep a stale look until it is rebuilt (Apple Developer Forums 800927,
/// 810314); redrawing does not cure it. So the app stops trusting the one-time
/// pin: the glass itself carries dark, is checked every time the panel shows,
/// and is rebuilt after every event that re-composites windows. Every check and
/// rebuild is logged, so a recurrence is provable from app.log.
/// Research record: agent fab03130, 2026-10-02-glass-light-state.
extension StatusHUD {
    static let darkAppearance = NSAppearance(named: .darkAqua)

    /// Watch the moments the window server re-draws everything.
    func installGlassKeeper() {
        guard glassKeeperObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            let reason = name.rawValue
            glassKeeperObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.renewGlass(because: reason) }
            })
        }
        glassKeeperObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renewGlass(because: "screen parameters changed") }
        })
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.renewGlass(because: "system appearance changed") } }
        }
        Permissions.log("glass: keeper installed; \(describeAppearance())")
    }

    /// The cheap check, on every show: anything in the chain resolving light
    /// means the glass is stale, and it is rebuilt before it is seen.
    func keepGlassDark(on event: String) {
        guard let panel, let glass = glassView else { return }
        func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        if panel.appearance?.name != .darkAqua || !isDark(panel.effectiveAppearance)
            || !isDark(glass.effectiveAppearance) {
            renewGlass(because: "\(event): resolved light")
        }
    }

    /// A new glass view in place of the old one, dark pinned on the window,
    /// the glass and the surface. The surface and everything on it move
    /// across untouched; the radius in force (slab or collapsed pill) is kept.
    func renewGlass(because reason: String) {
        guard let panel, let surface = surfaceView else { return }
        let before = describeAppearance()
        // Moving the surface to a new glass would take the keyboard from a
        // reply being typed; it is handed straight back.
        let typing = panel.firstResponder
        panel.appearance = Self.darkAppearance
        surface.appearance = Self.darkAppearance
        if #available(macOS 26.0, *), let old = glassView as? NSGlassEffectView {
            let glass = NSGlassEffectView(frame: old.frame)
            glass.style = .regular
            glass.cornerRadius = old.cornerRadius
            glass.autoresizingMask = [.width, .height]
            glass.appearance = Self.darkAppearance
            old.contentView = nil
            glass.contentView = surface
            panel.contentView = glass
            glassView = glass
            if let typing, typing !== panel { panel.makeFirstResponder(typing) }
        } else {
            glassView?.appearance = Self.darkAppearance
        }
        Permissions.log("glass: renewed (\(reason)); was \(before); now \(describeAppearance())")
    }

    func describeAppearance() -> String {
        "panel=\(panel?.appearance?.name.rawValue ?? "nil")/\(panel?.effectiveAppearance.name.rawValue ?? "-") "
            + "glass=\(glassView?.effectiveAppearance.name.rawValue ?? "-") "
            + "app=\(NSApp.effectiveAppearance.name.rawValue)"
    }
}
