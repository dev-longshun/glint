import SwiftUI
import AppKit
import ImageIO

struct SidebarView: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    /// UUID of the workspace card currently mid-drag. Set by the dragged
    /// card's preview onAppear and cleared on the preview's onDisappear,
    /// so every sibling can render its insertion indicator relative to it.
    @State private var draggingWorkspaceID: UUID?
    /// Traffic lights vanish in full screen, so the reserved strip above
    /// the search field must vanish with them (same fix as ToolbarHeader's
    /// 78pt gutter).
    @State private var isFullscreen = false

    var body: some View {
        VStack(spacing: 0) {
            // top spacer for traffic-light area (NSWindow draws them automatically here)
            Color.clear.frame(height: isFullscreen ? 8 : 38)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.willEnterFullScreenNotification)) { _ in
                    isFullscreen = true
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSWindow.willExitFullScreenNotification)) { _ in
                    isFullscreen = false
                }

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onChange(of: store.sidebarSearchFocusTick) { _, _ in
                    searchFocused = true
                }

            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader("Workspaces", count: filteredWorkspaces.count)
                    VStack(spacing: 6) {
                        ForEach(filteredWorkspaces) { ws in
                            WorkspaceCard(ws: ws, draggingID: $draggingWorkspaceID)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .animation(.spring(response: 0.32, dampingFraction: 0.85),
                               value: filteredWorkspaces.map(\.id))
                }
                .padding(.bottom, 12)
            }
            .scrollContentBackground(.hidden)

            newWorkspaceCard
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
        }
    }

    private var filteredWorkspaces: [Workspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base: [Workspace]
        if query.isEmpty {
            base = store.workspaces
        } else {
            base = store.workspaces.filter { ws in
                ws.displayName.lowercased().contains(query)
                    || ws.name.lowercased().contains(query)
            }
        }
        guard store.sortCompletedFirst else { return base }
        // Stable partition: `.justCompleted` first, preserving the user's
        // drag-assigned order within each group. Using enumerated() +
        // offset as the tiebreaker keeps the sort deterministic regardless
        // of `sorted(by:)` stability guarantees.
        return base.enumerated().sorted { lhs, rhs in
            let lhsDone = store.agentSummary(for: lhs.element)?.status == .justCompleted
            let rhsDone = store.agentSummary(for: rhs.element)?.status == .justCompleted
            if lhsDone != rhsDone { return lhsDone }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var newWorkspaceCard: some View {
        Button {
            store.addWorkspace()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    )
                Text("New Workspace")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text4)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    searchText = ""
                    searchFocused = false
                    return .handled
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(searchFocused ? 0.08 : 0.04))
        )
        // Make the entire pill hit-testable so clicking anywhere (the
        // magnifying glass, the empty padding, the trailing ⌘K tag) hands
        // focus to the TextField. Without contentShape SwiftUI only routes
        // hits that land directly on the TextField's text baseline.
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .textCase(.uppercase)
                .font(.glintSection)
                .kerning(0.8)
                .foregroundStyle(Theme.text4)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text4)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

}

private struct WorkspaceCard: View {
    @EnvironmentObject var store: WorkspaceStore
    /// System "Reduce Motion" — when on, the looping decorations (border
    /// comet, pulsing dots/borders, mascot GIF) render as static states.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ws: Workspace
    @Binding var draggingID: UUID?

