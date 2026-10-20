import Foundation

// Fork: Telegram remote confirm. When Claude ends a turn in a pane the user
// isn't watching, Glint pushes Claude's last message to the user's own
// Telegram bot. "✅ Proceed" types the approval text into that pane, a reply
// types the reply. Network and settings live in `TelegramBridge`; this file
// decides what is pushed and whether a tap still applies.

/// Outcome of typing a Telegram answer into a pane. Everything but
/// `.delivered` means the push is stale and nothing was typed.
enum ConfirmationDelivery: Equatable {
    case delivered
    /// Pane closed, or its surface is gone (hibernated / not minted yet).
    case paneGone
    /// The agent is working or waiting on something else.
    case busy
    /// Someone typed in the pane after the push: they're at the computer.
    case userActive
}

@MainActor
protocol ConfirmationHost: AnyObject {
    /// "Workspace · Tab" label for the push header; nil when the pane is gone.
    func confirmationTitle(forPane pane: String) -> String?
    /// Type `text` + Return into `pane`, unless the pane moved on since `pushedAt`.
    func deliverConfirmation(_ text: String, toPane pane: String, pushedAt: Date) -> ConfirmationDelivery
}

/// Which pushes are still answerable. Every hook event for a pane (except
/// the idle `Notification`) starts a new generation, and a push is only valid
/// for the generation it was sent in — so answering on the computer, a new
/// prompt, or any tool activity voids the phone's buttons. Telegram caps
/// callback_data at 64 bytes, so buttons carry a short token and the mapping
/// lives here, in memory: after a relaunch every old button is stale.
struct ConfirmationLedger {
    struct Push: Equatable {
        let token: String
        let pane: String
        let generation: Int
        let sentAt: Date
        /// The message text as sent; status edits append to it.
        let text: String
        /// The pushed message, plus the force-reply prompt once asked for.
        var messageIDs: [Int] = []
    }

    /// A push nobody answered for this long is dropped, so it stops holding
    /// the pane out of idle-agent hibernation.
    static let maxAge: TimeInterval = 12 * 3_600
    static let capacity = 64

    private(set) var generations: [String: Int] = [:]
    private(set) var pushes: [String: Push] = [:]

    /// Claude fires `Notification` on its own after idling at the prompt; it
    /// doesn't mean the turn moved on.
    static func startsNewGeneration(hook: String) -> Bool {
        hook != "Notification"
    }

    func generation(of pane: String) -> Int { generations[pane] ?? 0 }

    /// Record a hook event; returns the pushes it made stale (oldest first)
    /// so the caller can mark their messages expired.
    mutating func noteEvent(hook: String, pane: String) -> [Push] {
        guard Self.startsNewGeneration(hook: hook) else { return [] }
        generations[pane, default: 0] += 1
        let stale = pushes.values.filter { $0.pane == pane }.sorted { $0.sentAt < $1.sentAt }
        for push in stale { pushes.removeValue(forKey: push.token) }
        return stale
    }

    /// Register a push for the pane's current generation. Returns pushes
    /// evicted to stay within `capacity` (oldest first).
    @discardableResult
    mutating func register(token: String, pane: String, text: String, at date: Date) -> [Push] {
        pushes[token] = Push(token: token, pane: pane, generation: generation(of: pane),
                             sentAt: date, text: text)
        guard pushes.count > Self.capacity else { return [] }
        let evicted = pushes.values.sorted { $0.sentAt < $1.sentAt }.prefix(pushes.count - Self.capacity)
        for push in evicted { pushes.removeValue(forKey: push.token) }
        return Array(evicted)
    }

    /// Link a Telegram message to a push. False when the push went stale
    /// while the message was in flight.
    @discardableResult
    mutating func attach(messageID: Int, to token: String) -> Bool {
        guard pushes[token] != nil else { return false }
        pushes[token]?.messageIDs.append(messageID)
        return true
    }

