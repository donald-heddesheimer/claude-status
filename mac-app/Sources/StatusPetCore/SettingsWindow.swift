import AppKit

/// The app's Settings window.
///
/// Everything the pet reads is editable here. It exists because the app stopped
/// being something you launch from a terminal with exports in front of it — an
/// installed `.app` starts with an empty environment, so a Settings window is
/// the only place configuration can actually live.
///
/// Built in code rather than a nib: the package has no resource bundle, and four
/// tabs of labelled controls is less code than the plumbing to load one.
public final class SettingsWindowController: NSWindowController {
    public enum Tab: Int, CaseIterable {
        case general, sessions, security, remote, health

        var title: String {
            switch self {
            case .general:  return "General"
            case .sessions: return "Sessions"
            case .security: return "Security"
            case .remote:   return "Remote"
            case .health:   return "Health"
            }
        }
    }

    /// What a change actually costs to apply.
    ///
    /// The two used to be one bucket, which meant every setting restarted the
    /// listener. That is right for the port and wrong for a colour checkbox:
    /// dropping the socket, however briefly, is a real thing to do to a hook
    /// that might be posting at that instant.
    public enum Change {
        /// Port, token, accounts, logging — the listener has to come back up.
        case wire
        /// How the pet looks. Nothing on the network needs to know.
        case display
    }

    private let preferences: Preferences
    private let health: Health
    private let onChange: (Change) -> Void

    /// The live session list, supplied by the app after construction — the tab
    /// is built once and the sessions change constantly, so it is read on every
    /// `show` rather than captured at init.
    var choices: (() -> [SessionChoice])?
    var onFollow: ((String?) -> Void)?

    private let tabs = NSTabView()
    private var healthStack: NSStackView?
    private var remoteStatus: NSTextField?
    private var hostPicker: NSPopUpButton?
    private var tokenField: NSTextField?
    /// Internal rather than private so the tests can read back what the picker
    /// was rebuilt into. Nothing else touches them.
    private(set) var sessionPicker: NSPopUpButton?
    private var followToggle: NSButton?

    public init(preferences: Preferences, health: Health, onChange: @escaping (Change) -> Void) {
        self.preferences = preferences
        self.health = health
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "claude-status"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        tabs.translatesAutoresizingMaskIntoConstraints = false
        for tab in Tab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = view(for: tab)
            tabs.addTabViewItem(item)
        }
        window.contentView = tabs