    @State private var isEditing = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool
    /// Timestamp of the last reorder this card was the *target* of. Used
    /// to swallow the spring-animation sweep: after we swap, the target
    /// card slides under the cursor again mid-animation and SwiftUI re-
    /// fires `isTargeted`, which would bounce the dragged card back. A
    /// short cooldown matched to the spring response kills the oscillation
    /// without affecting genuine user-intent swaps onto a different card.
    @State private var lastTargetedAt: Date = .distantPast
    /// Hover affordance — drives the 1pt scale + soft shadow that makes
    /// cards feel "liftable" without being a heavy hover state. Driven
    /// by `.onHover`; doesn't touch ghostty.
    @State private var isHovered: Bool = false
    /// One-shot opacity for the green glow that flashes when an agent's
    /// `.justCompleted` arrives. 1 → 0 over ~0.7s, then idle. Re-armed
    /// only on a fresh transition into `.justCompleted`, so a re-render
    /// while the status is sticky doesn't re-fire.
    @State private var justCompletedFlash: Double = 0
    var body: some View {
        let active = store.selectedWorkspaceID == ws.id
        let summary = store.agentSummary(for: ws)
        let status = summary?.status
        HStack(alignment: .center, spacing: 10) {
            // Purely decorative for VoiceOver — the icon (incl. mascot GIF
            // and status dot) repeats what label/value below already say.
            workspaceIcon(active: active, status: status)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(Theme.text1)
                        .focused($nameFieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                        .onAppear {
                            // When editing, start with the underlying user name
                            // (not the auto-derived display name).
                            draftName = ws.userNamed ? ws.name : ""
                            DispatchQueue.main.async { nameFieldFocused = true }
                        }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused && isEditing { commitRename() }
                        }
                } else {
                    Text(ws.displayName)
                        .font(.system(size: 13, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Theme.text1 : Theme.text2)
                        .italic(!ws.userNamed)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                secondaryRow(summary: summary, active: active)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(cardBackground(active: active))
        // Border/flash/pulse overlays are decorative — hide from VoiceOver
        // so the combined element doesn't pick up phantom children.
        .overlay(cardBorder(active: active, status: status).accessibilityHidden(true))
        .overlay(completionFlashOverlay.accessibilityHidden(true))
        .overlay(permissionPulseOverlay(status: status).accessibilityHidden(true))
        .scaleEffect(isHovered ? 1.005 : 1.0, anchor: .center)
        .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0),
                radius: isHovered ? 6 : 0,
                y: isHovered ? 2 : 0)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering && !isEditing
        }
        .onChange(of: status) { oldStatus, newStatus in
            // One-shot green flash on transition into .justCompleted.
            // Guard against re-rendering while the status is sticky —
            // we only want the flash on the actual edge.
            if newStatus == .justCompleted && oldStatus != .justCompleted {
                justCompletedFlash = 1
                withAnimation(.easeOut(duration: 0.7)) {
                    justCompletedFlash = 0
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Single-tap only — double-tap-to-rename used to live here but
            // forced SwiftUI to wait the system double-click window before
            // committing the single tap, making workspace switching feel
            // sluggish. Rename now goes through the right-click menu.
            if !isEditing { store.selectWorkspace(ws.id) }
        }
        .contextMenu {
            Button("Rename") { startEditing() }
            Button("New Workspace") { store.addWorkspace() }
            Divider()
            Button("Delete Workspace", role: .destructive) {
                store.deleteWorkspace(ws.id)
            }
        }
        // VoiceOver: the card is one tappable button. Name = workspace
        // name (verbatim — user data); value = the same status line the
        // card renders visually, with the elapsed time spelled out.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: ws.displayName))
        .accessibilityValue(Text(verbatim: accessibilityStatus(summary: summary)))
        .draggable(ws.id.uuidString) {
            // The preview view's lifecycle is the cleanest drag-lifecycle
            // signal SwiftUI exposes for `.draggable` — onAppear when the
            // drag session starts, onDisappear when it ends (drop OR
            // cancel). We use it to drive `draggingID` so sibling cards
            // can render their insert indicator and fade the source.
            dragPreview
                .onAppear { draggingID = ws.id }
                .onDisappear {
                    if draggingID == ws.id { draggingID = nil }
                }
        }
        .dropDestination(for: String.self) { items, _ in
            // The actual reorder already happened while hovering — see the
            // `isTargeted` branch below. Returning true just confirms the
            // drop so SwiftUI doesn't snap the preview back.
            guard let raw = items.first,
                  let sourceID = UUID(uuidString: raw),
                  sourceID != ws.id
            else { return false }
            return true
        } isTargeted: { targeted in
            // Real-time reorder: as soon as the cursor enters another card,
            // slide the dragged workspace into that slot. The ForEach's
            // spring animation handles the visual rearrangement.
            guard targeted,
                  let draggingID,
                  draggingID != ws.id,
                  let targetIdx = store.workspaces.firstIndex(where: { $0.id == ws.id })
            else { return }
            // Spring-sweep guard: after we swap, this same card animates
            // back under the cursor and `isTargeted` re-fires, which would
            // bounce the row back. Spring response is 0.32s; 0.35s
            // covers settling without blocking the user from dragging
            // onto a *different* card (each card has its own timestamp).
            let now = Date()
            if now.timeIntervalSince(lastTargetedAt) < 0.35 { return }
            lastTargetedAt = now
            store.moveWorkspace(id: draggingID, to: targetIdx)
        }
    }

    /// Invisible drag preview — we only need the view's lifecycle hooks to
    /// drive `draggingID`. The row reorders live under the cursor, so a
    /// floating ghost above the cursor just adds visual noise.
    private var dragPreview: some View {
        Color.clear.frame(width: 1, height: 1)
    }

    private func startEditing() {
        draftName = ws.userNamed ? ws.name : ""
        isEditing = true
    }

    private func commitRename() {
        store.renameWorkspace(ws.id, to: draftName)
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }

    private func workspaceIcon(active: Bool, status: PaneAgentStatus?) -> some View {
        let kind = store.iconKind(for: ws)
        let isClaude: Bool = {
            if case .claude = kind { return true }
            return false
        }()
        let isCodex: Bool = {
            if case .codex = kind { return true }
            return false
        }()
        // Claude's gif mascot and Codex's official gradient mark both ship
        // their own colors — render them bare, no accent squircle behind.
        let bare = isClaude || isCodex
        return Group {
            if isClaude {
                ClaudeMascotIcon(status: status)
            } else if isCodex {
                Image("CodexMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else if let sf = kind.sfSymbol {
                Image(systemName: sf)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(kind.letter)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 28, height: 28)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(bare ? Color.clear : ws.accent)
                if active && !bare {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
        )
        .overlay(alignment: .bottomTrailing) {
            AgentStatusDot(status: status)
                .offset(x: 3, y: 3)
        }
        .shadow(
            color: active
                ? (isClaude
                    ? Color(red: 0.92, green: 0.55, blue: 0.32).opacity(0.5)
                    : isCodex
                        ? Color(red: 0.32, green: 0.38, blue: 1.0).opacity(0.5)
                        : ws.accent.opacity(0.5))
                : .clear,
            radius: 8
        )
    }

    @ViewBuilder
    private func secondaryRow(summary: (status: PaneAgentStatus, since: Date)?, active: Bool) -> some View {
        // Wrap the two branches in a single Group keyed off the row's
        // logical identity so SwiftUI treats a status flip as a view
        // replacement and the `.transition(.opacity)` actually fires.
        // Without the `.id(...)`, SwiftUI sees the same Text view with
        // changed text and snaps without crossfading.
        let key = secondaryRowKey(summary?.status)
        Group {
            if let summary, summary.status != .idle {
                HStack(spacing: 4) {
                    Text(statusText(summary.status))
                        .foregroundStyle(statusTextColor(summary.status))
                        .fontWeight(.medium)
                    if showsTimer(summary.status) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("· \(elapsedString(since: summary.since, now: ctx.date))")
                                .foregroundStyle(active ? Theme.text3 : Theme.text4)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            } else {
                Text(cwdLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(active ? Theme.text3 : Theme.text4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .id(key)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.18), value: key)
    }

    /// Stable identity for the secondary row — bucket `idle` and `nil`
    /// together (both render the cwd line), and each real status keeps
    /// its own key so transitions between e.g. thinking → tool also
    /// crossfade rather than snapping mid-word.
    private func secondaryRowKey(_ s: PaneAgentStatus?) -> String {
        switch s {
        case .none, .some(.idle):       return "cwd"
        case .some(.thinking):          return "thinking"
        case .some(.tool):              return "tool"
        case .some(.needsPermission):   return "permission"
        case .some(.compacting):        return "compacting"
        case .some(.justCompleted):     return "done"
        }
    }

    private func showsTimer(_ s: PaneAgentStatus) -> Bool {
        switch s {
        case .thinking, .tool, .compacting, .needsPermission: return true
        case .justCompleted, .idle:                           return false
        }
    }

    /// Compact mm:ss for the first hour, then h:mm. Most turns end inside a
    /// minute so we want second-precision early; long-running tools care
    /// about the gross magnitude, not seconds.
    private func elapsedString(since start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        if total < 3600 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h\(m)m"
    }

    /// Card surface fill — extracted so the body's modifier chain stays
    /// inside SwiftUI's type-inference budget. Three states: selected,
    /// hovered, idle; transitions are animated via the bound `value:`
    /// keys so they don't fight with the unrelated reorder spring on
    /// the parent VStack.
    private func cardBackground(active: Bool) -> some View {
        let fill: Color = {
            if active { return Color.white.opacity(0.09) }
            if isHovered { return Color.white.opacity(0.055) }
            return Color.white.opacity(0.03)
        }()
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: active)
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    /// One-shot green halo overlay that fades from full to clear over
    /// ~0.7s when `justCompletedFlash` is non-zero. Decoupled from the
    /// regular static border so the celebration doesn't fight with the
    /// border color crossfade.
    private var completionFlashOverlay: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(
                Color(red: 0.40, green: 0.90, blue: 0.55),
                lineWidth: 2
            )
            .blur(radius: 4)
            .opacity(justCompletedFlash)
            .allowsHitTesting(false)
    }

    /// While the agent is `.needsPermission`, render a soft amber border
    /// that breathes between 0.25 and 0.85 alpha on a 1.2s cycle. The
    /// breathing is a Core Animation opacity loop on the render server —
    /// a SwiftUI `repeatForever` here re-renders the card every frame on
    /// the main thread (see CardBorderTraveler).
    @ViewBuilder
    private func permissionPulseOverlay(status: PaneAgentStatus?) -> some View {
        if status == .needsPermission {
            BreathingBorder(
                color: NSColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1.0),
                cornerRadius: 9,
                lineWidth: 1.5,
                // Reduce Motion: hold the border at full strength instead
                // of breathing — still unmistakably "needs attention".
                animates: !reduceMotion
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func cardBorder(active: Bool, status: PaneAgentStatus?) -> some View {
        // Reduce Motion: skip the orbiting comet and fall through to the
        // static status-colored border, which carries the same information.
        if let status, isWorking(status), !reduceMotion {
            // Active turn: the comet replaces the static colored border and
            // makes it obvious from across the sidebar that something's
            // running. Compaction uses dual comets to look distinct.
            CardBorderTraveler(
                color: borderTravelerColor(status),
                cornerRadius: 9,
                dual: status == .compacting
            )
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    cardBorderColor(active: active, status: status),
                    lineWidth: cardBorderWidth(status: status)
                )
        }
    }

    private func isWorking(_ s: PaneAgentStatus) -> Bool {
        s == .thinking || s == .tool || s == .compacting
    }

    private func borderTravelerColor(_ s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool: return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .compacting:      return Color(red: 0.43, green: 0.72, blue: 0.86)
        default:               return Color.white.opacity(0.2)
        }
    }

    private var cwdLine: String {
        let n = ws.panes.count
        let unit = String(localized: n == 1 ? "pane" : "panes")
        let focused = ws.panes[ws.focusedPane]?.workingDirectory
        let firstCwd = ws.panes.values.compactMap(\.workingDirectory).first
        let cwd = focused ?? firstCwd
        let shortCwd = cwd.map(prettyCwd) ?? String(localized: "no cwd")
        return "\(n) \(unit) · \(shortCwd)"
    }

    /// Spoken description for VoiceOver: the agent-status text the card
    /// already renders, plus a spelled-out elapsed time ("1 minute, 24
    /// seconds") when the visual row shows a timer. Idle cards read the
    /// same pane-count/cwd line they display.
    private func accessibilityStatus(summary: (status: PaneAgentStatus, since: Date)?) -> String {
        guard let summary, summary.status != .idle else { return cwdLine }
        var parts = [plainStatusText(summary.status)]
        if showsTimer(summary.status),
           let spoken = Self.spokenDurationFormatter.string(
               from: max(0, Date().timeIntervalSince(summary.since))) {
            parts.append(spoken)
        }
        return parts.joined(separator: ", ")
    }

    /// Plain-String twin of `statusText` — accessibilityValue needs a
    /// String, not a LocalizedStringKey.
    private func plainStatusText(_ s: PaneAgentStatus) -> String {
        switch s {
        case .thinking:        return String(localized: "thinking…")
        case .tool:            return String(localized: "running tool")
        case .needsPermission: return String(localized: "needs approval")
        case .compacting:      return String(localized: "compacting…")
        case .justCompleted:   return String(localized: "done")
        case .idle:            return ""
        }
    }

    private static let spokenDurationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .full
        return f
    }()

    private func statusText(_ s: PaneAgentStatus) -> LocalizedStringKey {
        switch s {
        case .thinking:        return LocalizedStringKey("thinking…")
        case .tool:            return LocalizedStringKey("running tool")
        case .needsPermission: return LocalizedStringKey("needs approval")
        case .compacting:      return LocalizedStringKey("compacting…")
        case .justCompleted:   return LocalizedStringKey("✓ done")
        case .idle:            return LocalizedStringKey("")
        }
    }

    private func statusTextColor(_ s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool:  return Color(red: 0.72, green: 0.68, blue: 1.0)
        case .needsPermission:  return Color(red: 1.0, green: 0.45, blue: 0.42)
        case .compacting:       return Color(red: 0.43, green: 0.72, blue: 0.86)
        case .justCompleted:    return Color(red: 0.40, green: 0.86, blue: 0.55)
        case .idle:             return Theme.text4
        }
    }

    private func cardBorderColor(active: Bool, status: PaneAgentStatus?) -> Color {
        if let status, status != .idle {
            switch status {
            case .needsPermission:  return Color(red: 1.0, green: 0.32, blue: 0.29).opacity(0.85)
            case .justCompleted:    return Color(red: 0.30, green: 0.82, blue: 0.50).opacity(0.85)
            case .thinking, .tool:  return Color(red: 0.55, green: 0.50, blue: 0.95).opacity(0.55)
            case .compacting:       return Color(red: 0.35, green: 0.66, blue: 0.82).opacity(0.6)
            case .idle:             break
            }
        }
        return active ? ws.accent.opacity(0.45) : Color.white.opacity(0.04)
    }

    private func cardBorderWidth(status: PaneAgentStatus?) -> CGFloat {
        switch status {
        case .needsPermission, .justCompleted: return 1.5
        default:                                return 1
        }
    }

    private func prettyCwd(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Official Claude mark, bundled as an asset (`Claude.imageset`). Clipped
/// to the same squircle as the other workspace icons so it sits flush in
/// the sidebar row.
/// Animated Claude mascot driven by per-status GIFs (idle / thinking /
/// tool-call / working). The GIF carries the bulk of the motion; we
/// keep two extra interaction beats on top:
///   • Celebrate bounce — one-shot spring scale pop on the transition
///     into `.justCompleted`, pairs with the card's green halo flash.
///   • Tap squish — scale dip + spring rebound when the icon is clicked.
private struct ClaudeMascotIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: PaneAgentStatus?
    @State private var celebrateScale: CGFloat = 1.0
    @State private var tapScale: CGFloat = 1.0

    var body: some View {
        // Reduce Motion: freeze the GIF on its first frame — the mascot
        // stays as the workspace icon, just without the looping animation.
        AnimatedGIFView(assetName: gifAssetName(for: status), animates: !reduceMotion)
            // The 128×128 gif canvas pads the robot with transparent
            // margin (room for the bounce/confetti frames), so render
            // bigger than the 28pt layout slot to keep the robot itself
            // at icon size; the background is transparent so no clip.
            .frame(width: 40, height: 40)
            .frame(width: 28, height: 28)
            .scaleEffect(celebrateScale * tapScale, anchor: .bottom)
            .onChange(of: status) { oldStatus, newStatus in
                if newStatus == .justCompleted && oldStatus != .justCompleted {
                    celebrateScale = 1.22
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                        celebrateScale = 1.0
                    }
                }
            }
            .onTapGesture {
                tapScale = 0.85
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) {
                    tapScale = 1.0
                }
            }
    }

    /// Map the agent's status to the right Data Set in Assets.xcassets.
    /// Idle covers the "nothing's happening" cases (including the post-
    /// turn justCompleted window — the card already flashes green and
    /// the celebrate scale pops, the gif staying idle keeps the moment
    /// readable).
    private func gifAssetName(for s: PaneAgentStatus?) -> String {
        switch s {
        case .none, .some(.idle), .some(.needsPermission), .some(.justCompleted):
            return "ClaudeIdle"
        case .some(.thinking):
            return "ClaudeThinking"
        case .some(.tool):
            return "ClaudeToolCall"
        case .some(.compacting):
            return "ClaudeCompressing"
        }
    }
}

/// SwiftUI host for an animated GIF from Assets.xcassets (Data Set).
///
/// Playback deliberately does NOT use `NSImageView.animates`: that path
/// re-decodes the GIF on the main thread for every animation tick (ImageIO
/// shows up hot in samples) and dirties layout/display each frame — with a
/// few mascots looping, that alone held the whole app at ~15-20% CPU.
/// Instead each asset is decoded ONCE (cached for the app's lifetime, the
/// bitmaps are 128×128 so this is a few hundred KB) and played back by a
/// repeating `CAKeyframeAnimation` on the layer's `contents`, which runs
/// entirely in the render server — zero per-frame work in this process.
private struct AnimatedGIFView: NSViewRepresentable {
    let assetName: String
    /// false (Reduce Motion) shows the GIF's first frame statically.
    var animates: Bool = true

    func makeNSView(context: Context) -> GIFLayerView {
        let view = GIFLayerView()
        view.apply(assetName: assetName, animates: animates)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GIFLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 28, height: 28))
    }

