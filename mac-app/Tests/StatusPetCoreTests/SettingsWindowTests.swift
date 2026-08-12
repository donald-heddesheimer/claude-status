import AppKit
import XCTest
@testable import StatusPetCore

/// Construction smoke tests for the Settings window.
///
/// Every page is built in `init`, so simply making the controller exercises all
/// of the layout code — which is the half of this app that unit tests otherwise
/// never reach, and the half where a mistake shows up as a window that opens
/// blank rather than as a compile error.
final class SettingsWindowTests: XCTestCase {

    /// A window driven by an in-memory store, so nothing here can read or write
    /// the settings of a pet actually running on this machine.
    private func controller(_ environment: [String: String] = [:],
                            choices: @escaping () -> [SessionChoice] = { [] })
        -> (SettingsWindowController, changes: () -> [SettingsWindowController.Change]) {
        var environment = environment
        environment["CLAUDE_STATUS_USERS_FILE"] = "/nonexistent/claude-status/users"
        let preferences = Preferences(defaults: MemoryStore(), environment: environment)

        var recorded: [SettingsWindowController.Change] = []
        let controller = SettingsWindowController(
            preferences: preferences, health: Health(), onChange: { recorded.append($0) })
        controller.choices = choices
        return (controller, { recorded })
    }

    func testEveryTabBuildsAView() {
        let (window, _) = controller()
        guard let tabs = window.window?.contentView as? NSTabView else {
            return XCTFail("the window should hold the tab view")
        }
        XCTAssertEqual(tabs.tabViewItems.count, SettingsWindowController.Tab.allCases.count)
        for item in tabs.tabViewItems {
            XCTAssertNotNil(item.view, "\(item.label) built no view")
        }
    }

    /// The picker is rebuilt from whatever is running, which is nothing at all
    /// most of the time.
    func testTheSessionPickerSurvivesHavingNoSessions() {
        let (window, _) = controller()
        window.refreshSessions()
    }

    func testTheSessionPickerListsSessionsWithAWayBackOut() {
        // Following is on, which is the only state in which a choice can report
        // itself as followed — the two are the same switch.
        let (window, _) = controller(["CLAUDE_STATUS_FOLLOW_ONE": "1"], choices: {
            [SessionChoice(id: "a", label: "local · alpha — working", color: SessionPalette.ink,
                           isFollowed: false),
             SessionChoice(id: "b", label: "devbox (ssh) · beta — waiting",
                           color: SessionPalette.color(slot: 1), isFollowed: true)]
        })
        window.refreshSessions()

        guard let picker = window.sessionPicker else {
            return XCTFail("the sessions tab should own a picker")
        }
        XCTAssertEqual(picker.numberOfItems, 3, "two sessions plus a way back to all of them")
        XCTAssertEqual(picker.item(at: 0)?.title, "All sessions")
        XCTAssertEqual(picker.selectedItem?.representedObject as? String, "b",
                       "the followed session is the one shown")
        XCTAssertNotNil(picker.item(at: 1)?.image, "a swatch, so the colour means something here too")
    }

    /// Not following means the picker shows "All sessions" whatever else it was
    /// told, since the two controls are one switch and must not disagree.
    func testThePickerShowsAllSessionsWhenNotFollowing() {
        let (window, _) = controller(choices: {
            [SessionChoice(id: "a", label: "local · alpha — working", color: nil, isFollowed: false)]
        })
        window.refreshSessions()

        XCTAssertEqual(window.sessionPicker?.indexOfSelectedItem, 0)
        XCTAssertEqual(window.sessionPicker?.isEnabled, false,
                       "and there is nothing to pick until you ask for one session")
    }

    /// A control that silently does nothing is worse than no control, so a flag
    /// the environment is deciding has to say so rather than sit there enabled
    /// and ignored.
    func testAFlagSetInTheEnvironmentIsShownAsOverridden() {
        let (window, _) = controller(["CLAUDE_STATUS_BUBBLE_COLORS": "0"])
        guard let tabs = window.window?.contentView as? NSTabView,
              let sessions = tabs.tabViewItem(at: SettingsWindowController.Tab.sessions.rawValue).view
        else { return XCTFail("no sessions tab") }

        let boxes = checkboxes(in: sessions)
        guard let colorBox = boxes.first(where: { $0.title.contains("Colour-code") }) else {
            return XCTFail("no colour checkbox")
        }
        XCTAssertFalse(colorBox.isEnabled)
        XCTAssertEqual(colorBox.state, .off, "and it shows what the environment actually says")
    }

    /// Restarting the listener because someone ticked a colour box would drop
    /// the socket out from under any hook posting at that instant.
    func testDisplayTogglesDoNotAskForTheListenerBack() {
        let (window, changes) = controller()
        guard let tabs = window.window?.contentView as? NSTabView,
              let sessions = tabs.tabViewItem(at: SettingsWindowController.Tab.sessions.rawValue).view
        else { return XCTFail("no sessions tab") }

        for box in checkboxes(in: sessions) {
            box.state = .on
            _ = box.target?.perform(box.action, with: box)
        }

        XCTAssertFalse(changes().isEmpty, "the toggles should report something")
        XCTAssertTrue(changes().allSatisfy { $0 == .display })
    }

    /// The swatch is built by a drawing handler, which does not run until
    /// something asks for pixels. Ask.
    func testEveryPaletteSwatchRenders() {
        for color in SessionPalette.colors {
            XCTAssertNotNil(SessionPalette.swatch(color).tiffRepresentation)
        }
    }

    private func checkboxes(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton, !button.title.isEmpty { found.append(button) }
        // A clip view already lists the document view among its subviews, so a
        // plain walk reaches everything inside the page's scroll view.
        for subview in view.subviews { found += checkboxes(in: subview) }
        return found
    }
}
