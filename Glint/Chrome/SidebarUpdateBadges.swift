import SwiftUI
import AppKit

/// Fork-maintenance pills beside "New Workspace" at the bottom of the sidebar:
/// a red-dot pill when a newer build of this fork is out (click → install
/// popover), and a merge pill counting the commits `chenbstack/glint` has that
/// we haven't merged (click → commit list). Each hides when there's nothing
/// to report, so the row stays clean.
struct SidebarUpdateBadges: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var updater: UpdaterController
    @EnvironmentObject var upstream: UpstreamTracker
    @State private var updateOpen = false
    @State private var upstreamOpen = false

    /// The 244pt sidebar can't fit "New Workspace" plus both pills with the
    /// version spelled out, so the update pill drops to a bare red dot while
    /// the upstream pill is showing (version stays in its tooltip / popover).
    private var showsUpstreamPill: Bool {
        upstream.enabled && upstream.newCommitCount > 0
    }

    var body: some View {
        HStack(spacing: 4) {
            if updater.showsUpdateBadge {
                BadgePill(help: updateHelp, isOpen: updateOpen, action: { updateOpen.toggle() }) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    if !showsUpstreamPill, let v = updater.availableVersion {
                        Text(verbatim: Self.shortVersion(v))
                    }
                }
                .popover(isPresented: $updateOpen, arrowEdge: .top) {
                    UpdatePopover()
                        .environmentObject(store)
                        .environmentObject(updater)
                        .environment(\.locale, store.preferredLocale)
                }
            }
            if showsUpstreamPill {
                BadgePill(help: upstreamCountText(upstream.newCommitCount),
                          isOpen: upstreamOpen, action: { upstreamOpen.toggle() }) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(verbatim: "\(upstream.newCommitCount)")
                }
                .popover(isPresented: $upstreamOpen, arrowEdge: .top) {
                    UpstreamPopover()
                        .environmentObject(store)
                        .environmentObject(upstream)
                        .environment(\.locale, store.preferredLocale)
                }
            }
        }
    }

    private var updateHelp: Text {
        if let v = updater.availableVersion { return Text("Update available: \(v)") }
        return Text("Update available")
    }

    /// `0.1.28-dev.15` → `dev.15` so the pill stays narrow; plain versions
    /// pass through.
    static func shortVersion(_ version: String) -> String {
        guard let r = version.range(of: "-dev.") else { return version }
        return "dev." + version[r.upperBound...]
    }
}

/// Localized "N new upstream commits" — singular / plural as separate keys.
private func upstreamCountText(_ count: Int) -> Text {
    count == 1 ? Text("1 new upstream commit") : Text("\(count) new upstream commits")
}

private struct BadgePill<Label: View>: View {
    let help: Text
    let isOpen: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { label() }
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(hovering || isOpen ? Theme.text1 : Theme.text2)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Capsule().fill(Theme.overlay(isOpen ? 0.12 : hovering ? 0.09 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Popovers

private struct UpdatePopover: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var updater: UpdaterController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                title
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
            }
            Text("Current version: \(UpdaterController.currentVersionString())")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)

            status

            switch updater.phase {
            case .readyToInstall:
                popoverButton("Quit & Install", prominent: true) {
                    updater.quitToFinishInstall()
                }
            case .available, .failed:
                popoverButton("Download & Install", prominent: true) {
                    updater.installAndRelaunch()
                }
            default:
                EmptyView()
            }
        }
        .padding(13)
        .frame(width: 280, alignment: .leading)
        .background(Theme.bgPane)
    }

    private var title: Text {
        if let v = updater.availableVersion { return Text("Update available: \(v)") }
        return Text("Update available")
    }

    @ViewBuilder
    private var status: some View {
        switch updater.phase {
        case .downloading:
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: updater.downloadProgress)
                    .progressViewStyle(.linear)
                Text(verbatim: updater.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(verbatim: updater.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
            }
        case .readyToInstall, .failed:
            Text(verbatim: updater.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(updater.phase == .failed ? Color.red.opacity(0.85) : Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private func popoverButton(_ title: LocalizedStringKey, prominent: Bool = false,
                               action: @escaping () -> Void) -> some View {
        PopoverActionButton(title: title, prominent: prominent, accent: store.accent, action: action)
    }
}

private struct UpstreamPopover: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var upstream: UpstreamTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(store.accent)
                upstreamCountText(upstream.newCommitCount)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
            }
            Text(verbatim: "\(UpstreamTracker.upstreamOwner)/\(UpstreamTracker.upstreamRepo) · \(UpstreamTracker.branch)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.text3)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(upstream.recentCommits) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: String(commit.sha.prefix(7)))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.text4)
                        Text(verbatim: commit.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(Text(verbatim: commit.title))
                        Spacer(minLength: 6)
                        if let date = commit.date {
                            Text(date, format: .relative(presentation: .named))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.text4)
                                .fixedSize()
                        }
                    }
                }
                if upstream.newCommitCount > upstream.recentCommits.count {
                    Text(verbatim: "…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text4)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.22)))

            HStack(spacing: 7) {
                PopoverActionButton(title: "View on GitHub", prominent: true, accent: store.accent) {
                    NSWorkspace.shared.open(upstream.compareURL)
                }
                PopoverActionButton(title: "Refresh", accent: store.accent) {
                    upstream.refresh()
                }
                .disabled(upstream.isChecking)
            }
            if let checked = upstream.lastCheckedAt {
                Text("Checked \(checked, format: .relative(presentation: .named))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text4)
            }
        }
        .padding(13)
        .frame(width: 380, alignment: .leading)
        .background(Theme.bgPane)
    }
}

/// Same look as the git status popover's buttons.
private struct PopoverActionButton: View {
    let title: LocalizedStringKey
    var prominent = false
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? accent : Theme.text2)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? accent.opacity(0.14) : Theme.overlay(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(prominent ? accent.opacity(0.30) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