    func updateNSView(_ view: GIFLayerView, context: Context) {
        view.apply(assetName: assetName, animates: animates)
    }

    final class GIFLayerView: NSView {
        private static let animationKey = "glint.gif.contents"
        private var currentAsset: String?
        private var currentlyAnimating = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.minificationFilter = .trilinear
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        func apply(assetName: String, animates: Bool) {
            // No-op on SwiftUI's frequent re-renders with unchanged inputs,
            // so the loop isn't restarted mid-cycle every second.
            guard assetName != currentAsset || animates != currentlyAnimating else { return }
            currentAsset = assetName
            currentlyAnimating = animates
            applyToLayer()
        }

        /// Layer-backed views can be handed a fresh layer when re-parented
        /// or moved between windows, dropping our animation — re-apply.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyToLayer()
        }

        private func applyToLayer() {
            guard let layer, let asset = currentAsset,
                  let gif = GIFFrameCache.shared.gif(named: asset) else { return }
            layer.removeAnimation(forKey: Self.animationKey)
            layer.contents = gif.frames.first
            guard currentlyAnimating, gif.frames.count > 1 else { return }
            let anim = CAKeyframeAnimation(keyPath: "contents")
            anim.calculationMode = .discrete
            anim.values = gif.frames
            anim.keyTimes = gif.keyTimes
            anim.duration = gif.duration
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: Self.animationKey)
        }
    }
}

