import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

/// Entry point. `main.swift` is one line so that everything here stays inside
/// the library target, where the tests can reach it.
public enum StatusPetApp {
    // NSApplication holds its delegate weakly.
    private static var delegate: AppDelegate?

    public static func main() {
        // Used by scripts/build-app.sh so the icon is generated from the same
        // pixel map the pet is drawn from, rather than committed as a binary
        // that quietly drifts away from it.
        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "--export-icon" {
            exit(IconExporter.writeIconSet(to: arguments[2]) ? 0 : 1)
        }
        // Regenerates the README's state strip. Same reasoning as the icon:
        // documentation art drawn by hand drifts from the pet it documents.
        if arguments.count >= 3, arguments[1] == "--export-states" {
            exit(StatesExporter.writeStrip(to: arguments[2]) ? 0 : 1)
        }
        if arguments.count >= 3, arguments[1] == "--export-sessions" {
            exit(SessionsExporter.writeStrip(to: arguments[2]) ? 0 : 1)
        }
        if arguments.count >= 3, arguments[1] == "--export-agents" {
            exit(AgentsExporter.writeStrip(to: arguments[2]) ? 0 : 1)
        }
        if arguments.count >= 3, arguments[1] == "--export-animation" {
            exit(AnimationExporter.writeGIF(to: arguments[2]) ? 0 : 1)
        }

        let app = NSApplication.shared
        // Accessory: no Dock icon, no menu bar, never steals focus.
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences.shared
    let health = Health()

    private var pack: PetPack!
    private var users: UserFilter!
    private var server: StateServer?
    private var settings: SettingsWindowController?

    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    #if canImport(Sparkle)
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        users = UserFilter.from(preferences)
        pack = PetPack()
        pack.menuExtras = { [weak self] in self?.menuExtras() ?? [] }

        applyLoginItemPreference()
        startListener()

        #if canImport(Sparkle)
        _ = updater
        #endif
    }

    // MARK: - Listener

    /// Reads the token fresh each time, so changing it in Settings takes effect
    /// on the restart rather than at next launch.
    private func currentToken() -> String? {
        let path = preferences.tokenPath
        if let problem = TokenStore.tightenIfNeeded(at: path) {
            health.note(problem)
        }
        return TokenStore.read(at: path)
    }

