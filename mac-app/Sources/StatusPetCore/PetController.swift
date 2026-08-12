import AppKit

/// Owns the panel, keeps it in sync with the session store, and remembers
/// where you dragged it.
final class PetController: NSObject {
    /// Per agent, so each pet remembers where you put *it*.
    private var originKey: String { "com.claudestatus.petOrigin.\(agent)" }
    // The critter sits in the middle. The height is matching room above and
    // below for the thought bubble, the width is room for it to grow sideways —
    // all of it transparent and click-through.
    private static let size = NSSize(width: 320, height: 180)
    /// Gap between the pet and the hover panel.
    private static let statsGap: CGFloat = 10

    let store: SessionStore
    private let agent: String
    /// Where this pet defaults to when it has no saved position, counted from
    /// the corner so a second agent doesn't land on top of the first.
    private let slot: Int
    private let panel: PetPanel
    private let view: PetView
    private let stats = StatsPanel()
    private var statsTimer: Timer?
    private var statsSize: NSSize = .zero

    /// Agent name drawn under the critter. Nil when there's only one pet and
    /// naming it would be noise.
    var agentLabel: String? {
        didSet { view.agentLabel = agentLabel }
    }

    /// Extra menu items contributed by the app. Rebuilt on every right-click, so
    /// items whose titles report live state stay current.
    var menuExtras: (() -> [NSMenuItem])?

    init(store: SessionStore, agent: String = PetPack.primary, slot: Int = 0) {
        self.store = store
        self.agent = agent
        self.slot = slot
        self.panel = PetPanel(size: Self.size)
        self.view = PetView(frame: NSRect(origin: .zero, size: Self.size))
        super.init()

        panel.contentView = view
        view.tint = PetPack.tint(for: agent)
        view.petImage = Self.loadArt()
        view.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        view.onClick = { Self.openClaude() }
        view.onHover = { [weak self] inside in
            inside ? self?.showStats() : self?.hideStats()
        }
        store.onChange = { [weak self] in self?.refresh() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowMoved),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        restorePosition()
        applyPreferences()
        refresh()
    }

    /// Pushes the display preferences into the store. Called once at startup and
    /// again whenever Settings changes one.
    ///
    /// The store deliberately knows nothing about `Preferences` — it is the one
    /// piece of this app with real logic worth testing, and a singleton reaching
    /// into `UserDefaults` from inside it would drag the disk into every test.
    func applyPreferences() {
        let preferences = Preferences.shared
        store.colorCoding = preferences.colorCodedBubbles
        store.followOne(preferences.followOneSession)
    }

    /// Follow one named session, or nil to go back to all of them. Writes the
    /// preference too, so the choice you make from the menu is the one Settings
    /// shows and the one you get back after a relaunch.
    func follow(_ id: String?) {
        Preferences.shared.followOneSession = id != nil
        if let id {
            store.follow(id)
        } else {
            store.followOne(false)
        }
    }

    func show() {
        // orderFrontRegardless keeps the pet visible without activating us.
        panel.orderFrontRegardless()
    }