/// Decodes each GIF asset exactly once per app run. Main-thread only
/// (always reached via SwiftUI view updates).
private final class GIFFrameCache {
    static let shared = GIFFrameCache()

    struct DecodedGIF {
        let frames: [CGImage]
        /// `.discrete` keyframe timing: frames.count + 1 entries in 0…1;
        /// frame i is visible from keyTimes[i] to keyTimes[i+1].
        let keyTimes: [NSNumber]
        let duration: Double
    }

    private var cache: [String: DecodedGIF] = [:]

    func gif(named assetName: String) -> DecodedGIF? {
        if let hit = cache[assetName] { return hit }
        guard let data = NSDataAsset(name: assetName)?.data,
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(src) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(img)
            delays.append(Self.frameDelay(src, i))
        }
        guard !frames.isEmpty else { return nil }
        let duration = max(delays.reduce(0, +), 0.01)
        var acc = 0.0
        var keyTimes: [NSNumber] = [0]
        for d in delays {
            acc += d
            keyTimes.append(NSNumber(value: acc / duration))
        }
        let gif = DecodedGIF(frames: frames, keyTimes: keyTimes, duration: duration)
        cache[assetName] = gif
        return gif
    }

    private static func frameDelay(_ src: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
        let clamped = gifProps[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        // Browsers clamp tiny delays to ~100ms; honor the unclamped value
        // when present but never spin faster than 50fps.
        return max(unclamped > 0 ? unclamped : clamped, 0.02)
    }
}