    func live(token: String, now: Date) -> Push? {
        guard let push = pushes[token],
              push.generation == generation(of: push.pane),
              now.timeIntervalSince(push.sentAt) < Self.maxAge else { return nil }
        return push
    }

    func live(messageID: Int, now: Date) -> Push? {
        guard let push = pushes.values.first(where: { $0.messageIDs.contains(messageID) }) else { return nil }
        return live(token: push.token, now: now)
    }

    func hasLivePush(pane: String, now: Date) -> Bool {
        pushes.values.contains { $0.pane == pane && live(token: $0.token, now: now) != nil }
    }

    @discardableResult
    mutating func remove(_ token: String) -> Push? {
        pushes.removeValue(forKey: token)
    }
}

@MainActor
final class ConfirmationRelay {
    static let shared = ConfirmationRelay()

    weak var host: ConfirmationHost?
    private(set) var ledger = ConfirmationLedger()
    private let bridge: TelegramBridge

    private init() {
        bridge = .shared
    }

    enum CallbackAction: String {
        case approve = "a"
        case reply = "r"
    }

    // MARK: hook events

    /// Called for every hook event after the store updated pane state.
    /// `pane` is the "uuid:seq" handle the event resolved to.
    func agentEvent(hook: String, kind: PaneAgentKind, pane: String,
                    message: String?, userIsWatching: Bool) {
        for push in ledger.noteEvent(hook: hook, pane: pane) {
            markStale(push)
        }
        guard hook == "Stop", kind == .claude,
              bridge.canPush,
              !(bridge.onlyWhenAway && userIsWatching),
              let message,
              let title = host?.confirmationTitle(forPane: pane) else { return }
        let body = Self.redact(message, label: String(localized: "redacted"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        let text = Self.compose(header: title, body: body,
                                elidedMarker: String(localized: "… (earlier text omitted)"))
        let token = Self.makeToken()
        for push in ledger.register(token: token, pane: pane, text: text, at: Date()) {
            markStale(push)
        }
        // Proceed sits on the right, under the thumb.
        let keyboard = [[
            TelegramButton(text: String(localized: "✏️ Add details"),
                           data: Self.callbackData(.reply, token)),
            TelegramButton(text: String(localized: "✅ Proceed (as recommended)"),
                           data: Self.callbackData(.approve, token)),
        ]]
        Task { [weak self] in
            guard let self else { return }
            guard let id = await self.bridge.send(text, keyboard: keyboard) else {
                self.ledger.remove(token)
                return
            }
            if !self.ledger.attach(messageID: id, to: token) {
                // A new hook event landed while the message was in flight.
                self.bridge.edit(messageID: id,
                                 text: Self.appendingStatus(Self.expiredStatus, to: text))
            }
        }
    }

    /// Idle-agent hibernation would release the pane the phone is about to
    /// answer; WorkspaceStore skips panes with an answerable push.
    func hasLivePush(pane: String) -> Bool {
        ledger.hasLivePush(pane: pane, now: Date())
    }

    // MARK: Telegram input

    func handleCallback(id: String, data: String, messageID: Int) {
        let parsed = Self.parseCallback(data)
        guard let (action, token) = parsed,
              let push = ledger.live(token: token, now: Date()) else {
            bridge.answerCallback(id: id, text: String(localized: "Expired"))
            // Known but past maxAge → edit with its text; unknown (e.g. sent
            // before a relaunch) → we no longer have the text, drop the buttons.
            if let token = parsed?.token, let stale = ledger.remove(token) {
                markStale(stale)
            } else {
                bridge.clearKeyboard(messageID: messageID)
            }
            return
        }
        switch action {
        case .approve:
            let outcome = deliver(bridge.effectiveApproveText, for: push,
                                  status: String(localized: "✅ Proceeded"))
            bridge.answerCallback(id: id, text: outcome == .delivered
                                  ? String(localized: "Sent")
                                  : String(localized: "Expired"))
        case .reply:
            bridge.answerCallback(id: id, text: nil)
            let title = host?.confirmationTitle(forPane: push.pane) ?? ""
            let prompt = String(localized: "✏️ Reply to this message — your text is typed into \(title) as is.")
            Task { [weak self] in
                guard let self,
                      let promptID = await self.bridge.send(
                          prompt, forceReplyPlaceholder: String(localized: "Details for Claude"),
                          replyTo: messageID) else { return }
                self.ledger.attach(messageID: promptID, to: push.token)
            }
        }
    }

    /// A text message from the bound chat (commands already handled).
    func handleMessage(text: String, messageID: Int, replyTo: Int?) {
        guard let replyTo else {
            bridge.post(String(localized: "To answer Claude, swipe left on its message (or long-press → Reply) and send your text."),
                        replyTo: messageID)
            return
        }
        guard let push = ledger.live(messageID: replyTo, now: Date()) else {
            bridge.post(String(localized: "⌛ Expired — nothing was typed."), replyTo: messageID)
            return
        }
        if deliver(text, for: push, status: String(localized: "✏️ Details sent")) == .delivered {
            bridge.react(messageID: messageID, emoji: "👍")
        } else {
            bridge.post(String(localized: "⌛ Expired — nothing was typed."), replyTo: messageID)
        }
    }

    // MARK: helpers

    /// One answer per push: consumed whatever the host decides.
    private func deliver(_ text: String, for push: ConfirmationLedger.Push,
                         status: String) -> ConfirmationDelivery {
        ledger.remove(push.token)
        let outcome = host?.deliverConfirmation(text, toPane: push.pane, pushedAt: push.sentAt)
            ?? .paneGone
        let line: String
        switch outcome {
        case .delivered:
            line = "\(status) · \(Self.timeFormatter.string(from: Date()))"
        case .paneGone:
            line = String(localized: "⌛ Expired — the pane is closed or asleep")
        case .busy, .userActive:
            line = Self.expiredStatus
        }
        if let first = push.messageIDs.first {
            bridge.edit(messageID: first, text: Self.appendingStatus(line, to: push.text))
        }
        return outcome
    }

    private func markStale(_ push: ConfirmationLedger.Push) {
        guard let first = push.messageIDs.first else { return }
        bridge.edit(messageID: first, text: Self.appendingStatus(Self.expiredStatus, to: push.text))
    }

    private static var expiredStatus: String { String(localized: "⌛ Expired") }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    nonisolated static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }

    nonisolated static func callbackData(_ action: CallbackAction, _ token: String) -> String {
        "\(action.rawValue):\(token)"
    }

    nonisolated static func parseCallback(_ data: String) -> (action: CallbackAction, token: String)? {
        let parts = data.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let action = CallbackAction(rawValue: String(parts[0])),
              !parts[1].isEmpty else { return nil }
        return (action, String(parts[1]))
    }

    // MARK: text

    /// Telegram rejects messages over 4096 characters (UTF-16 units).
    nonisolated static let telegramLimit = 4_096
    /// Room kept for the status line an edit appends later.
    nonisolated static let statusReserve = 96

    /// Header, blank line, body. An over-long body keeps its END — that's
    /// where Claude asks what to do next.
    nonisolated static func compose(header: String, body: String, elidedMarker: String,
                        limit: Int = telegramLimit - statusReserve) -> String {
        let head = header + "\n\n"
        let budget = limit - head.utf16.count
        guard body.utf16.count > budget else { return head + body }
        let marker = elidedMarker + "\n"
        let room = max(0, budget - marker.utf16.count)
        var start = body.endIndex
        var used = 0
        while start > body.startIndex {
            let previous = body.index(before: start)
            let width = body[previous].utf16.count
            if used + width > room { break }
            used += width
            start = previous
        }
        return head + marker + String(body[start...])
    }

    nonisolated static func appendingStatus(_ status: String, to text: String) -> String {
        let joined = text + "\n\n" + status
        return joined.utf16.count <= telegramLimit ? joined : status
    }

    // MARK: redaction

    /// Generic secret patterns, applied before anything leaves the Mac.
    /// (kind, pattern, keep capture group 1 as a visible prefix)
    private nonisolated static let rules: [(String, NSRegularExpression, Bool)] = {
        // ASCII-only word edges: `\b` treats CJK as word characters, so a key
        // glued to Chinese text ("密钥是sk-…") would slip past it.
        let start = "(?<![A-Za-z0-9_])"
        let end = "(?![A-Za-z0-9_])"
        let specs: [(String, String, Bool)] = [
            ("private_key", "-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", false),
            // "account----password----recovery" credential dumps
            ("account_dump", "[^\\s`]*----[^\\s`]*(?:----[^\\s`]*)+", false),
            ("anthropic_key", "sk-ant-[A-Za-z0-9_\\-]{10,}", false),
            ("api_key", "\(start)(?:sk|rk|pk)-[A-Za-z0-9_\\-]{16,}", false),
            ("hex_secret", "\(start)[0-9a-fA-F]{48,}\(end)", false),
            ("github_token", "\(start)(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|\(start)github_pat_[A-Za-z0-9_]{20,}", false),
            ("slack_token", "\(start)xox[abpr]-[A-Za-z0-9\\-]{10,}", false),
            ("aws_key", "\(start)AKIA[0-9A-Z]{16}\(end)", false),
            ("jwt", "\(start)eyJ[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}\\.[A-Za-z0-9_\\-]{10,}", false),
            ("bearer", "(?i)(bearer\\s+)[A-Za-z0-9._\\-]{16,}", true),
            ("secret_assign", "(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|密码|口令|密钥)\\s*[:：=]\\s*[\"']?)[^\\s\"'，。,]{6,}", true),
            ("url_secret", "(?i)([?&](?:token|key|secret|sig|signature|access_token|auth)=)[^&\\s]{8,}", true),
            ("email", "\(start)[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}\(end)", false),
            ("phone", "(?<!\\d)1[3-9]\\d{9}(?!\\d)", false),
            ("ipv4", "\(start)(?:\\d{1,3}\\.){3}\\d{1,3}\(end)", false),
            // Mixed-case + digit runs: tokens with no recognizable prefix.
            ("long_secret", "[A-Za-z0-9+_\\-]{16,}={0,2}", false),
        ]
        return specs.map { kind, pattern, keep in
            // swiftlint:disable:next force_try
            (kind, try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]), keep)
        }
    }()

    nonisolated static func redact(_ text: String, label: String = "redacted") -> String {
        var out = text
        for (kind, regex, keepPrefix) in rules {
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = ""
            var cursor = 0
            for match in matches {
                let found = ns.substring(with: match.range)
                guard shouldRedact(kind: kind, match: found) else { continue }
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if keepPrefix, match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                    result += ns.substring(with: match.range(at: 1))
                }
                result += "[\(label):\(kind)]"
                cursor = match.range.location + match.range.length
            }
            result += ns.substring(from: cursor)
            out = result
        }
        return out
    }

    private nonisolated static func shouldRedact(kind: String, match: String) -> Bool {
        switch kind {
        case "account_dump":
            // Markdown table rules ("|-----|-----|") have no letters or digits.
            return match.contains { $0.isLetter || $0.isNumber }
        case "long_secret":
            return match.contains { $0.isLowercase }
                && match.contains { $0.isUppercase }
                && match.contains { $0.isNumber }
                && !match.hasPrefix("toolu_")
        default:
            return true
        }
    }
}

/// The two host methods live in WorkspaceStore.swift: they need its private
/// surface registry.
extension WorkspaceStore: ConfirmationHost {}
