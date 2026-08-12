import Foundation
import ServiceManagement

/// Start-at-login, via the modern `SMAppService` API.
///
/// This only works for a real bundled `.app`. A `swift run` build has no bundle
/// identifier and no `Contents/Info.plist` for launchd to register, so the
/// control reports itself unavailable rather than throwing something unhelpful
/// at a developer who is just iterating on the sprite.
public enum LoginItem {
    public enum Availability {
        case available
        case unavailable(String)
    }

    public static var availability: Availability {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else {
            return .unavailable("only available when running the installed app")
        }
        return .available
    }

    public static var isEnabled: Bool {
        guard case .available = availability else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a message worth showing the user.
    @discardableResult
    public static func set(_ enabled: Bool) -> String? {
        if case .unavailable(let why) = availability { return why }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            // The usual cause is the user having denied login items in System
            // Settings, which we cannot override and shouldn't pretend to.
            return "\(error.localizedDescription) — check Login Items in System Settings"
        }
    }
}
