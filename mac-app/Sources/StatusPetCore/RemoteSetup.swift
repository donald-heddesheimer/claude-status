import Foundation

/// Runs a subprocess and waits, with a deadline.
enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        /// True when the process was still running at the deadline.
        let timedOut: Bool
    }

    /// `stdin` is written and closed before reading, which is what lets the SSH
    /// helpers ship a whole script down the pipe instead of trying to quote one
    /// through a remote shell.
    static func run(_ path: String, _ arguments: [String],
                    stdin: String? = nil, timeout: TimeInterval = 30) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        // A passphrase prompt from a subprocess with no terminal hangs until the
        // deadline. Tell SSH not to ask; the wizard explains the agent instead.
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment

        do {
            try process.run()
        } catch {
            return Result(status: -1, out: "", err: error.localizedDescription, timedOut: false)
        }

        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()

        // Read on background queues: a child that fills a 64 KB pipe buffer
        // while we wait on `waitUntilExit` deadlocks with both sides blocked.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(outPipe, { outData = $0 }), (errPipe, { errData = $0 })] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        return Result(
            status: process.terminationStatus,
            out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut)
    }
}

/// One `Host` entry from `~/.ssh/config`.
public struct SSHHost: Equatable {
    public let alias: String
    public let hostName: String?
    public let user: String?
    /// A `RemoteForward` for our port already applies to this host — either in
    /// its own block or inherited from a wildcard.
    public let hasForward: Bool
}

/// Reading and editing `~/.ssh/config`.
///
/// Kept as pure string transforms so the wizard can preview exactly what it is
/// about to write. Silently rewriting someone's SSH config is a bad way to make
/// friends; showing them the diff first is a good one.
public enum SSHConfig {
    public static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    /// Splits an ssh_config line into keyword and argument. The real grammar
    /// allows `Key value`, `Key=value` and any mix of surrounding whitespace.
    static func keyword(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        let separators = CharacterSet(charactersIn: " \t=")
        guard let split = trimmed.rangeOfCharacter(from: separators) else { return nil }
        let key = String(trimmed[trimmed.startIndex..<split.lowerBound]).lowercased()
        let value = String(trimmed[split.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        return (key, value)
    }

    public static func parse(_ text: String, port: UInt16) -> [SSHHost] {
        struct Block {
            var aliases: [String]
            var hostName: String?
            var user: String?
            var forwards = false
        }

        var blocks: [Block] = []
        // Everything before the first Host line applies globally, as does a
        // `Host *` block — a RemoteForward in either already covers every alias.
        var globalForward = false

        for line in text.components(separatedBy: .newlines) {
            guard let (key, value) = keyword(line) else { continue }

            switch key {
            case "host":
                blocks.append(Block(aliases: value.split(whereSeparator: \.isWhitespace).map(String.init)))
            case "hostname":
                if !blocks.isEmpty { blocks[blocks.count - 1].hostName = value }
            case "user":
                if !blocks.isEmpty { blocks[blocks.count - 1].user = value }
            case "remoteforward":
                // "RemoteForward 7777 127.0.0.1:7777" — only the first field
                // says which port is bound on the remote side.
                let bound = value.split(whereSeparator: \.isWhitespace).first.map(String.init)
                guard bound == String(port) else { continue }
                if blocks.isEmpty {
                    globalForward = true
                } else if blocks[blocks.count - 1].aliases.contains("*") {
                    globalForward = true
                } else {
                    blocks[blocks.count - 1].forwards = true
                }
            default:
                continue
            }
        }

        return blocks.compactMap { block in
            // Wildcards configure other hosts rather than being one you connect
            // to, so they don't belong in a "pick your host" list.
            guard let alias = block.aliases.first,
                  !block.aliases.contains(where: { $0.contains("*") || $0.contains("?") })
            else { return nil }
            return SSHHost(alias: alias, hostName: block.hostName, user: block.user,
                           hasForward: block.forwards || globalForward)
        }
    }

    public static func load(port: UInt16) -> [SSHHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text, port: port)
    }

    public static func forwardLine(port: UInt16) -> String {
        "    RemoteForward \(port) 127.0.0.1:\(port)"
    }

    /// Returns the config text with a `RemoteForward` added for `alias`.
    ///
    /// If the alias already has a block, the line goes inside it, immediately
    /// after the `Host` line — appending a second `Host alias` block would work
    /// but leaves a config nobody wants to read later. Otherwise a new block is
    /// appended at the end.
    public static func adding(alias: String, port: UInt16, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            guard let (key, value) = keyword(line), key == "host" else { continue }
            let aliases = value.split(whereSeparator: \.isWhitespace).map(String.init)
            guard aliases.contains(alias) else { continue }
            lines.insert(forwardLine(port: port), at: index + 1)
            return lines.joined(separator: "\n")
        }

        var appended = text
        if !appended.isEmpty, !appended.hasSuffix("\n") { appended += "\n" }
        appended += "\nHost \(alias)\n\(forwardLine(port: port))\n"
        return appended
    }

    /// Writes the config, keeping a timestamped backup. Returns the backup path.
    @discardableResult
    public static func write(_ text: String) throws -> String? {
        let manager = FileManager.default
        var backup: String?

        if manager.fileExists(atPath: path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
            let target = "\(path).claude-status-backup-\(stamp)"
            try? manager.copyItem(atPath: path, toPath: target)
            backup = target
        } else {
            try manager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        try text.write(toFile: path, atomically: true, encoding: .utf8)
        // ssh refuses to use a config other users can write.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return backup
    }
}

/// Runs the checks the old `setup-remote.sh` printed instructions for, and turns
/// the result into something that says what to do next.
public enum RemoteProbe {
    public struct Outcome {
        public let ok: Bool
        public let headline: String
        public let detail: String
    }