/// Tiny circle in the squircle's corner reflecting the agent's mood:
///   thinking/tool → pulsing purple
///   waiting       → amber
///   needsPerm     → red
///   idle / nil    → invisible
private struct AgentStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: PaneAgentStatus?

    var body: some View {
        Group {
            if let status, status != .idle {
                ZStack {
                    // The scale/opacity pulse runs as a Core Animation loop
                    // on the render server — a SwiftUI `repeatForever` here
                    // re-renders every frame on the main thread (see
                    // CardBorderTraveler).
                    PulsingDot(
                        color: NSColor(color(for: status)),
                        pulsing: needsPulse(status)
                    )
                    if status == .justCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 10, height: 10)
            }
        }
    }

    private func color(for s: PaneAgentStatus) -> Color {
        switch s {
        case .thinking, .tool:  return Color(red: 0.55, green: 0.50, blue: 0.95)
        case .needsPermission:  return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .compacting:       return Color(red: 0.35, green: 0.66, blue: 0.82)
        case .justCompleted:    return Color(red: 0.30, green: 0.78, blue: 0.46)
        case .idle:             return .clear
        }
    }

    private func needsPulse(_ s: PaneAgentStatus) -> Bool {
        // Reduce Motion: render the dot steady at full opacity — the
        // color alone carries the status.
        guard !reduceMotion else { return false }
        return s == .thinking || s == .tool || s == .needsPermission || s == .compacting
    }
}

