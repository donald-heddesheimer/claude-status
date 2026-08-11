import AppKit

// Config comes from the environment so the same binary works for anyone.
let environment = ProcessInfo.processInfo.environment
let port = UInt16(environment["CLAUDE_STATUS_PORT"] ?? "") ?? 7777

let tokenPath = environment["CLAUDE_STATUS_TOKEN_FILE"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-status/token")
let token = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)

let application = NSApplication.shared
// Accessory: no Dock icon, no menu bar, never steals focus.
application.setActivationPolicy(.accessory)

let store = SessionStore()
let controller = PetController(store: store)

let server = StateServer(port: port, token: token) { event in
    // The network runs off the main thread; all UI state changes hop back.
    DispatchQueue.main.async {
        store.apply(event)
    }
}

do {
    try server.start()
} catch {
    let message = """
    claude-status: could not bind 127.0.0.1:\(port) — \(error.localizedDescription)

    Another process is probably already on that port. Check with:
        lsof -nP -iTCP:\(port) -sTCP:LISTEN

    """
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

let banner = """
claude-status: pet listening on 127.0.0.1:\(port)\
\(token.map { _ in " (token required)" } ?? "")
Right-click the pet to quit.

"""
FileHandle.standardOutput.write(Data(banner.utf8))

controller.show()
application.run()
