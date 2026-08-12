import Foundation

/// The shared secret that separates your sessions from everyone else's.
///
/// The account name in an event is self-reported and therefore only a
/// convenience filter. This is the actual boundary: a request without a
/// matching token is refused before it becomes a session. On any host you share
/// with other people, this is the thing that matters.
public enum TokenStore {
    /// 128 bits of urandom, hex. Long enough that guessing is hopeless, short
    /// enough to paste, and drawn from a character set that survives being put
    /// in a curl config file and an SSH command line untouched.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes does not fail in practice. If it somehow does,
            // refusing is the only safe answer — a predictable token is worse
            // than none, because it looks like protection.
            fatalError("claude-status: no secure randomness available")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func read(at path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    /// Writes with mode 0600 from the outset.
    ///
    /// Created via `FileManager` attributes rather than by writing and then
    /// chmod-ing, so the secret is never briefly world-readable on disk.
    public static func write(_ token: String, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let data = Data((token + "\n").utf8)
        // Remove first: writing over an existing file keeps the old mode.
        try? FileManager.default.removeItem(atPath: path)
        guard FileManager.default.createFile(atPath: path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "StatusPet", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "could not write \(path)"
            ])
        }
    }

    /// Current mode, or nil if the file isn't there.
    public static func mode(at path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions]
            .flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// A token other accounts can read is not a secret. Returns a message if
    /// that's the case, having already fixed it — this is our own file in the
    /// user's home directory, and leaving a live secret world-readable while
    /// printing a suggestion would be the wrong trade. The fix is reported
    /// rather than done silently.
    @discardableResult
    public static func tightenIfNeeded(at path: String) -> String? {
        guard let mode = mode(at: path), mode & 0o077 != 0 else { return nil }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return "token file was mode \(String(mode, radix: 8)) — tightened to 600"
        } catch {
            return "token file is mode \(String(mode, radix: 8)) and readable by other accounts; "
                + "fix with: chmod 600 \(path)"
        }
    }
}
