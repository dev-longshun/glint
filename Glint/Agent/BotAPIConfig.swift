import Foundation

/// Fork: which API a Telegram channel bot's Claude Code talks to.
///
/// The bots run in tmux, outside Glint (`~/.claude/channels/tgbots`). Each
/// bot's state directory holds an `api.env` that the launch loop
/// (`api-env.sh`) re-reads before every Claude start. Glint only edits that
/// file and kicks the loop, so the bots keep their settings when Glint is
/// closed, e.g. after `start-all.sh` brings them up at login.
enum BotAPIMode: String {
    /// The Mac's own Claude login (subscription); no API env is exported.
    case subscription
    /// `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` from the file.
    case relay
}

/// Parsed `api.env`. Only the three keys below belong to Glint; every other
/// line (comments, `ANTHROPIC_MODEL`, …) is kept verbatim. URL and token stay
/// in the file while the bot is on the subscription, so switching back to
/// the relay needs no re-typing.
struct BotAPIConfig: Equatable {
    static let modeKey = "GLINT_API_MODE"
    static let urlKey = "ANTHROPIC_BASE_URL"
    static let tokenKey = "ANTHROPIC_AUTH_TOKEN"

    /// Header written into a file Glint creates from scratch. The script
    /// skips `#` lines, so this is for anyone opening the file by hand.
    static let freshHeader = [
        "# Bot API settings, edited from Glint (right-click the bot → API Settings…) or by hand.",
        "# GLINT_API_MODE=relay uses the URL and token below; subscription uses this Mac's Claude login and keeps them unused.",
    ]

    var mode: BotAPIMode = .subscription
    var baseURL = ""
    var token = ""
    var otherLines: [String] = []

    init(mode: BotAPIMode = .subscription, baseURL: String = "", token: String = "",
         otherLines: [String] = []) {
        self.mode = mode
        self.baseURL = baseURL
        self.token = token
        self.otherLines = otherLines
    }

    /// Mirrors `api-env.sh`: `#` lines and lines without `=` are not
    /// settings, the key is everything before the first `=` (whitespace
    /// dropped), the value everything after it.
    init(parsing text: String) {
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].filter { !$0.isWhitespace }
                let value = String(line[line.index(after: eq)...])
                switch key {
                case Self.modeKey:
                    mode = BotAPIMode(rawValue: value.trimmingCharacters(in: .whitespaces)) ?? .subscription
                    continue
                case Self.urlKey:
                    baseURL = value
                    continue
                case Self.tokenKey:
                    token = value
                    continue
                default:
                    break
                }
            }
            otherLines.append(line)
        }
        while otherLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            otherLines.removeLast()
        }
    }

    /// What the launch loop will actually do with this file: the relay only
    /// takes effect with both a URL and a token, otherwise it falls back to
    /// the subscription.
    var usesRelay: Bool { mode == .relay && !baseURL.isEmpty && !token.isEmpty }

    /// Leading comments stay on top, then Glint's three keys, then the rest.
    func serialized() -> String {
        let leading = otherLines.prefix { $0.hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let rest = otherLines.dropFirst(leading.count)
        let owned = ["\(Self.modeKey)=\(mode.rawValue)",
                     "\(Self.urlKey)=\(baseURL)",
                     "\(Self.tokenKey)=\(token)"]
        return (Array(leading) + owned + Array(rest)).joined(separator: "\n") + "\n"
    }
}

/// One bot from `tgbots/bots.json`.
struct BotEndpoint: Equatable {
    let name: String
    let title: String?
    let stateDirectory: URL

    var apiEnvFile: URL { stateDirectory.appendingPathComponent("api.env") }

    /// `--settings` path the launch loop passes to Claude, used to find that
    /// one process (same lookup as the bots' own `restart.sh`).
    var sessionSettingsFile: URL {
        let direct = stateDirectory.appendingPathComponent("session-settings.json")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return stateDirectory.appendingPathComponent("bin/session-settings.json")
    }
}

