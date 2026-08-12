import AppKit

/// Owns the pet and routes events to it.
///
/// `agent_source` is parsed off every event and used to decide whether we care
/// about it. Today only Claude Code gets a pet; see the TODO below.
final class PetPack {
    /// The only agent with a pet right now.
    static let primary = "claude-code"

    private let claude = PetController(store: SessionStore(), agent: primary, slot: 0)
    /// Agents already reported as ignored, so a busy one says so once.
    private var reported: Set<String> = []

    /// App-level menu items (Settings, Health, Updates) appended to every pet's
    /// context menu. Supplied by the app so the pet stays ignorant of it.
    var menuExtras: (() -> [NSMenuItem])? {
        didSet { claude.menuExtras = menuExtras }
    }

    init() {
        claude.show()
    }

    /// The sessions the Settings window offers, and how it picks one. Routed
    /// through here rather than handing Settings the store, so the day the
    /// per-agent block below comes back there is one place to decide which
    /// pet's sessions the window is talking about.
    var choices: [SessionChoice] { claude.store.choices }

    func follow(_ id: String?) { claude.follow(id) }

    /// Re-reads the display preferences after Settings changes one.
    func applyPreferences() { claude.applyPreferences() }

    func apply(_ event: StateEvent) {
        // Events from other agents are dropped rather than folded in — a Codex
        // session showing up as one of Claude's would misreport both.
        guard event.agentSource == Self.primary else {
            report(event.agentSource)
            return
        }
        claude.store.apply(event)
    }

    /// Said out loud because the event passed every other check to get here.
    /// Dropping it silently would look like the tunnel was broken.
    private func report(_ agent: String) {
        guard reported.insert(agent).inserted else { return }
        FileHandle.standardError.write(Data(
            "claude-status: ignoring events from '\(agent)' — only \(Self.primary) has a pet\n".utf8))
    }

    // MARK: - TODO: one pet per agent
    //
    // Parked, not abandoned. This worked — Codex, opencode and anything else
    // speaking the protocol each got its own critter, session list, colour and
    // saved position, routed on `agent_source`. It's shelved until there's a
    // second agent actually worth watching on this desktop.
    //
    // To restore: swap the single `claude` controller for the registry below,
    // call `pruneEmptyPets()` from the sweep timer in main.swift, and drop the
    // `guard` in `apply`.
    //
    // petdex reserves the same field for this — "stamp agent_source so the
    // sidecar can route per-pet when we ship multi-mascot" — and doesn't route
    // on it either, so there's no interop cost to leaving it off.
    //
    //     private var pets: [String: PetController] = [:]
    //     /// Insertion order, so a pet doesn't jump when another appears.
    //     private var order: [String] = []
    //
    //     private func pet(for agent: String) -> PetController {
    //         if let existing = pets[agent] { return existing }
    //         let controller = PetController(store: SessionStore(),
    //                                        agent: agent, slot: order.count)
    //         pets[agent] = controller
    //         order.append(agent)
    //         controller.show()
    //         relabel()
    //         return controller
    //     }
    //
    //     /// Sessions expire on a timer as well as on SessionEnd, so a pet whose
    //     /// agent went quiet needs a nudge to notice it has nothing left.
    //     func pruneEmptyPets() {
    //         for (agent, controller) in pets where agent != Self.primary {
    //             guard controller.store.sessions.isEmpty else { continue }
    //             controller.close()
    //             pets[agent] = nil
    //             order.removeAll { $0 == agent }
    //         }
    //         relabel()
    //     }
    //
    //     /// The agent name is only worth screen space when there's something to
    //     /// tell apart. One pet on its own is unambiguous.
    //     private func relabel() {
    //         let showNames = pets.count > 1
    //         for (agent, controller) in pets {
    //             controller.agentLabel = showNames ? Self.displayName(agent) : nil
    //         }
    //     }
    //
    //     static func displayName(_ agent: String) -> String {
    //         switch agent {
    //         case "claude-code": return "Claude"
    //         case "codex":       return "Codex"
    //         case "opencode":    return "opencode"
    //         case "antigravity": return "Antigravity"
    //         default:            return agent.capitalized
    //         }
    //     }

    /// A stable colour per agent, so pets stay distinguishable if the block
    /// above comes back. Claude keeps the clay it was drawn in; everyone else
    /// gets a hue derived from their name, deterministic without a table.
    static func tint(for agent: String) -> NSColor {
        if agent == primary {
            return PetView.clay
        }
        var hash: UInt64 = 5381
        for byte in agent.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        // Skip the arc around Claude's own orange so the pets stay distinct.
        let hue = 0.30 + (Double(hash % 1000) / 1000.0) * 0.62
        return NSColor(calibratedHue: CGFloat(hue), saturation: 0.52,
                       brightness: 0.88, alpha: 1)
    }
}