    func startListener() {
        server?.stop()

        let port = preferences.port
        let token = currentToken()
        let debug = preferences.debugLogging

        let server = StateServer(port: port, token: token) { [weak self] verdict in
            // The network runs off the main thread; all UI state changes hop
            // back. The filter check rides along on that hop, which is also what
            // keeps its "already reported this account" set to a single thread.
            DispatchQueue.main.async {
                self?.handle(verdict, debug: debug)
            }
        }
        self.server = server

        do {
            try server.start(
                onReady: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.health.listenerBound(port: port)
                        let banner = """
                        claude-status: pet listening on 127.0.0.1:\(port)\
                        \(token.map { _ in " (token required)" } ?? " (no token)")
                        \(self.users.describe.map { "accepting sessions from: \($0)" }
                            ?? "accepting sessions from any account")
                        Right-click the pet for settings.

                        """
                        FileHandle.standardOutput.write(Data(banner.utf8))
                    }
                },
                onFailure: { [weak self] message in
                    DispatchQueue.main.async {
                        self?.listenerFailed(port: port, message: message)
                    }
                })
        } catch {
            listenerFailed(port: port, message: error.localizedDescription)
        }
    }

    /// A port collision used to be fatal, which was right for a terminal app and
    /// wrong for a windowed one: quitting on launch just looks like the app is
    /// broken. Now it stays up, says so in Health, and Settings can move it to a
    /// free port without a relaunch.
    private func listenerFailed(port: UInt16, message: String) {
        health.listenerFailed("port \(port) unavailable — \(message)")
        FileHandle.standardError.write(Data("""
        claude-status: could not listen on 127.0.0.1:\(port) — \(message)

        Another pet is most likely already running. Check with:
            lsof -nP -iTCP:\(port) -sTCP:LISTEN

        Open Settings from the pet's right-click menu to pick another port.

        """.utf8))
    }

    private func handle(_ verdict: Verdict, debug: Bool) {
        switch verdict {
        case .reject(_, let reason, let detail):
            health.rejected(reason: reason, detail: detail)
            if debug {
                log("DROP \(reason)\(detail.isEmpty ? "" : " — \(detail)")")
            }

        case .accept(let event):
            switch users.decide(event) {
            case .reject(let reason, let detail):
                health.rejected(reason: reason, detail: detail)
                if debug { log("DROP \(describe(event)) — \(reason)") }
            case .accept:
                health.accepted(event)
                if debug { log("take \(describe(event))") }
                pack.apply(event)
            }
        }
    }

    /// CLAUDE_STATUS_DEBUG=1, or the checkbox in Settings. The pet is a glance,
    /// so when it says something you don't recognise — a stray "allow Bash?"
    /// from a session you can't place — this is how you find out who sent it.
    private func log(_ line: String) {
        FileHandle.standardError.write(Data("[\(clock.string(from: Date()))] \(line)\n".utf8))
    }

    private func describe(_ event: StateEvent) -> String {
        "agent=\(event.agentSource) user=\(event.user.nonEmpty ?? "-") "
            + "host=\(event.host)\(event.remote ? " (ssh)" : "") state=\(event.state) "
            + "tool=\(event.tool.nonEmpty ?? "-") detail=\(event.detail.nonEmpty ?? "-") "
            + "session=\(event.sessionID.prefix(8)) cwd=\(event.cwd)"
    }

    // MARK: - Settings

    /// Called by the Settings window after a change, told what the change costs.
    func settingsChanged(_ change: SettingsWindowController.Change) {
        switch change {
        case .wire:
            users = UserFilter.from(preferences)
            applyLoginItemPreference()
            startListener()
        case .display:
            // Nothing on the network cares how the pet looks, and bouncing the
            // listener for a checkbox could drop a hook posting at that instant.
            pack.applyPreferences()
        }
    }

    private func applyLoginItemPreference() {
        guard case .available = LoginItem.availability else { return }
        if let problem = LoginItem.set(preferences.launchAtLogin) {
            health.note("launch at login: \(problem)")
        }
    }

    private func menuExtras() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        items.append(settingsItem)

        // Surfaced in the menu rather than only inside Settings, because the
        // moment you want it is the moment the pet is doing nothing and you're
        // wondering whether it's broken.
        let healthItem = NSMenuItem(title: healthSummary, action: #selector(openHealth),
                                    keyEquivalent: "")
        healthItem.target = self
        items.append(healthItem)

        #if canImport(Sparkle)
        let update = NSMenuItem(title: "Check for Updates…",
                                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                keyEquivalent: "")
        update.target = updater
        items.append(update)
        #endif

        return items
    }

    private var healthSummary: String {
        switch health.listener {
        case .starting: return "Connection: starting…"
        case .failed: return "Connection: not listening"
        case .listening:
            guard let at = health.lastEventAt else { return "Connection: no events yet" }
            return "Connection: last event \(Health.ago(Date().timeIntervalSince(at)))"
        }
    }

    @objc private func openSettings() {
        showSettings(tab: .general)
    }

    @objc private func openHealth() {
        showSettings(tab: .health)
    }

    func showSettings(tab: SettingsWindowController.Tab) {
        if settings == nil {
            let controller = SettingsWindowController(
                preferences: preferences, health: health,
                onChange: { [weak self] change in self?.settingsChanged(change) })
            controller.choices = { [weak self] in self?.pack.choices ?? [] }
            controller.onFollow = { [weak self] id in self?.pack.follow(id) }
            settings = controller
        }
        settings?.show(tab: tab)
    }
}