/// A comet of accent color orbits the workspace card border to indicate
/// indeterminate progress. Compaction passes `dual: true` so two opposing
/// spots travel together — visually distinct from a normal thinking turn.
///
/// The sweep is a `CABasicAnimation` rotating a conic `CAGradientLayer`
/// masked by the border stroke, so it plays entirely on the render
/// server. A SwiftUI `repeatForever` rotation here is NOT offloaded to
/// Core Animation: the view graph re-resolves the display list every
/// frame on the main thread (~15% CPU with one spinner), starving the
/// main thread ghostty needs for frame presentation and tick processing.
private struct CardBorderTraveler: NSViewRepresentable {
    let color: Color
    let cornerRadius: CGFloat
    let dual: Bool

    func makeNSView(context: Context) -> CometLayerView {
        let view = CometLayerView()
        view.apply(color: NSColor(color), cornerRadius: cornerRadius, dual: dual)
        return view
    }

    func updateNSView(_ view: CometLayerView, context: Context) {
        view.apply(color: NSColor(color), cornerRadius: cornerRadius, dual: dual)
    }

    final class CometLayerView: NSView {
        private static let spinKey = "glint.comet.spin"
        private let gradientLayer = CAGradientLayer()
        private var color: NSColor = .clear
        private var cornerRadius: CGFloat = 9
        private var dual = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            gradientLayer.type = .conic
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
            gradientLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        /// The overlay spans the whole card; never swallow its clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(color: NSColor, cornerRadius: CGFloat, dual: Bool) {
            guard color != self.color || cornerRadius != self.cornerRadius
                || dual != self.dual else { return }
            self.color = color
            self.cornerRadius = cornerRadius
            self.dual = dual
            configureLayers()
        }

