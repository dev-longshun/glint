import SwiftUI

/// Fork: Settings → Agents card for Telegram remote confirm. Kept out of
/// SettingsView.swift so upstream merges only see the one-line mount.
struct TelegramConfirmCard: View {
    @ObservedObject private var bridge = TelegramBridge.shared
    @State private var tokenDraft = ""
    @State private var editingToken = false
    @State private var tokenRejected = false

    var body: some View {
        SettingsCard("Telegram remote confirm",
                     footer: "Use a dedicated bot made with @BotFather that no other app polls. The token stays in the macOS Keychain. Keys, passwords, emails and IP addresses are masked before a message leaves this Mac, and only the chat that sent /start can answer.") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send Claude's stops to Telegram")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text1)
                    Text(verbatim: statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusIsProblem ? Color.orange : Theme.text4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $bridge.enabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            SettingsDivider()
            tokenRow

            if bridge.hasToken {
                SettingsDivider()
                chatRow
            }

            SettingsDivider()
            SettingsRow("Only when I'm away",
                        subtitle: "Push only while Glint is in the background or the pane is off screen. Off: push every time Claude stops.") {
                Toggle("", isOn: $bridge.onlyWhenAway)
                    .toggleStyle(.switch).labelsHidden()
            }

            SettingsDivider()
            SettingsRow("Text typed by ✅",
                        subtitle: "Typed into the pane, then Return.") {
                TextField(TelegramBridge.defaultApproveText, text: $bridge.approveText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
        }
    }

    @ViewBuilder
    private var tokenRow: some View {
        if bridge.hasToken && !editingToken {
            SettingsRow("Bot token", subtitle: "Saved in the Keychain.") {
                HStack(spacing: 8) {
                    Button("Replace") {
                        tokenDraft = ""
                        tokenRejected = false
                        editingToken = true
                    }
                    Button("Remove") { bridge.removeToken() }
                }
            }
        } else {
            SettingsRow("Bot token",
                        subtitle: tokenRejected
                        ? "That doesn't look like a token from @BotFather (123456:ABC…)."
                        : "Paste the token @BotFather gave you.") {
                HStack(spacing: 8) {
                    SecureField("123456:ABC…", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(saveToken)
                    Button("Save", action: saveToken)
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingToken {
                        Button("Cancel") { editingToken = false }
                    }
                }
            }
        }
    }

    private var chatRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Linked chat")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text1)
                Text(verbatim: bridge.boundChatName
                     ?? String(localized: "Not linked — send /start to your bot in Telegram."))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text4)
            }
            Spacer(minLength: 12)
            if bridge.boundChatName != nil {
                HStack(spacing: 8) {
                    Button("Send test message") { bridge.sendTestMessage() }
                        .disabled(!bridge.canPush)
                    Button("Unlink") { bridge.unbind() }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func saveToken() {
        if bridge.saveToken(tokenDraft) {
            tokenDraft = ""
            tokenRejected = false
            editingToken = false
        } else {
            tokenRejected = true
        }
    }

    private var statusText: String {
        guard bridge.enabled else { return String(localized: "Off — nothing is sent.") }
        switch bridge.status {
        case .off:
            return bridge.hasToken
                ? String(localized: "Starting…")
                : String(localized: "Add a bot token below.")
        case .connecting:
            return String(localized: "Connecting to Telegram…")
        case .waitingForBinding(let bot):
            return String(localized: "Connected as \(bot). Send /start to it in Telegram to link your chat.")
        case .ready(let bot):
            return String(localized: "Ready — \(bot) pushes to \(bridge.boundChatName ?? "")")
        case .invalidToken:
            return String(localized: "Telegram rejected the token. Check it with @BotFather.")
        case .tokenUnavailable:
            return String(localized: "Couldn't read the token from the Keychain.")
        case .conflict:
            return String(localized: "Another program is polling this bot. Use a dedicated bot.")
        case .offline:
            return String(localized: "Can't reach Telegram — retrying.")
        }
    }

    private var statusIsProblem: Bool {
        guard bridge.enabled else { return false }
        switch bridge.status {
        case .invalidToken, .tokenUnavailable, .conflict, .offline: return true
        case .off, .connecting, .waitingForBinding, .ready: return false
        }
    }
}