        // Health redraws itself while the window is open, so a dropped tunnel
        // shows up without the user having to close and reopen the window.
        health.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshHealth() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public func show(tab: Tab) {
        tabs.selectTabViewItem(at: tab.rawValue)
        refreshHealth()
        refreshSessions()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout helpers

    private func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -2)
        ])
        return scroll
    }

    private func label(_ text: String, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : .systemFont(ofSize: secondary ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
        if secondary { field.textColor = .secondaryLabelColor }
        field.preferredMaxLayoutWidth = 460
        return field
    }

    /// A labelled text field, disabled and annotated when an environment
    /// variable is winning — a control that silently does nothing is worse than
    /// no control at all.
    private func row(_ field: Preferences.Field, value: String,
                     onEdit: @escaping (String) -> Void) -> NSView {
        let input = NSTextField(string: value)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.widthAnchor.constraint(equalToConstant: 300).isActive = true
        input.target = self
        input.action = #selector(fieldCommitted(_:))
        input.identifier = NSUserInterfaceItemIdentifier(field.key)
        editHandlers[field.key] = onEdit

        let stack = NSStackView(views: [label(field.label), input])
        stack.orientation = .horizontal
        stack.spacing = 8

        guard let override = preferences.override(field) else { return stack }
        input.stringValue = override
        input.isEnabled = false
        let note = label("Set by \(field.environmentVariable) in the environment, which wins over "
                       + "this window. Unset it and relaunch to edit here.", secondary: true)
        let column = NSStackView(views: [stack, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    private var editHandlers: [String: (String) -> Void] = [:]

    @objc private func fieldCommitted(_ sender: NSTextField) {
        guard let key = sender.identifier?.rawValue, let handler = editHandlers[key] else { return }
        handler(sender.stringValue)
        onChange(.wire)
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        return button
    }

    /// A checkbox that admits when an environment variable is deciding for it.
    ///
    /// Same reasoning as `row`: a control that silently does nothing is worse
    /// than no control. Returns the button too, so callers that need to read it
    /// back later can hold on to it.
    private func checkbox(_ field: Preferences.Field, title: String, on: Bool,
                          action: Selector) -> (view: NSView, button: NSButton) {
        let button = checkbox(title, on: on, action: action)
        guard let override = preferences.override(field) else { return (button, button) }

        button.state = (override == "1" || override == "true") ? .on : .off
        button.isEnabled = false
        let column = NSStackView(views: [
            button,
            label("Set by \(field.environmentVariable) in the environment, which wins over this "
                + "window. Unset it and relaunch to change it here.", secondary: true)
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return (column, button)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return box
    }

    // MARK: - Pages

    private func view(for tab: Tab) -> NSView {
        switch tab {
        case .general:  return generalPage()
        case .sessions: return sessionsPage()
        case .security: return securityPage()
        case .remote:   return remotePage()
        case .health:   return healthPage()
        }
    }

    private func generalPage() -> NSView {
        var views: [NSView] = [
            row(Preferences.Keys.port, value: String(preferences.port)) { [weak self] raw in
                guard let port = UInt16(raw.trimmingCharacters(in: .whitespaces)), port > 0 else { return }
                self?.preferences.port = port
            },
            label("Both the pet and the hooks use this port. Changing it here means changing "
                + "CLAUDE_STATUS_PORT on any machine that reports in, and the RemoteForward line "
                + "for any SSH host.", secondary: true),
            separator(),
            row(Preferences.Keys.clickTarget, value: preferences.clickTarget) { [weak self] raw in
                self?.preferences.clickTarget = raw
            },
            label("An app path or a bundle id. Point it at your terminal or editor if that's "
                + "where you actually work.", secondary: true),
            separator(),
            row(Preferences.Keys.artPath, value: preferences.artPath) { [weak self] raw in
                self?.preferences.artPath = raw
            },
            label("A PNG here replaces the drawn sprite and still inherits the motion.",
                  secondary: true),
            separator(),
            checkbox(Preferences.Keys.debugLogging, title: "Log every event to stderr",
                     on: preferences.debugLogging, action: #selector(toggleDebug(_:))).view
        ]

        let launch = checkbox("Launch at login", on: preferences.launchAtLogin,
                              action: #selector(toggleLaunchAtLogin(_:)))
        if case .unavailable(let why) = LoginItem.availability {
            launch.isEnabled = false
            views.append(contentsOf: [launch, label(why.prefix(1).uppercased() + why.dropFirst() + ".",
                                                    secondary: true)])
        } else {
            views.append(launch)
        }

        return page(views)
    }

    /// Everything about which sessions the pet shows, and how you tell them
    /// apart once it is showing several.
    private func sessionsPage() -> NSView {
        let follow = checkbox(Preferences.Keys.followOneSession,
                              title: "Follow one session at a time",
                              on: preferences.followOneSession,
                              action: #selector(toggleFollowOne(_:)))
        followToggle = follow.button

        let picker = NSPopUpButton()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(equalToConstant: 340).isActive = true
        picker.target = self
        picker.action = #selector(sessionPicked(_:))
        sessionPicker = picker

        return page([
            label("Which session the pet watches", bold: true),
            label("By default every session collapses into one mood, and whatever needs you wins. "
                + "That is the right answer when you want to know if anything is blocked, and the "
                + "wrong one when four sessions are running and the thought bubble belongs to "
                + "whichever spoke last.", secondary: true),
            follow.view,
            label("The pet's mood, bubble, animation and finish flourish all come from the one "
                + "session. If it ends, the pet adopts another rather than going blank.",
                  secondary: true),
            picker,
            label("Session ids change every time Claude Code starts, so the mode is what is "
                + "remembered, not the session. Right-click the pet to switch without opening "
                + "this window.", secondary: true),
            separator(),
            label("Telling sessions apart", bold: true),
            checkbox(Preferences.Keys.colorCodedBubbles,
                     title: "Colour-code thought bubbles by session",
                     on: preferences.colorCodedBubbles,
                     action: #selector(toggleBubbleColors(_:))).view,
            label("Colours are handed out in the order sessions appear and stay put for as long as "
                + "the session lasts. The first is always black, so nothing changes until there is "
                + "a second session to tell it from. The same colours mark the hover panel and the "
                + "right-click menu, which is where you learn what each one means.", secondary: true),
            paletteLegend()
        ])
    }

    /// The palette itself, drawn from the same source the pet draws from, so it
    /// cannot describe colours the pet does not use.
    private func paletteLegend() -> NSView {
        let swatches = SessionPalette.colors.map { color -> NSView in
            let image = NSImageView(image: SessionPalette.swatch(color, diameter: 14))
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 14).isActive = true
            image.heightAnchor.constraint(equalToConstant: 14).isActive = true
            return image
        }
        let row = NSStackView(views: swatches + [label("1st … 6th session", secondary: true)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func securityPage() -> NSView {
        let token = NSTextField(string: TokenStore.read(at: preferences.tokenPath) ?? "")
        token.isEditable = false
        token.isSelectable = true
        token.translatesAutoresizingMaskIntoConstraints = false
        token.widthAnchor.constraint(equalToConstant: 320).isActive = true
        token.placeholderString = "no token — the pet accepts any local sender"
        tokenField = token

        let buttons = NSStackView(views: [
            button("Generate", #selector(generateToken)),
            button("Remove", #selector(removeToken)),
            button("Reveal in Finder", #selector(revealToken))
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        return page([
            label("Shared token", bold: true),
            label("This is the real boundary. A request without a matching token is refused before "
                + "it becomes a session. Recommended on any host you share with other people — "
                + "and the Remote tab installs it for you.", secondary: true),
            token,
            buttons,
            label("Stored at \(preferences.tokenPath), mode 600.", secondary: true),
            separator(),
            label("Allowed accounts", bold: true),
            label("Loopback is per-machine, not per-user: on a shared host the RemoteForward binds "
                + "one address for the whole box, so a colleague's hooks post into your tunnel. "
                + "Listing your own accounts keeps their work off your desktop. Leave empty to "
                + "accept everyone.", secondary: true),
            row(Preferences.Keys.allowedUsers,
                value: preferences.allowedUsers.joined(separator: ", ")) { [weak self] raw in
                    self?.preferences.allowedUsers = Preferences.parseUsers(raw)
                },
            label("⚠︎ This is convenience filtering, not a security boundary. The account name is "
                + "self-reported by the hook, so anyone with a shell on that host can claim to be "
                + "you. Use the token for an actual boundary.", secondary: true)
        ])
    }

    private func remotePage() -> NSView {
        let picker = NSPopUpButton()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(equalToConstant: 260).isActive = true
        hostPicker = picker

        let status = label("")
        status.preferredMaxLayoutWidth = 460
        remoteStatus = status

        let actions = NSStackView(views: [
            button("Add tunnel to ~/.ssh/config", #selector(addForward)),
            button("Install token on host", #selector(installToken))
        ])
        actions.orientation = .horizontal
        actions.spacing = 8

        let view = page([
            label("SSH hosts", bold: true),
            label("Claude Code runs on the remote host; the pet runs here. One SSH reverse tunnel "
                + "connects them, and the same plugin config works on both ends.", secondary: true),
            NSStackView(views: [picker, button("Rescan", #selector(rescanHosts))]),
            actions,
            button("Test tunnel", #selector(testTunnel)),
            separator(),
            status
        ])
        rescanHosts()
        return view
    }

    private func healthPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        healthStack = stack

        let view = page([
            label("Connection", bold: true),
            label("What the pet knows about its own plumbing. A still pet has four different "
                + "causes and they need four different fixes.", secondary: true),
            stack,
            button("Refresh", #selector(refreshHealthAction))
        ])
        refreshHealth()
        return view
    }

    // MARK: - Actions

    @objc private func toggleDebug(_ sender: NSButton) {
        preferences.debugLogging = sender.state == .on
        onChange(.wire)
    }

    @objc private func toggleFollowOne(_ sender: NSButton) {
        preferences.followOneSession = sender.state == .on
        onChange(.display)
        refreshSessions()
    }

    @objc private func toggleBubbleColors(_ sender: NSButton) {
        preferences.colorCodedBubbles = sender.state == .on
        onChange(.display)
        refreshSessions()
    }

    @objc private func sessionPicked(_ sender: NSPopUpButton) {
        // A nil represented object is the "All sessions" row, which is also the
        // way out of single-session mode from here.
        let id = sender.selectedItem?.representedObject as? String
        onFollow?(id)
        followToggle?.state = id == nil ? .off : .on
        refreshSessions()
    }

    /// Rebuilds the session picker from whatever is running right now.
    ///
    /// Called on every `show` as well as after each change: the window is built
    /// once and kept, and sessions come and go while it sits closed.
    func refreshSessions() {
        guard let picker = sessionPicker else { return }
        let choices = self.choices?() ?? []
        let following = preferences.followOneSession

        picker.removeAllItems()
        picker.isEnabled = following && !choices.isEmpty

        guard !choices.isEmpty else {
            picker.addItem(withTitle: "No active sessions")
            return
        }

        picker.addItem(withTitle: "All sessions")
        for choice in choices {
            picker.addItem(withTitle: choice.label)
            picker.lastItem?.representedObject = choice.id
            if let color = choice.color {
                picker.lastItem?.image = SessionPalette.swatch(color)
            }
            if choice.isFollowed { picker.select(picker.lastItem) }
        }
        if !following { picker.selectItem(at: 0) }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        preferences.launchAtLogin = sender.state == .on
        if let problem = LoginItem.set(sender.state == .on) {
            sender.state = LoginItem.isEnabled ? .on : .off
            preferences.launchAtLogin = LoginItem.isEnabled
            present(problem)
        }
    }

    @objc private func generateToken() {
        let token = TokenStore.generate()
        do {
            try TokenStore.write(token, to: preferences.tokenPath)
            tokenField?.stringValue = token
            onChange(.wire)
            present("""
            A new token is in place on this Mac. Every machine that reports in needs the same \
            value — use “Install token on host” on the Remote tab for SSH hosts.
            """)
        } catch {
            present("Could not write the token: \(error.localizedDescription)")
        }
    }

    @objc private func removeToken() {
        try? FileManager.default.removeItem(atPath: preferences.tokenPath)
        tokenField?.stringValue = ""
        onChange(.wire)
    }

    @objc private func revealToken() {
        NSWorkspace.shared.selectFile(preferences.tokenPath,
                                      inFileViewerRootedAtPath: (preferences.tokenPath as NSString)
                                        .deletingLastPathComponent)
    }

    @objc private func rescanHosts() {
        guard let picker = hostPicker else { return }
        picker.removeAllItems()

        let hosts = SSHConfig.load(port: preferences.port)
        guard !hosts.isEmpty else {
            picker.addItem(withTitle: "No hosts in ~/.ssh/config")
            picker.isEnabled = false
            return
        }
        picker.isEnabled = true
        for host in hosts {
            let suffix = host.hasForward ? " ✓ tunnel configured" : ""
            picker.addItem(withTitle: host.alias + suffix)
            picker.lastItem?.representedObject = host.alias
        }
    }

    private var selectedHost: String? {
        hostPicker?.selectedItem?.representedObject as? String
    }

    @objc private func addForward() {
        guard let alias = selectedHost else { return present("Pick a host first.") }

        let existing = (try? String(contentsOfFile: SSHConfig.path, encoding: .utf8)) ?? ""
        if SSHConfig.parse(existing, port: preferences.port)
            .first(where: { $0.alias == alias })?.hasForward == true {
            return present("\(alias) already forwards port \(preferences.port).")
        }

        let updated = SSHConfig.adding(alias: alias, port: preferences.port, to: existing)
        let alert = NSAlert()
        alert.messageText = "Add this line to ~/.ssh/config?"
        alert.informativeText = """
        Host \(alias)
        \(SSHConfig.forwardLine(port: preferences.port))

        A timestamped backup of the current config is kept. RemoteForward only applies to new \
        connections, so reconnect any open session to \(alias) afterwards.
        """
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let backup = try SSHConfig.write(updated)
            rescanHosts()
            present("Added. Backup: \(backup ?? "none needed"). Reconnect to \(alias), then Test tunnel.")
        } catch {
            present("Could not write ~/.ssh/config: \(error.localizedDescription)")
        }
    }

    @objc private func installToken() {
        guard let alias = selectedHost else { return present("Pick a host first.") }
        guard let token = TokenStore.read(at: preferences.tokenPath) else {
            return present("No token on this Mac yet — generate one on the Security tab first.")
        }
        run("Installing token on \(alias)…") { RemoteProbe.installToken(token, on: alias) }
    }

    @objc private func testTunnel() {
        guard let alias = selectedHost else { return present("Pick a host first.") }
        let port = preferences.port
        run("Testing \(alias)…") { RemoteProbe.test(alias: alias, port: port) }
    }

    /// SSH takes seconds and must not freeze the window.
    private func run(_ pending: String, _ work: @escaping () -> RemoteProbe.Outcome) {
        remoteStatus?.stringValue = pending
        remoteStatus?.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = work()
            DispatchQueue.main.async { [weak self] in
                self?.remoteStatus?.stringValue = "\(outcome.ok ? "✓" : "✗") \(outcome.headline)\n\(outcome.detail)"
                self?.remoteStatus?.textColor = outcome.ok ? .labelColor : .systemRed
            }
        }
    }

    @objc private func refreshHealthAction() { refreshHealth() }

    private func refreshHealth() {
        guard let stack = healthStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for line in health.report() {
            let mark = line.ok.map { $0 ? "✓" : "✗" } ?? "•"
            let text = label("\(mark)  \(line.label): \(line.value)")
            text.textColor = line.ok == false ? .systemRed : .labelColor
            stack.addArrangedSubview(text)
        }
    }

    private func present(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "claude-status"
        alert.informativeText = message
        alert.runModal()
    }
}
