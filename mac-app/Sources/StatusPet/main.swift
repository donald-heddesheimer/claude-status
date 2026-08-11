import AppKit

// Config comes from the environment so the same binary works for anyone.
let environment = ProcessInfo.processInfo.environment
let port = UInt16(environment["CLAUDE_STATUS_PORT"] ?? "") ?? 7777

let tokenPath = environment["CLAUDE_STATUS_TOKEN_FILE"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-status/token")
let token = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)

// A shared secret other accounts can read is not a secret. Warn rather than
// refuse to start — the pet's job is to keep working.
if token?.isEmpty == false,
   let permissions = (try? FileManager.default.attributesOfItem(atPath: tokenPath))?[.posixPermissions] as? NSNumber,
   permissions.intValue & 0o077 != 0 {
    FileHandle.standardError.write(Data("""
    claude-status: \(tokenPath) is readable by other accounts (mode \(String(permissions.intValue, radix: 8))).
    Fix it with: chmod 600 \(tokenPath)

    """.utf8))
}

let application = NSApplication.shared
// Accessory: no Dock icon, no menu bar, never steals focus.
application.setActivationPolicy(.accessory)

let pack = PetPack()
let users = UserFilter.load()

// Sessions also disappear on a timer, not only on SessionEnd, so a pet whose
// agent went quiet needs a nudge to notice it has nothing left to show.
let reaper = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
    pack.pruneEmptyPets()
}
RunLoop.main.add(reaper, forMode: .common)

// CLAUDE_STATUS_DEBUG=1 prints every event as it lands. The pet is a glance, so
// when it says something you don't recognise — a stray "allow Bash?" from a
// session you can't place — this is how you find out who sent it.
let debug = (ProcessInfo.processInfo.environment["CLAUDE_STATUS_DEBUG"] ?? "") == "1"

let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

let server = StateServer(port: port, token: token) { event in
    // The network runs off the main thread; all UI state changes hop back.
    // The filter check rides along on that hop, which is also what keeps its
    // "already reported this account" set to a single thread.
    DispatchQueue.main.async {
        let allowed = users.accepts(event)
        if debug {
            let line = "[\(clock.string(from: Date()))] \(allowed ? "take" : "DROP") "
                + "agent=\(event.agentSource) "
                + "user=\(event.user.isEmpty ? "-" : event.user) "
                + "host=\(event.host)\(event.remote ? " (ssh)" : "") "
                + "state=\(event.state) tool=\(event.tool.isEmpty ? "-" : event.tool) "
                + "detail=\(event.detail.isEmpty ? "-" : event.detail) "
                + "session=\(event.sessionID.prefix(8)) cwd=\(event.cwd)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        guard allowed else { return }
        pack.apply(event)
    }
}

do {
    // The banner only prints once the port is actually bound, so seeing it is
    // proof the pet is live rather than a second copy failing quietly.
    try server.start {
        let banner = """
        claude-status: pet listening on 127.0.0.1:\(port)\
        \(token.map { _ in " (token required)" } ?? "")
        \(users.describe.map { "accepting sessions from: \($0)" } ?? "accepting sessions from any account")
        Right-click the pet to quit.

        """
        FileHandle.standardOutput.write(Data(banner.utf8))
    }
} catch {
    let message = """
    claude-status: could not bind 127.0.0.1:\(port) — \(error.localizedDescription)

    Another process is probably already on that port. Check with:
        lsof -nP -iTCP:\(port) -sTCP:LISTEN

    """
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}

application.run()