        /// Layer-backed views can be handed a fresh layer when re-parented
        /// or moved between windows, dropping sublayers/animations.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureLayers()
        }

        override func layout() {
            super.layout()
            configureLayers()
        }

        private func configureLayers() {
            guard let layer, bounds.width > 1, bounds.height > 1 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if gradientLayer.superlayer !== layer {
                layer.addSublayer(gradientLayer)
            }
            gradientLayer.colors = stops.map(\.0.cgColor)
            gradientLayer.locations = stops.map { NSNumber(value: $0.1) }
            // Square side = card diagonal, so the rotating gradient covers
            // every corner of the mask at any angle.
            let side = (bounds.width * bounds.width
                + bounds.height * bounds.height).squareRoot()
            gradientLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradientLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
            mask.frame = bounds
            mask.path = strokeBorderPath(in: bounds, cornerRadius: cornerRadius,
                                         lineWidth: 1.2)
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = 1.2
            layer.mask = mask
            CATransaction.commit()
            ensureSpin()
        }

        private func ensureSpin() {
            let duration: CFTimeInterval = dual ? 1.4 : 2.0
            if let existing = gradientLayer.animation(forKey: Self.spinKey),
               existing.duration == duration { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            // Negative = clockwise on screen (macOS layers are y-up).
            spin.toValue = -2 * Double.pi
            spin.duration = duration
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            gradientLayer.add(spin, forKey: Self.spinKey)
        }

        private var stops: [(NSColor, Double)] {
            if dual {
                return [
                    (color.withAlphaComponent(0.20), 0.00),
                    (color.withAlphaComponent(0.95), 0.10),
                    (color.withAlphaComponent(0.20), 0.30),
                    (color.withAlphaComponent(0.20), 0.55),
                    (color.withAlphaComponent(0.95), 0.72),
                    (color.withAlphaComponent(0.20), 0.88),
                    (color.withAlphaComponent(0.20), 1.00),
                ]
            }
            return [
                (color.withAlphaComponent(0.18), 0.00),
                (color.withAlphaComponent(0.18), 0.55),
                (color.withAlphaComponent(0.95), 0.72),
                (color.withAlphaComponent(0.18), 0.88),
                (color.withAlphaComponent(0.18), 1.00),
            ]
        }
    }
}