enum BotRegistry {
    static var tgbotsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/channels/tgbots")
    }

    /// `~/.claude/channels/tgbots/glint-attach.sh ledger` → `ledger`. That
    /// startup command is how a bot workspace is tied to its tmux session.
    static func botName(fromStartupCommand command: String?) -> String? {
        guard let command else { return nil }
        let words = command.split(whereSeparator: \.isWhitespace)
        guard let i = words.firstIndex(where: { $0.hasSuffix("glint-attach.sh") }),
              words.indices.contains(i + 1) else { return nil }
        return String(words[i + 1])
    }

    /// Bots that run Claude have a `state` directory in `bots.json`; the
    /// timer doesn't, so it resolves to nil.
    static func endpoint(named name: String, botsJSON data: Data,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> BotEndpoint? {
        guard let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = all[name] as? [String: Any],
              let state = entry["state"] as? String, !state.isEmpty else { return nil }
        let path: String
        if state == "~" {
            path = home.path
        } else if state.hasPrefix("~/") {
            path = home.appendingPathComponent(String(state.dropFirst(2))).path
        } else {
            path = state
        }
        return BotEndpoint(name: name, title: entry["title"] as? String,
                           stateDirectory: URL(fileURLWithPath: path, isDirectory: true))
    }

    static func endpoint(named name: String) -> BotEndpoint? {
        guard let data = try? Data(contentsOf: tgbotsDirectory.appendingPathComponent("bots.json")) else {
            return nil
        }
        return endpoint(named: name, botsJSON: data)
    }

    static func load(_ bot: BotEndpoint) -> BotAPIConfig? {
        guard let text = try? String(contentsOf: bot.apiEnvFile, encoding: .utf8) else { return nil }
        return BotAPIConfig(parsing: text)
    }

    /// Writes owner-only from the first byte (the token must never sit in a
    /// world-readable file, even briefly), then swaps it in atomically.
    static func save(_ config: BotAPIConfig, for bot: BotEndpoint) throws {
        let fm = FileManager.default
        let target = bot.apiEnvFile
        let temp = bot.stateDirectory.appendingPathComponent(".api.env.\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: Data(config.serialized().utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Restart the bot's Claude so it picks up `api.env`, staying in the
    /// same conversation. Same handshake as the bots' `/new`: `restart.flag`
    /// tells the launch loop to start Claude again; `restart.continue` (the
    /// Telegram notice) makes that start resume with `--continue`. Returns
    /// false when this bot's Claude isn't running — the marker files are
    /// removed again so a later `/new` still opens a fresh conversation.
    @discardableResult
    static func restart(_ bot: BotEndpoint, notice: String) -> Bool {
        let flag = bot.stateDirectory.appendingPathComponent("restart.flag")
        let resume = bot.stateDirectory.appendingPathComponent("restart.continue")
        try? Data(notice.utf8).write(to: resume)
        FileManager.default.createFile(atPath: flag.path, contents: Data())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-TERM", "-f", claudeProcessPattern(for: bot)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var matched = false
        if (try? process.run()) != nil {
            process.waitUntilExit()
            matched = process.terminationStatus == 0
        }
        if !matched {
            try? FileManager.default.removeItem(at: resume)
            try? FileManager.default.removeItem(at: flag)
        }
        return matched
    }

    /// POSIX ERE for `pkill -f`. Escapes only ERE metacharacters:
    /// `NSRegularExpression.escapedPattern` also escapes `/`, and a backslash
    /// before an ordinary character is undefined in ERE.
    static func claudeProcessPattern(for bot: BotEndpoint) -> String {
        let special: Set<Character> = [".", "[", "]", "(", ")", "*", "+", "?", "{", "}", "|", "^", "$", "\\"]
        let path = bot.sessionSettingsFile.path.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
        return "^claude .*--settings \(path) "
    }
}
