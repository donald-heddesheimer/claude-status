import Foundation

/// Every setting the pet has, and where it came from.
///
/// The app used to be configured entirely through the environment, which is
/// fine when you launch it from a terminal and hopeless once it's an installed
/// `.app` that Finder starts with an empty environment. So the store of record
/// is now `UserDefaults`, written by the Settings window.
///
/// Environment variables still win when they're set. That keeps every existing
/// `swift run`-with-exports setup working exactly as it did, and it's genuinely
/// the right precedence for a developer tool — an explicit export at launch is a
/// more specific instruction than something you clicked a week ago. The Settings
/// window shows those fields as overridden rather than pretending it owns them,
/// because a control that silently does nothing is worse than no control.
/// The slice of `UserDefaults` that `Preferences` actually uses.
///
/// Small enough that `UserDefaults` conforms without a single line of adapter,
/// and it keeps the tests off the disk entirely — a `UserDefaults(suiteName:)`
/// is a real plist in `~/Library/Preferences` that survives the test that made
/// it, so a suite-per-test quietly litters every machine and CI runner it
/// touches.
public protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// A `KeyValueStore` that exists only for as long as you hold it.
public final class MemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]

    public init(_ values: [String: Any] = [:]) { self.values = values }

    public func string(forKey key: String) -> String? { values[key] as? String }
    public func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    public func object(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}

public final class Preferences {
    public static let shared = Preferences()

    /// One configurable value: how to read it, where it's stored, what overrides it.
    public struct Field {
        public let key: String
        public let environmentVariable: String
        public let label: String
    }

    public enum Keys {
        public static let port = Field(key: "port", environmentVariable: "CLAUDE_STATUS_PORT", label: "Port")
        public static let clickTarget = Field(key: "clickTarget", environmentVariable: "CLAUDE_STATUS_CLICK_APP", label: "Click opens")
        public static let allowedUsers = Field(key: "allowedUsers", environmentVariable: "CLAUDE_STATUS_USERS", label: "Allowed accounts")
        public static let tokenPath = Field(key: "tokenPath", environmentVariable: "CLAUDE_STATUS_TOKEN_FILE", label: "Token file")
        public static let artPath = Field(key: "artPath", environmentVariable: "CLAUDE_STATUS_ART", label: "Artwork")
        public static let debugLogging = Field(key: "debugLogging", environmentVariable: "CLAUDE_STATUS_DEBUG", label: "Log every event")
        public static let followOneSession = Field(key: "followOneSession", environmentVariable: "CLAUDE_STATUS_FOLLOW_ONE", label: "Follow one session")
        public static let colorCodedBubbles = Field(key: "colorCodedBubbles", environmentVariable: "CLAUDE_STATUS_BUBBLE_COLORS", label: "Colour-code bubbles")
        public static let clickDisabled = Field(key: "clickDisabled", environmentVariable: "CLAUDE_STATUS_CLICK_DISABLE", label: "Clicking does nothing")

        public static let all = [port, clickTarget, allowedUsers, tokenPath, artPath, debugLogging,
                                 followOneSession, colorCodedBubbles, clickDisabled]
    }

    private let defaults: KeyValueStore
    private let environment: [String: String]

    public init(defaults: KeyValueStore = UserDefaults.standard,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        self.environment = environment
        migrateLegacyUsersFile()
    }

    // MARK: - Reading

    /// The environment value for a field, if one is set and non-empty.
    ///
    /// Public because the Settings window disables and annotates any field this
    /// returns a value for.
    public func override(_ field: Field) -> String? {
        environment[field.environmentVariable]?.trimmingCharacters(in: .whitespaces).nonEmpty
    }

    private func string(_ field: Field) -> String? {
        override(field) ?? defaults.string(forKey: field.key)?.nonEmpty
    }

    public var port: UInt16 {
        get { string(Keys.port).flatMap(UInt16.init) ?? 7777 }
        set { defaults.set(String(newValue), forKey: Keys.port.key) }
    }

    public var clickTarget: String {
        get { string(Keys.clickTarget) ?? "/Applications/Claude.app" }
        set { defaults.set(newValue, forKey: Keys.clickTarget.key) }
    }

