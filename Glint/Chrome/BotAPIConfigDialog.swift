import AppKit

/// Fork: right-click a bot → "API Settings…". Switches one Telegram channel
/// bot between this Mac's Claude subscription and a relay, and edits the
/// relay URL and key. Storage and restart live in `BotRegistry`; this file is
/// only the modal, kept apart so upstream merges see one menu line.
@MainActor
final class BotAPIConfigDialog: NSObject {

    /// Entry point from the sidebar context menu.
    static func present(startupCommand: String?) {
        guard let name = BotRegistry.botName(fromStartupCommand: startupCommand) else {
            info(String(localized: "This workspace isn't attached to a bot"),
                 String(localized: "Set its startup command to “~/.claude/channels/tgbots/glint-attach.sh <name>” first."))
            return
        }
        guard let bot = BotRegistry.endpoint(named: name) else {
            info(String(localized: "“\(name)” has no API settings"),
                 String(localized: "It isn't listed with a state folder in ~/.claude/channels/tgbots/bots.json, so it doesn't run Claude."))
            return
        }
        let original = BotRegistry.load(bot)
        var draft = original ?? BotAPIConfig(otherLines: BotAPIConfig.freshHeader)

        while true {
            let dialog = BotAPIConfigDialog(config: draft)
            guard let choice = dialog.run(bot: bot) else { return }
            draft = dialog.edited(from: draft)
            if draft.mode == .relay, let problem = Self.relayProblem(draft) {
                info(String(localized: "The relay needs a URL and a key"), problem)
                continue
            }
            do {
                if draft != original { try BotRegistry.save(draft, for: bot) }
            } catch {
                info(String(localized: "Couldn't save the API settings"), error.localizedDescription)
                return
            }
            guard choice == .saveAndRestart else { return }
            let notice = draft.usesRelay
                ? String(localized: "Switched to the relay. Continuing the same conversation.")
                : String(localized: "Switched to this Mac's Claude subscription. Continuing the same conversation.")
            if !BotRegistry.restart(bot, notice: notice) {
                info(String(localized: "Saved. The bot isn't running right now"),
                     String(localized: "The new settings apply the next time it starts."))
            }
            return
        }
    }

    private enum Choice { case saveAndRestart, save }

    private let modeControl: NSSegmentedControl
    private let urlField = NSTextField()
    private let secureKeyField = NSSecureTextField()
    private let plainKeyField = NSTextField()
    private let showKey: NSButton

    private init(config: BotAPIConfig) {
        modeControl = NSSegmentedControl(
            labels: [String(localized: "Claude Subscription"), String(localized: "Relay")],
            trackingMode: .selectOne, target: nil, action: nil)
        showKey = NSButton(checkboxWithTitle: String(localized: "Show Key"), target: nil, action: nil)
        super.init()
        modeControl.selectedSegment = config.mode == .relay ? 1 : 0
        for field in [urlField, secureKeyField, plainKeyField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.lineBreakMode = .byTruncatingMiddle
            field.cell?.usesSingleLineMode = true
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        urlField.stringValue = config.baseURL
        urlField.placeholderString = "https://"
        secureKeyField.stringValue = config.token
        plainKeyField.stringValue = config.token
        plainKeyField.isHidden = true
        showKey.target = self
        showKey.action = #selector(toggleShowKey)
    }

    @objc private func toggleShowKey() {
        let reveal = showKey.state == .on
        if reveal {
            plainKeyField.stringValue = secureKeyField.stringValue
        } else {
            secureKeyField.stringValue = plainKeyField.stringValue
        }
        plainKeyField.isHidden = !reveal
        secureKeyField.isHidden = reveal
    }

    private var keyValue: String {
        (showKey.state == .on ? plainKeyField : secureKeyField).stringValue
    }

    private func edited(from config: BotAPIConfig) -> BotAPIConfig {
        var next = config
        next.mode = modeControl.selectedSegment == 1 ? .relay : .subscription
        next.baseURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        next.token = keyValue.filter { !$0.isWhitespace }
        return next
    }

    private func run(bot: BotEndpoint) -> Choice? {
        let alert = NSAlert()
        alert.messageText = String(localized: "API Settings")
        let botLabel = bot.title.map { "\($0) (\(bot.name))" } ?? bot.name
        let path = (bot.apiEnvFile.path as NSString).abbreviatingWithTildeInPath
        alert.informativeText = String(localized: "Bot \(botLabel) · \(path)\n\nSave and Restart interrupts a reply in progress and continues the same conversation. Save alone takes effect at the next restart or /new. The relay URL and key are kept when you switch to the subscription.")
        alert.accessoryView = makeForm()
        alert.addButton(withTitle: String(localized: "Save and Restart"))
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = modeControl.selectedSegment == 1 ? urlField : modeControl
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .saveAndRestart
        case .alertSecondButtonReturn: return .save
        default: return nil
        }
    }

    private func makeForm() -> NSView {
        let keyStack = NSStackView(views: [secureKeyField, plainKeyField])
        keyStack.orientation = .vertical
        keyStack.detachesHiddenViews = true
        let grid = NSGridView(views: [
            [label(String(localized: "Use")), modeControl],
            [label(String(localized: "API URL")), urlField],
            [label(String(localized: "API Key")), keyStack],
            [NSGridCell.emptyContentView, showKey],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = true
        grid.layoutSubtreeIfNeeded()
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        return grid
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    /// nil when the draft is usable as a relay.
    private static func relayProblem(_ config: BotAPIConfig) -> String? {
        let url = config.baseURL.lowercased()
        if !(url.hasPrefix("https://") || url.hasPrefix("http://")) || URL(string: config.baseURL) == nil {
            return String(localized: "The URL must start with http:// or https://.")
        }
        if config.token.isEmpty {
            return String(localized: "Fill in the relay's API key, or choose Claude Subscription.")
        }
        return nil
    }

    private static func info(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
