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
///
/// **This is convenience filtering, not a security boundary.** The account name
/// is self-reported by the hook, so anyone with a shell on that host can post
/// `"user":"you"` and land on your pet regardless. It exists to keep a
/// colleague's honest work off your desktop. The boundary is the shared token —
/// see `Preferences.tokenPath` and the SSH wizard, which provisions one by
/// default for exactly this reason.
public final class UserFilter {
    public enum Decision: Equatable {
        case accept
        case reject(reason: String, detail: String)
    }

    /// nil means "no filter configured" — accept anything.
    private let allowed: Set<String>?

    /// Accounts already reported as rejected, so a chatty session logs once
    /// rather than on every keystroke.
    private var reported: Set<String> = []

    public init(allowed: Set<String>?) {
        self.allowed = allowed
    }

    /// Builds from the current settings.
    ///
    /// Your own Mac account is always allowed. Filtering exists to keep other
    /// people's remote sessions out, and silently dropping your local ones would
    /// be a nasty surprise.
    public static func from(_ preferences: Preferences,
                            localAccount: String = NSUserName()) -> UserFilter {
        let names = preferences.allowedUsers
        guard !names.isEmpty else { return UserFilter(allowed: nil) }

        var allowed = Set(names.map { $0.lowercased() })
        allowed.insert(localAccount.lowercased())
        return UserFilter(allowed: allowed)
    }

    public var describe: String? {
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
    public func decide(_ event: StateEvent) -> Decision {
        guard let allowed else { return .accept }
        if allowed.contains(event.user.lowercased()) { return .accept }
        if event.user.isEmpty, !event.remote { return .accept }

        report(event.user)
        return event.user.isEmpty
            ? .reject(reason: "no account on a remote event", detail: "plugin older than 0.1.3")
            : .reject(reason: "account not allowed", detail: event.user)
    }

    public func accepts(_ event: StateEvent) -> Bool {
        decide(event) == .accept
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