    /// When on, clicking the pet does nothing instead of opening `clickTarget`.
    /// For anyone who just wants a status light on the desktop.
    public var clickDisabled: Bool {
        get { flag(Keys.clickDisabled, default: false) }
        set { defaults.set(newValue, forKey: Keys.clickDisabled.key) }
    }

    public var tokenPath: String {
        get {
            string(Keys.tokenPath)
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-status/token")
        }
        set { defaults.set(newValue, forKey: Keys.tokenPath.key) }
    }

    public var artPath: String {
        get {
            string(Keys.artPath)
                ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-status/pet.png")
        }
        set { defaults.set(newValue, forKey: Keys.artPath.key) }
    }

    public var debugLogging: Bool {
        get { flag(Keys.debugLogging, default: false) }
        set { defaults.set(newValue, forKey: Keys.debugLogging.key) }
    }

    /// Whether the pet follows a single session rather than collapsing all of
    /// them into one mood.
    ///
    /// The *mode* is what persists, not which session — session ids are minted
    /// afresh every time Claude Code starts, so an id saved yesterday names
    /// nothing today. The pet adopts whatever turns up.
    public var followOneSession: Bool {
        get { flag(Keys.followOneSession, default: false) }
        set { defaults.set(newValue, forKey: Keys.followOneSession.key) }
    }

    /// Whether each session gets its own thought-bubble colour. On by default:
    /// with one session it changes nothing, and with several it is the only
    /// thing saying which one is talking.
    public var colorCodedBubbles: Bool {
        get { flag(Keys.colorCodedBubbles, default: true) }
        set { defaults.set(newValue, forKey: Keys.colorCodedBubbles.key) }
    }

    /// A boolean with a default that may be true.
    ///
    /// `UserDefaults.bool(forKey:)` cannot express that — an unset key and a key
    /// set to false both come back false — so an unset key is read through
    /// `object(forKey:)` and only then falls back.
    private func flag(_ field: Field, default fallback: Bool) -> Bool {
        if let raw = override(field) { return raw == "1" || raw == "true" }
        guard defaults.object(forKey: field.key) != nil else { return fallback }
        return defaults.bool(forKey: field.key)
    }

    /// Accounts whose events the pet will show. Empty means "everyone", which is
    /// the right default on a machine only you use.
    public var allowedUsers: [String] {
        get { Self.parseUsers(string(Keys.allowedUsers) ?? "") }
        set {
            defaults.set(newValue.joined(separator: ", "), forKey: Keys.allowedUsers.key)
        }
    }

    /// Accepts commas, whitespace or newlines, so pasting from any of the three
    /// places this list has historically lived does the expected thing.
    ///
    /// Comments are stripped a line at a time, before anything is split. The
    /// `~/.claude-status/users` file this has to keep reading ships with two
    /// explanatory `#` lines at the top, and splitting the whole text on
    /// whitespace first would quietly enrol every word of them — "accounts",
    /// "always", "the" — as an account allowed to drive the pet.
    public static func parseUsers(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .components(separatedBy: .newlines)
            .map { line -> Substring in
                guard let hash = line.firstIndex(of: "#") else { return line[...] }
                return line[line.startIndex..<hash]
            }
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }) }
            .map { $0.lowercased() }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Launch at login

    /// Stored separately from the service registration so the Settings checkbox
    /// can show what you asked for even if registration is still pending.
    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    // MARK: - Migration

    /// Installs from before the Settings window kept the allowed accounts in
    /// `~/.claude-status/users`. Read it once, then leave it alone — the file
    /// stays on disk so a downgrade still works.
    private func migrateLegacyUsersFile() {
        guard defaults.object(forKey: Keys.allowedUsers.key) == nil else { return }

        let path = environment["CLAUDE_STATUS_USERS_FILE"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude-status/users")
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let names = Self.parseUsers(contents)
        guard !names.isEmpty else { return }
        defaults.set(names.joined(separator: ", "), forKey: Keys.allowedUsers.key)
    }
}
