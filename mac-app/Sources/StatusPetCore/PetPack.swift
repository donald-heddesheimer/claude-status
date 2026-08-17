import AppKit

/// Owns the pet and routes events to it.
///
/// One pet, whatever is talking to it. Codex, opencode, or anything else
/// speaking the same protocol shares Claude's critter and session list rather
/// than getting one of its own — see `SessionStore.multipleAgents` for how the
/// thought bubble and hover panel say which agent is which once there's more
/// than one. A separate critter per agent was built and worked, but a second
/// window competing for desktop space wasn't worth it for what amounts to a
/// colour and a name.
final class PetPack {
    /// The pet's saved-position key and default tint. Not a filter any more —
    /// every agent shares this one pet.
    static let primary = "claude-code"

    private let claude = PetController(store: SessionStore(), agent: primary, slot: 0)

    /// App-level menu items (Settings, Health, Updates) appended to every pet's
    /// context menu. Supplied by the app so the pet stays ignorant of it.
    var menuExtras: (() -> [NSMenuItem])? {
        didSet { claude.menuExtras = menuExtras }
    }

    init() {
        claude.show()
    }

    /// The sessions the Settings window offers, and how it picks one.
    var choices: [SessionChoice] { claude.store.choices }

    func follow(_ id: String?) { claude.follow(id) }

    /// Re-reads the display preferences after Settings changes one.
    func applyPreferences() { claude.applyPreferences() }

    func apply(_ event: StateEvent) {
        claude.store.apply(event)
    }
}