    /// Clicking the pet brings Claude to the front. Settings ▸ General points it
    /// at any app path or bundle id — your terminal or editor, if that's where
    /// you actually work.
    private static func openClaude() {
        let target = Preferences.shared.clickTarget

        let url: URL?
        if target.hasPrefix("/") {
            url = FileManager.default.fileExists(atPath: target) ? URL(fileURLWithPath: target) : nil
        } else {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
        }

        guard let url else {
            NSSound.beep()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Optional override artwork. Missing art is fine — the view draws the
    /// critter from its pixel map instead.
    private static func loadArt() -> NSImage? {
        let path = Preferences.shared.artPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private func refresh() {
        // Claude just finished: work was in flight, and now none is. Read off
        // the collapsed mood rather than any single session, so a pet watching
        // four sessions celebrates once, when the last of them stops — not four
        // times, and not while three are still running.
        //
        // Deliberately not driven from SessionEnd: closing a terminal is not an
        // achievement, and a session that ends mid-task would celebrate a
        // failure.
        let finished = (view.mood == .busy || view.mood == .waiting) && store.mood == .idle

        view.mood = store.mood
        view.remoteBadge = store.remoteBadge

        // Text and colour come from one lookup: the colour is only meaningful
        // attached to the words it arrived with.
        let thought = store.thought
        view.caption = thought?.text
        view.bubbleTint = thought.flatMap { store.color(for: $0.sessionID) } ?? SessionPalette.ink

        if finished { view.celebrate() }

        if stats.isVisible { refreshStats() }
    }

    // MARK: - Hover panel

    private func showStats() {
        refreshStats()
        // refreshStats only moves the panel when the content size changed, so
        // place it unconditionally here — the pet may have moved (menu, reset,
        // display change) while the panel was hidden.
        positionStats(statsSize)

        // Attaching the panel as a child window hands the follow to the window
        // server, which moves it in lockstep with the pet. Repositioning it
        // ourselves from didMove can only ever trail the drag by a frame, which
        // is exactly what a fast flick exposes.
        if stats.parent == nil {
            panel.addChildWindow(stats, ordered: .above)
        }

        // The ages tick while you hover, so redraw on a slow timer rather than
        // freezing whatever the numbers happened to be on entry.
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }
    }

    private func hideStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        if stats.parent != nil { panel.removeChildWindow(stats) }
        stats.orderOut(nil)
    }

    /// Re-measures the content, and only moves the panel if that changed its
    /// size. Measuring every string is the expensive half of this and has no
    /// business running while you drag.
    private func refreshStats() {
        let size = stats.update(with: store.stats)
        guard size != statsSize else { return }
        statsSize = size
        positionStats(size)
    }

    /// Parks the panel beside the pet, flipping to whichever side has room —
    /// the pet lives in a screen corner by default.
    ///
    /// Measured against the critter rather than the window: most of the window
    /// is transparent padding for the bubble, and hugging that would leave the
    /// panel floating in space.
    private func positionStats(_ size: NSSize) {
        let pet = panel.convertToScreen(view.critterFrame)
        let screen = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = pet.minX - size.width - Self.statsGap
        if x < screen.minX {
            x = pet.maxX + Self.statsGap
        }
        // If neither side fits, hug the edge rather than sliding off-screen.
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)

        var y = pet.maxY - size.height
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)

        stats.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                       display: true)
    }

    // MARK: - Position

    /// Takes the panel off screen for good. Used when an agent's last session
    /// goes away and its pet has nothing left to report.
    func close() {
        hideStats()
        NotificationCenter.default.removeObserver(self)
        panel.orderOut(nil)
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            let origin = NSPointFromString(saved)
            // Only trust it if it still lands on a connected display.
            let visible = NSScreen.screens.contains { $0.visibleFrame.contains(origin) }
            if visible {
                panel.setFrameOrigin(origin)
                return
            }
        }
        moveToDefaultCorner()
    }

    private func moveToDefaultCorner() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        // Stack down the right edge. The window is mostly transparent, so the
        // step is the critter's height plus a gap rather than the full frame.
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - Self.size.width - 24,
            y: frame.maxY - Self.size.height - 24 - CGFloat(slot) * 120
        ))
    }

    @objc private func windowMoved() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: originKey)
        // The child window already followed. The only thing that can go stale
        // is which side of the pet it belongs on, once a drag reaches a screen
        // edge — and that check costs nothing, since it re-measures nothing.
        if stats.isVisible { positionStats(statsSize) }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let choices = store.choices
        if choices.isEmpty {
            let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // Pick a session and the pet follows that one instead of collapsing
            // everything into a single mood. This and the Settings checkbox are
            // the same switch — picking a session here is the fastest way to
            // turn single-session mode on, because it answers "which one" in the
            // same gesture.
            let auto = NSMenuItem(title: "All sessions",
                                  action: #selector(clearFocus), keyEquivalent: "")
            auto.target = self
            auto.state = store.followsOneSession ? .off : .on
            menu.addItem(auto)

            for choice in choices {
                let item = NSMenuItem(title: choice.label,
                                      action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice.id
                item.state = choice.isFollowed ? .on : .off
                // The swatch is what makes the colour on the bubble mean
                // something — this menu and the hover panel are where you learn
                // the mapping.
                if let color = choice.color {
                    item.image = SessionPalette.swatch(color)
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Claude", action: #selector(openClaudeFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let reset = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        if let extras = menuExtras?(), !extras.isEmpty {
            menu.addItem(.separator())
            extras.forEach(menu.addItem)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Pet", action: #selector(quitPet), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openClaudeFromMenu() {
        Self.openClaude()
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        follow(sender.representedObject as? String)
    }

    @objc private func clearFocus() {
        follow(nil)
    }

    @objc private func resetPosition() {
        moveToDefaultCorner()
        windowMoved()
    }

    @objc private func quitPet() {
        NSApp.terminate(nil)
    }
}