    /// Sends the token to the remote host over SSH stdin, never as an argument.
    ///
    /// Process command lines are world-readable on a shared Linux box — the
    /// exact hazard the token exists to defend against — so putting a secret in
    /// `ssh host "echo ..."` would publish it to every account there on its way
    /// to protecting it.
    public static func installToken(_ token: String, on alias: String) -> Outcome {
        // Tokens are hex from `TokenStore.generate`, so there is nothing here
        // that a quoted heredoc could misinterpret. Guarded anyway: this is the
        // one place a hand-edited token file reaches a remote shell.
        guard token.allSatisfy({ $0.isHexDigit }), !token.isEmpty else {
            return Outcome(ok: false, headline: "Token has unexpected characters",
                           detail: "Generate a new one in Settings ▸ Security rather than "
                                 + "sending this to a remote shell.")
        }

        let script = """
        set -e
        umask 077
        mkdir -p "$HOME/.claude-status"
        cat > "$HOME/.claude-status/token" <<'CLAUDE_STATUS_TOKEN'
        \(token)
        CLAUDE_STATUS_TOKEN
        chmod 600 "$HOME/.claude-status/token"
        echo installed
        """

        let result = ssh(alias, script: script, timeout: 25)
        if result.timedOut {
            return Outcome(ok: false, headline: "Timed out connecting to \(alias)",
                           detail: agentHint)
        }
        guard result.status == 0, result.out.contains("installed") else {
            return Outcome(ok: false, headline: "Could not write the token on \(alias)",
                           detail: sshFailure(result))
        }
        return Outcome(ok: true, headline: "Token installed on \(alias)",
                       detail: "~/.claude-status/token, mode 600.")
    }

    /// Posts a real event from the remote host through the tunnel.
    public static func test(alias: String, port: UInt16) -> Outcome {
        // Built on the far side exactly the way the hook builds it — config on
        // stdin, so the token never lands in the remote process table.
        let script = """
        command -v curl >/dev/null 2>&1 || { echo NOCURL; exit 0; }
        TOKEN=""
        if [ -r "$HOME/.claude-status/token" ]; then
          TOKEN="$(head -n 1 "$HOME/.claude-status/token" 2>/dev/null | tr -d '\\r\\n')"
        fi
        {
          printf 'url = "http://127.0.0.1:%s/state"\\n' "\(port)"
          printf 'header = "Content-Type: application/json"\\n'
          [ -n "$TOKEN" ] && printf 'header = "X-Petdex-Update-Token: %s"\\n' "$TOKEN"
          printf 'data = "{\\\\"state\\\\":\\\\"idle\\\\",\\\\"session_id\\\\":\\\\"tunnel-test\\\\",\\\\"user\\\\":\\\\"$(id -un)\\\\",\\\\"host\\\\":\\\\"$(hostname -s)\\\\",\\\\"remote\\\\":true,\\\\"agent_source\\\\":\\\\"claude-code\\\\"}"\\n'
        } | curl -K - -s -o /dev/null -w 'HTTP %{http_code}\\n' -m 5
        """

        let result = ssh(alias, script: script, timeout: 30)

        if result.timedOut {
            return Outcome(ok: false, headline: "Timed out connecting to \(alias)", detail: agentHint)
        }
        if result.status == 255 {
            return Outcome(ok: false, headline: "SSH could not connect to \(alias)",
                           detail: sshFailure(result))
        }
        if result.out.contains("NOCURL") {
            return Outcome(ok: false, headline: "No curl on \(alias)",
                           detail: "The hook needs curl on the remote host. Install it there.")
        }

        let code = result.out.components(separatedBy: "HTTP ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch code {
        case "200":
            return Outcome(ok: true, headline: "Tunnel works",
                           detail: "\(alias) reached the pet and the event was accepted.")
        case "000":
            return Outcome(ok: false, headline: "Nothing is listening on \(alias):\(port)",
                           detail: """
                           The RemoteForward isn't active on that connection. \
                           RemoteForward only applies to new connections, so reconnect \
                           any existing session to \(alias) and try again. If it still \
                           fails, another process on \(alias) may already hold port \
                           \(port) — SSH declines to bind it and logs "remote port \
                           forwarding failed".
                           """)
        case "401":
            return Outcome(ok: false, headline: "Token mismatch",
                           detail: "The pet refused the event. Use “Install token on host” "
                                 + "to copy this Mac's token to \(alias).")
        case "404", "405":
            return Outcome(ok: false, headline: "Something else is on port \(port)",
                           detail: "The tunnel reached a server on this Mac, but not the pet. "
                                 + "Check for another app on \(port), or change the port in "
                                 + "Settings ▸ General.")
        case "415":
            return Outcome(ok: false, headline: "Request rejected",
                           detail: "The pet refused the content type — this is a bug; "
                                 + "please report it.")
        default:
            return Outcome(ok: false, headline: code.isEmpty ? "No response" : "Unexpected HTTP \(code)",
                           detail: sshFailure(result))
        }
    }

    private static func ssh(_ alias: String, script: String, timeout: TimeInterval) -> Shell.Result {
        Shell.run("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=accept-new",
            alias, "bash", "-s"
        ], stdin: script, timeout: timeout)
    }

    private static let agentHint = """
    SSH was told not to prompt, so a key with a passphrase has to be loaded in \
    your agent first: run `ssh-add` in a terminal, then try again.
    """

    private static func sshFailure(_ result: Shell.Result) -> String {
        let stderr = result.err.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
            .prefix(4)
            .joined(separator: "\n")
        return stderr.isEmpty ? "ssh exited \(result.status)." : stderr
    }
}
