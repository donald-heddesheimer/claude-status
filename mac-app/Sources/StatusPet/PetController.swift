import AppKit

/// Owns the panel, keeps it in sync with the session store, and remembers
/// where you dragged it.
final class PetController: NSObject {
    private static let originKey = "com.claudestatus.petOrigin"
    // Tall enough for the thought bubble above the pet, wide enough that the
    // attention pulse never clips at the edges.
    private static let size = NSSize(width: 170, height: 190)

    private let store: SessionStore
    private let panel: PetPanel
    private let view: PetView

    init(store: SessionStore) {
        self.store = store
        self.panel = PetPanel(size: Self.size)
        self.view = PetView(frame: NSRect(origin: .zero, size: Self.size))
        super.init()

        panel.contentView = view
        view.petImage = Self.loadArt()
        view.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        view.onClick = { Self.openClaude() }
        store.onChange = { [weak self] in self?.refresh() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowMoved),
            name: NSWindow.didMoveNotification,
            object: panel
        )

        restorePosition()
        refresh()
    }

    func show() {
        // orderFrontRegardless keeps the pet visible without activating us.
        panel.orderFrontRegardless()
    }

    /// Clicking the pet brings Claude to the front. Point
    /// `CLAUDE_STATUS_CLICK_APP` at any app path or bundle id to change it —
    /// your terminal or editor, if that's where you actually work.
    private static func openClaude() {
        let target = ProcessInfo.processInfo.environment["CLAUDE_STATUS_CLICK_APP"]
            ?? "/Applications/Claude.app"

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
        let path = ProcessInfo.processInfo.environment["CLAUDE_STATUS_ART"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-status/pet.png")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private func refresh() {
        view.mood = store.mood
        view.remoteBadge = store.remoteBadge
        view.caption = store.caption
    }

    // MARK: - Position

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
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
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - Self.size.width - 24,
            y: frame.maxY - Self.size.height - 24
        ))
    }

    @objc private func windowMoved() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for line in store.summaryLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Claude", action: #selector(openClaudeFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let reset = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let quit = NSMenuItem(title: "Quit Pet", action: #selector(quitPet), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openClaudeFromMenu() {
        Self.openClaude()
    }

    @objc private func resetPosition() {
        moveToDefaultCorner()
        windowMoved()
    }

    @objc private func quitPet() {
        NSApp.terminate(nil)
    }
}