/// The agent-status dot circle, with its working-state pulse running as a
/// Core Animation scale/opacity loop on the render server.
private struct PulsingDot: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool

    func makeNSView(context: Context) -> DotLayerView {
        let view = DotLayerView()
        view.apply(color: color, pulsing: pulsing)
        return view
    }

    func updateNSView(_ view: DotLayerView, context: Context) {
        view.apply(color: color, pulsing: pulsing)
    }

    final class DotLayerView: NSView {
        private static let pulseKey = "glint.dot.pulse"
        private let dot = CALayer()
        private var color: NSColor = .clear
        private var pulsing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            dot.borderWidth = 1
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(color: NSColor, pulsing: Bool) {
            guard color != self.color || pulsing != self.pulsing else { return }
            self.color = color
            self.pulsing = pulsing
            configureLayers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureLayers()
        }

        override func layout() {
            super.layout()
            configureLayers()
        }

        private func configureLayers() {
            guard let layer, bounds.width > 1, bounds.height > 1 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if dot.superlayer !== layer {
                layer.addSublayer(dot)
            }
            let side = min(bounds.width, bounds.height)
            dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
            dot.cornerRadius = side / 2
            dot.backgroundColor = color.cgColor
            dot.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
            CATransaction.commit()
            if pulsing {
                guard dot.animation(forKey: Self.pulseKey) == nil else { return }
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1.0
                scale.toValue = 1.18
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1.0
                fade.toValue = 0.75
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = 0.9
                group.autoreverses = true
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.isRemovedOnCompletion = false
                dot.add(group, forKey: Self.pulseKey)
            } else {
                dot.removeAnimation(forKey: Self.pulseKey)
            }
        }
    }
}

/// Amber "needs permission" border, breathing via a Core Animation
/// opacity loop on the render server. `animates: false` (Reduce Motion)
/// holds it steady at full strength.
private struct BreathingBorder: NSViewRepresentable {
    let color: NSColor
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let animates: Bool

    func makeNSView(context: Context) -> BorderLayerView {
        let view = BorderLayerView()
        view.apply(color: color, cornerRadius: cornerRadius,
                   lineWidth: lineWidth, animates: animates)
        return view
    }

    func updateNSView(_ view: BorderLayerView, context: Context) {
        view.apply(color: color, cornerRadius: cornerRadius,
                   lineWidth: lineWidth, animates: animates)
    }

    final class BorderLayerView: NSView {
        private static let breatheKey = "glint.permission.breathe"
        private let border = CAShapeLayer()
        private var color: NSColor = .clear
        private var cornerRadius: CGFloat = 9
        private var lineWidth: CGFloat = 1.5
        private var animates = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            border.fillColor = nil
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(color: NSColor, cornerRadius: CGFloat,
                   lineWidth: CGFloat, animates: Bool) {
            guard color != self.color || cornerRadius != self.cornerRadius
                || lineWidth != self.lineWidth || animates != self.animates
            else { return }
            self.color = color
            self.cornerRadius = cornerRadius
            self.lineWidth = lineWidth
            self.animates = animates
            configureLayers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureLayers()
        }

        override func layout() {
            super.layout()
            configureLayers()
        }

        private func configureLayers() {
            guard let layer, bounds.width > 1, bounds.height > 1 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if border.superlayer !== layer {
                layer.addSublayer(border)
            }
            border.frame = bounds
            border.path = strokeBorderPath(in: bounds, cornerRadius: cornerRadius,
                                           lineWidth: lineWidth)
            border.strokeColor = color.cgColor
            border.lineWidth = lineWidth
            border.opacity = 0.85
            CATransaction.commit()
            if animates {
                guard border.animation(forKey: Self.breatheKey) == nil else { return }
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.85
                breathe.toValue = 0.25
                breathe.duration = 1.2
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                breathe.isRemovedOnCompletion = false
                border.add(breathe, forKey: Self.breatheKey)
            } else {
                border.removeAnimation(forKey: Self.breatheKey)
            }
        }
    }
}

/// Path for a stroke that hugs the inside of `rect` (the CAShapeLayer
/// equivalent of SwiftUI's `strokeBorder`): inset by half the line width
/// so the stroke's outer edge lands exactly on the rect's edge.
private func strokeBorderPath(in rect: CGRect, cornerRadius: CGFloat,
                              lineWidth: CGFloat) -> CGPath {
    let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let radius = max(cornerRadius - lineWidth / 2, 0)
    return CGPath(roundedRect: inset, cornerWidth: radius,
                  cornerHeight: radius, transform: nil)
}
