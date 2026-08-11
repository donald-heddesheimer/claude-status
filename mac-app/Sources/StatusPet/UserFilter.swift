import Foundation

/// Which accounts are allowed to drive this pet.
///
/// Loopback is per-machine, not per-user. On a shared host the hook's
/// `127.0.0.1:7777` is one address for the whole box, and the SSH RemoteForward
/// bound to it belongs to whoever connected — so every colleague on that
/// machine running claude-status posts into *your* pet. You end up watching
/// their file names and Bash descriptions, and their permission prompts make
/// your pet demand attention for work you can't even see.
///
/// Naming the accounts you own fixes that. Unconfigured, the pet accepts
/// everyone, which is the right default on a machine only you use.
final class UserFilter {
    /// nil means "no filter configured" — accept anything.
    private let allowed: Set<String>?

    /// Accounts already reported as rejected, so a chatty session logs once
    /// rather than on every keystroke.
    private var reported: Set<String> = []

    init(allowed: Set<String>?) {
        self.allowed = allowed
    }

    /// Reads `CLAUDE_STATUS_USERS` first, then `~/.claude-status/users` — a file
    /// so the setting survives however you happen to launch the pet.
    ///
    /// Your own Mac account is always allowed. Filtering exists to keep other
    /// people's remote sessions out, and silently dropping your local ones would
    /// be a nasty surprise.
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserFilter {
        var names: [String]

        if let raw = environment["CLAUDE_STATUS_USERS"] {
            names = raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        } else {
            let path = environment["CLAUDE_STATUS_USERS_FILE"]
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-status/users")
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                return UserFilter(allowed: nil)
            }
            names = contents
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }

        guard !names.isEmpty else { return UserFilter(allowed: nil) }

        var allowed = Set(names.map { $0.lowercased() })
        allowed.insert(NSUserName().lowercased())
        return UserFilter(allowed: allowed)
    }

    var describe: String? {
        guard let allowed else { return nil }
        return allowed.sorted().joined(separator: ", ")
    }

    /// Events from an unlisted account are dropped.
    ///
    /// An event with no account at all came from a plugin older than 0.1.3.
    /// Those are judged by where they arrived from: a *local* one reached this
    /// port from a process on this Mac, which is you, so it's kept and an
    /// out-of-date local install keeps working. A *remote* one came down a
    /// tunnel from a machine you may well share, which is the entire case this
    /// filter exists for, so it's dropped.
    func accepts(_ event: StateEvent) -> Bool {
        guard let allowed else { return true }
        if allowed.contains(event.user.lowercased()) { return true }
        if event.user.isEmpty, !event.remote { return true }
        report(event.user)
        return false
    }

    private func report(_ user: String) {
        let key = user.isEmpty ? "<none>" : user.lowercased()
        guard reported.insert(key).inserted else { return }

        let message = user.isEmpty
            ? "claude-status: ignoring events with no user — that machine's plugin predates 0.1.3\n"
            : "claude-status: ignoring events from '\(user)' — not in the allowed users list\n"
        FileHandle.standardError.write(Data(message.utf8))
    }
}
