import AppKit

/// One pet per agent.
///
/// `agent_source` has been on the wire since the first version, and petdex
/// reserves the same field for "route per-pet when we ship multi-mascot". This
/// is that routing: Claude Code, Codex and anything else that speaks the
/// protocol each get their own critter, their own session list and their own
/// saved position, rather than fighting over one window.
///
/// Sessions from different agents were never comparable anyway — collapsing
/// Codex's "waiting" and Claude's "working" into a single mood produces a pet
/// that is lying about both.
final class PetPack {
    /// The agent that always has a pet, even with nothing running. Without it
    /// the desktop would be empty until the first event, and you'd have no way
    /// to tell "idle" from "not installed".
    static let primary = "claude-code"

    private var pets: [String: PetController] = [:]
    /// Insertion order, so a pet doesn't jump position when another appears.
    private var order: [String] = []

    init() {
        _ = pet(for: Self.primary)
    }

    func apply(_ event: StateEvent) {
        let controller = pet(for: event.agentSource)
        controller.store.apply(event)
        pruneEmptyPets()
    }

    /// Called on the sweep timer as well as on events, so a pet whose sessions
    /// all timed out goes away without needing one more packet to notice.
    func pruneEmptyPets() {
        for (agent, controller) in pets where agent != Self.primary {
            guard controller.store.sessions.isEmpty else { continue }
            controller.close()
            pets[agent] = nil
            order.removeAll { $0 == agent }
        }
        relabel()
    }

    private func pet(for agent: String) -> PetController {
        if let existing = pets[agent] { return existing }

        let controller = PetController(
            store: SessionStore(),
            agent: agent,
            slot: order.count
        )
        pets[agent] = controller
        order.append(agent)
        controller.show()
        relabel()
        return controller
    }

    /// The agent name is only worth screen space when there's something to tell
    /// apart. One pet on its own is unambiguous.
    private func relabel() {
        let showNames = pets.count > 1
        for (agent, controller) in pets {
            controller.agentLabel = showNames ? Self.displayName(agent) : nil
        }
    }

    static func displayName(_ agent: String) -> String {
        switch agent {
        case "claude-code": return "Claude"
        case "codex":       return "Codex"
        case "opencode":    return "opencode"
        case "antigravity": return "Antigravity"
        default:            return agent.capitalized
        }
    }

    /// A stable colour per agent so you learn which pet is which by sight.
    /// Claude keeps the clay it was drawn in; everyone else gets a hue derived
    /// from their name, which is deterministic without needing a table.
    static func tint(for agent: String) -> NSColor {
        if agent == primary {
            return NSColor(calibratedRed: 0.843, green: 0.471, blue: 0.353, alpha: 1)
        }
        var hash: UInt64 = 5381
        for byte in agent.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        // Skip the arc around Claude's own orange so the pets stay distinct.
        let hue = 0.30 + (Double(hash % 1000) / 1000.0) * 0.62
        return NSColor(calibratedHue: CGFloat(hue), saturation: 0.52,
                       brightness: 0.88, alpha: 1)
    }
}
