import Foundation
import Security

// Fork: Telegram remote confirm — the Bot API side. Long-polls `getUpdates`
// on the user's own dedicated bot, binds the first private chat that sends
// /start, and ignores every other chat. What to push and how answers reach a
// pane is `ConfirmationRelay`'s job.
//
// Use a bot nothing else polls: two `getUpdates` consumers on one token
// knock each other off with 409 Conflict.

struct TelegramButton: Equatable {
    let text: String
    let data: String
}

/// Bot token in the login keychain, never in UserDefaults. The service is
/// derived from the bundle id so Debug (`app.glint.Glint.dev`) and release
/// builds never share a bot — they'd fight over `getUpdates`.
enum TelegramTokenStore {
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "app.glint.Glint") + ".telegram"
    }
    private static let account = "bot-token"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Attributes only: unlike reading the secret this never prompts, so the
    /// Settings UI can show "token saved" without touching it.
    static func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ token: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// "123456789:AA…" as issued by @BotFather. Also keeps the token safe to
    /// splice into the API URL path.
    static func isPlausible(_ token: String) -> Bool {
        token.range(of: #"^[0-9]{5,}:[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Bot API wire types

struct TelegramAPIError: Error {
    let status: Int
    let description: String?
    let retryAfter: Int?

    var isUnauthorized: Bool { status == 401 || status == 404 }
    var isConflict: Bool { status == 409 }
}

enum TelegramWire {
    struct Envelope<T: Decodable>: Decodable {
        struct Parameters: Decodable { let retryAfter: Int? }
        let ok: Bool
        let result: T?
        let description: String?
        let errorCode: Int?
        let parameters: Parameters?
    }

    /// For methods that return `true` or a message we don't need.
    struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    struct User: Decodable {
        let id: Int64
        let firstName: String?
        let username: String?
    }

    struct Chat: Decodable {
        let id: Int64
        let type: String
        let firstName: String?
        let username: String?
    }

    struct MessageRef: Decodable {
        let messageId: Int
    }

    struct Message: Decodable {
        let messageId: Int
        let date: Int
        let chat: Chat
        let from: User?
        let text: String?
        let replyToMessage: MessageRef?
    }

    struct CallbackMessage: Decodable {
        let messageId: Int
        let chat: Chat
    }

    struct CallbackQuery: Decodable {
        let id: String
        let from: User
        let message: CallbackMessage?
        let data: String?
    }

    struct Update: Decodable {
        let updateId: Int
        let message: Message?
        let callbackQuery: CallbackQuery?
    }
}

struct TelegramBotAPI {
    let token: String

    /// Ephemeral: message bodies never land in a disk cache.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 75
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:],
                            timeout: TimeInterval = 20) async throws -> T {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramAPIError(status: 401, description: nil, retryAfter: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? Self.decoder.decode(TelegramWire.Envelope<T>.self, from: data)
        if let envelope, envelope.ok, let result = envelope.result { return result }
        throw TelegramAPIError(status: envelope?.errorCode ?? status,
                               description: envelope?.description,
                               retryAfter: envelope?.parameters?.retryAfter)
    }
}

// MARK: - Bridge

@MainActor
final class TelegramBridge: ObservableObject {
    static let shared = TelegramBridge()

    enum Status: Equatable {
        case off
        case connecting
        case waitingForBinding(bot: String)
        case ready(bot: String)
        case invalidToken
        /// The keychain refused to hand the saved token back.
        case tokenUnavailable
        /// Another program is polling the same bot (HTTP 409).
        case conflict
        case offline
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var hasToken: Bool
    @Published private(set) var boundChatName: String?

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            restart()
        }
    }

    /// Push only when the user isn't looking at the pane (Glint in the
    /// background, or the pane off screen) — same rule as the chimes.
    @Published var onlyWhenAway: Bool {
        didSet { UserDefaults.standard.set(onlyWhenAway, forKey: Keys.onlyWhenAway) }
    }

    /// What "✅ Proceed" types. Empty means the localized default.
    @Published var approveText: String {
        didSet { UserDefaults.standard.set(approveText, forKey: Keys.approveText) }
    }

    var effectiveApproveText: String {
        let trimmed = approveText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultApproveText : trimmed
    }

    static var defaultApproveText: String { String(localized: "Proceed") }

    var canPush: Bool { enabled && api != nil && boundChatID != nil }

    weak var relay: ConfirmationRelay?

    private enum Keys {
        static let enabled = "glint.telegramConfirm.enabled"
        static let onlyWhenAway = "glint.telegramConfirm.onlyWhenAway"
        static let approveText = "glint.telegramConfirm.approveText"
        static let chatID = "glint.telegramConfirm.chatID"
        static let chatName = "glint.telegramConfirm.chatName"
    }

    private var api: TelegramBotAPI?
    private var boundChatID: Int64?
    private var botName: String?
    private var pollTask: Task<Void, Never>?
    private var offset = 0
    /// Messages older than this were queued while Glint wasn't listening.
    private var listeningSince = Date()

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        onlyWhenAway = (defaults.object(forKey: Keys.onlyWhenAway) as? Bool) ?? true
        approveText = defaults.string(forKey: Keys.approveText) ?? ""
        boundChatID = (defaults.object(forKey: Keys.chatID) as? NSNumber)?.int64Value
        boundChatName = defaults.string(forKey: Keys.chatName)
        hasToken = TelegramTokenStore.exists()
    }

    /// Called once at launch, after the relay is wired up.
    func start() {
        restart()
    }

    // MARK: settings actions

    /// False when the token doesn't look like a BotFather token or the
    /// keychain refused it.
    @discardableResult
    func saveToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TelegramTokenStore.isPlausible(token), TelegramTokenStore.write(token) else { return false }
        hasToken = true
        api = TelegramBotAPI(token: token)
        botName = nil
        offset = 0
        // A chat id is only reachable by a bot the user has /start-ed.
        unbind()
        restart()
        return true
    }

    func removeToken() {
        TelegramTokenStore.delete()
        hasToken = false
        api = nil
        botName = nil
        offset = 0
        unbind()
        restart()
    }

    func unbind() {
        boundChatID = nil
        boundChatName = nil
        UserDefaults.standard.removeObject(forKey: Keys.chatID)
        UserDefaults.standard.removeObject(forKey: Keys.chatName)
        refreshStatus()
    }

    func sendTestMessage() {
        post(String(localized: "Glint is connected. When Claude stops in a pane you're not watching, its last message shows up here."))
    }

    // MARK: sending (used by ConfirmationRelay)

    /// Returns the sent message's id, nil on failure. Plain text on purpose:
    /// Claude's Markdown would trip Telegram's entity parser.
    func send(_ text: String, keyboard: [[TelegramButton]]? = nil,
              forceReplyPlaceholder: String? = nil, replyTo: Int? = nil) async -> Int? {
        guard let api, let chat = boundChatID else { return nil }
        var params: [String: Any] = ["chat_id": chat, "text": text]
        if let keyboard {
            params["reply_markup"] = Self.inlineKeyboard(keyboard)
        } else if let forceReplyPlaceholder {
            params["reply_markup"] = ["force_reply": true,
                                      "input_field_placeholder": forceReplyPlaceholder]
        }
        if let replyTo {
            params["reply_parameters"] = ["message_id": replyTo, "allow_sending_without_reply": true]
        }
        do {
            let message: TelegramWire.Message = try await api.call("sendMessage", params)
            return message.messageId
        } catch {
            Self.log("sendMessage", error)
            return nil
        }
    }

    func post(_ text: String, replyTo: Int? = nil) {
        Task { _ = await send(text, replyTo: replyTo) }
    }

    /// Replace the text and drop the buttons.
    func edit(messageID: Int, text: String) {
        fire("editMessageText", ["message_id": messageID, "text": text,
                                 "reply_markup": Self.inlineKeyboard([])])
    }

    func clearKeyboard(messageID: Int) {
        fire("editMessageReplyMarkup", ["message_id": messageID,
                                        "reply_markup": Self.inlineKeyboard([])])
    }

    func answerCallback(id: String, text: String?) {
        var params: [String: Any] = ["callback_query_id": id]
        if let text { params["text"] = text }
        fire("answerCallbackQuery", params, needsChat: false)
    }

    func react(messageID: Int, emoji: String) {
        fire("setMessageReaction", ["message_id": messageID,
                                    "reaction": [["type": "emoji", "emoji": emoji]]])
    }

    private func fire(_ method: String, _ params: [String: Any], needsChat: Bool = true) {
        guard let api else { return }
        var params = params
        if needsChat {
            guard let chat = boundChatID else { return }
            params["chat_id"] = chat
        }
        Task {
            do {
                let _: TelegramWire.Ignored = try await api.call(method, params)
            } catch {
                Self.log(method, error)
            }
        }
    }

    private static func inlineKeyboard(_ rows: [[TelegramButton]]) -> [String: Any] {
        ["inline_keyboard": rows.map { row in
            row.map { ["text": $0.text, "callback_data": $0.data] }
        }]
    }

    /// Never log the error itself: a URLError carries the request URL, and
    /// the URL carries the bot token.
    private static func log(_ method: String, _ error: Error) {
        if let api = error as? TelegramAPIError {
            NSLog("[glint] telegram \(method) failed: HTTP \(api.status) \(api.description ?? "")")
        } else if let url = error as? URLError {
            NSLog("[glint] telegram \(method) failed: URLError \(url.code.rawValue)")
        } else {
            NSLog("[glint] telegram \(method) failed")
        }
    }

    // MARK: polling

    private func restart() {
        pollTask?.cancel()
        pollTask = nil
        guard enabled, hasToken else {
            status = .off
            return
        }
        if api == nil {
            guard let token = TelegramTokenStore.read() else {
                status = .tokenUnavailable
                return
            }
            api = TelegramBotAPI(token: token)
        }
        guard let api else { return }
        status = .connecting
        listeningSince = Date()
        pollTask = Task { [weak self] in await self?.run(api) }
    }

    private func run(_ api: TelegramBotAPI) async {
        var backoff: UInt64 = 2
        while !Task.isCancelled, botName == nil {
            do {
                let me: TelegramWire.User = try await api.call("getMe")
                botName = me.username.map { "@\($0)" } ?? me.firstName ?? "bot"
                refreshStatus()
            } catch {
                guard await handlePollError(error, backoff: &backoff) else { return }
            }
        }
        backoff = 2
        while !Task.isCancelled {
            do {
                let updates: [TelegramWire.Update] = try await api.call(
                    "getUpdates",
                    ["offset": offset, "timeout": 50, "allowed_updates": ["message", "callback_query"]],
                    timeout: 65)
                backoff = 2
                refreshStatus()
                for update in updates {
                    offset = max(offset, update.updateId + 1)
                    handle(update)
                }
            } catch {
                guard await handlePollError(error, backoff: &backoff) else { return }
            }
        }
    }

    /// Sleeps as appropriate; false means stop polling for good.
    private func handlePollError(_ error: Error, backoff: inout UInt64) async -> Bool {
        if Task.isCancelled { return false }
        var delay = backoff
        if let api = error as? TelegramAPIError {
            if api.isUnauthorized {
                status = .invalidToken
                return false
            }
            if api.isConflict {
                status = .conflict
                delay = 15
            } else if let retry = api.retryAfter {
                delay = UInt64(max(1, retry))
            } else {
                status = .offline
                backoff = min(backoff * 2, 60)
            }
        } else {
            status = .offline
            backoff = min(backoff * 2, 60)
        }
        Self.log("poll", error)
        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        return !Task.isCancelled
    }

    private func refreshStatus() {
        guard pollTask != nil, let botName else { return }
        status = boundChatID == nil ? .waitingForBinding(bot: botName) : .ready(bot: botName)
    }

    private func handle(_ update: TelegramWire.Update) {
        if let query = update.callbackQuery {
            guard let chat = boundChatID, query.from.id == chat,
                  let message = query.message, message.chat.id == chat else {
                answerCallback(id: query.id, text: nil)
                return
            }
            relay?.handleCallback(id: query.id, data: query.data ?? "", messageID: message.messageId)
            return
        }
        guard let message = update.message, let text = message.text else { return }
        let sent = Date(timeIntervalSince1970: TimeInterval(message.date))
        guard sent >= listeningSince.addingTimeInterval(-5) else { return }
        let isStart = text == "/start" || text.hasPrefix("/start ") || text.hasPrefix("/start@")
        guard let chat = boundChatID else {
            if isStart, message.chat.type == "private" { bind(message.chat) }
            return
        }
        guard message.chat.id == chat else { return }
        if isStart {
            post(String(localized: "This chat is already linked to Glint."))
            return
        }
        relay?.handleMessage(text: text, messageID: message.messageId,
                             replyTo: message.replyToMessage?.messageId)
    }

    private func bind(_ chat: TelegramWire.Chat) {
        boundChatID = chat.id
        boundChatName = chat.username.map { "@\($0)" } ?? chat.firstName ?? String(chat.id)
        UserDefaults.standard.set(NSNumber(value: chat.id), forKey: Keys.chatID)
        UserDefaults.standard.set(boundChatName, forKey: Keys.chatName)
        refreshStatus()
        post(String(localized: "Linked to Glint. Only this chat can answer for you from now on."))
    }
}
