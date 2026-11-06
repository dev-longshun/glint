import SwiftUI

/// Fork: Settings → Agents card for lid-closed running. Kept out of
/// SettingsView.swift so upstream merges only see the one-line mount.
struct LidAwakeCard: View {
    @ObservedObject private var lid = LidAwakeController.shared

    var body: some View {
        SettingsCard("Lid-closed running",
                     footer: "While it holds, closing the lid, the Apple menu and a short power-button press won't sleep the Mac. Don't leave it running in a closed bag.") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep agents running with the lid closed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text1)
                    Text(verbatim: lid.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(lid.statusIsProblem ? Color.orange : Theme.text4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let override = lid.overrideText {
                        Text(verbatim: override)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(get: { lid.enabled }, set: { lid.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(lid.authorizing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if lid.enabled {
                SettingsDivider()
                SettingsRow("Waiting for you",
                            subtitle: "Let the Mac sleep once an agent has waited this long for your answer.") {
                    GlintDropdown(selection: $lid.waitLimitSeconds,
                                  items: LidAwakeController.waitLimitChoices.map {
                                      (value: $0, label: durationLabel($0))
                                  },
                                  listWidth: 150)
                }
                SettingsDivider()
                SettingsRow("No progress",
                            subtitle: "Let the Mac sleep once a running agent shows no activity for this long.") {
                    GlintDropdown(selection: $lid.stallLimitSeconds,
                                  items: LidAwakeController.stallLimitChoices.map {
                                      (value: $0, label: durationLabel($0))
                                  },
                                  listWidth: 150)
                }
                SettingsDivider()
                SettingsRow("Lowest battery",
                            subtitle: "On battery, let the Mac sleep at this level.") {
                    GlintDropdown(selection: $lid.batteryFloorPercent,
                                  items: LidAwakeController.batteryFloorChoices.map {
                                      (value: $0, label: "\($0)%")
                                  },
                                  listWidth: 150)
                }
            }

            if lid.sudoersInstalled {
                SettingsDivider()
                SettingsRow("System approval",
                            subtitle: "Removes the rule that lets Glint switch the sleep setting. Asks for your password.") {
                    Button("Revoke") { lid.revokeAuthorization() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func durationLabel(_ seconds: Int) -> String {
        switch seconds {
        case 900: return String(localized: "15 minutes")
        case 1_800: return String(localized: "30 minutes")
        case 3_600: return String(localized: "1 hour")
        case 7_200: return String(localized: "2 hours")
        case 14_400: return String(localized: "4 hours")
        default: return "\(seconds / 60)"
        }
    }
}
