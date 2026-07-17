import AppKit
import SwiftUI

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var updater = UpdaterController()
    @StateObject private var usage = UsageStore()
    @StateObject private var codexHomes = CodexHomeStore()
    @StateObject private var shortcuts = ShortcutStore()

    init() {
        #if DEBUG
        // Dev builds run under their own defaults domain (app.glint.Glint.dev).
        // The first dev launch copies the production app's glint.* preferences
        // so it starts where production left off; after that the two domains
        // diverge independently. Must run before the language read below.
        if !UserDefaults.standard.bool(forKey: "glint.devDefaultsSeeded"),
           let prod = UserDefaults.standard.persistentDomain(forName: "app.glint.Glint") {
            for (key, value) in prod where key.hasPrefix("glint.") {
                UserDefaults.standard.set(value, forKey: key)
            }
            UserDefaults.standard.set(true, forKey: "glint.devDefaultsSeeded")
        }
        #endif

        // Crash-loop guard: if the previous launch died before going healthy,
        // roll back the setting change that most likely caused it BEFORE we
        // read any preference below — otherwise a bad sticky value (issue #15)
        // replays the same crash on every launch. Also starts journaling
        // subsequent setting changes so the next crash can be undone.
        SettingsSafety.shared.beginLaunch()

        // Apply the stored language choice BEFORE any view materializes so
        // Bundle.main picks the right .lproj at its first lookup. "system"
        // clears the override so macOS falls back to the user's OS-level
        // language. Any explicit choice writes into `AppleLanguages`,
        // which is what NSBundle reads to resolve localized strings.
        let stored = UserDefaults.standard.string(forKey: "glint.preferredLanguage") ?? "system"
        if stored == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([stored], forKey: "AppleLanguages")
        }
    }

    var body: some Scene {
        // Single-instance `Window` scene: it can never spawn a second window,
        // so any external activation (a clicked macOS notification, a reopen)
        // lands on the existing window instead of creating a new one. The
        // UNUserNotificationCenterDelegate handles the pane switch.
        // NB: `handlesExternalEvents` does NOT help here — it only routes
        // URL-scheme / NSUserActivity events, and a local-notification click
        // produces neither. WindowGroup would open a fresh window on reopen.
        Window("Glint", id: "glint-main") {
            ContentView()
                .environmentObject(workspaceStore)
                .environmentObject(updater)
                .environmentObject(usage)
                .environmentObject(codexHomes)
                .environmentObject(shortcuts)
                .frame(minWidth: 980, minHeight: 600)
                .preferredColorScheme(Theme.colorScheme)
                .onAppear { updater.startDeferred() }
                // Live language switching: AppleLanguages (set in init) only
                // applies on the next launch; this env value re-resolves
                // LocalizedStringKey lookups immediately when the user picks
                // a language in Settings.
                .environment(\.locale, workspaceStore.preferredLocale)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // Bindings come from ShortcutStore (defaults + UserDefaults
            // overrides). ⌘↑/⌘↓ and bare ⌘F stay unbound so they reach ghostty.
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") { workspaceStore.requestNewWorkspace() }
                    .keyboardShortcut(shortcuts.chord(for: .newWorkspace))
                Button("Next Workspace") { workspaceStore.selectNextWorkspace() }
                    .keyboardShortcut(shortcuts.chord(for: .nextWorkspace))
                Button("Previous Workspace") { workspaceStore.selectPreviousWorkspace() }
                    .keyboardShortcut(shortcuts.chord(for: .previousWorkspace))
                Button("Archive Workspace") {
                    if let id = workspaceStore.selectedWorkspaceID {
                        workspaceStore.archiveWorkspace(id)
                    } else {
                        NSSound.beep()
                    }
                }
                .keyboardShortcut(shortcuts.chord(for: .archiveWorkspace))
                Button("Delete Workspace") {
                    if let id = workspaceStore.selectedWorkspaceID {
                        workspaceStore.deleteWorkspace(id)
                    } else {
                        NSSound.beep()
                    }
                }
                .keyboardShortcut(shortcuts.chord(for: .deleteWorkspace))
                ForEach(1..<10, id: \.self) { n in
                    Button("Workspace \(n)") { workspaceStore.selectWorkspace(at: n - 1) }
                        .keyboardShortcut(shortcuts.chord(for: ShortcutID.workspaceIndex(n)!))
                }
                Divider()
                Button("Split Right") { workspaceStore.requestSplit(.horizontal) }
                    .keyboardShortcut(shortcuts.chord(for: .splitRight))
                Button("Split Down") { workspaceStore.requestSplit(.vertical) }
                    .keyboardShortcut(shortcuts.chord(for: .splitDown))
                Button("Close Pane") { workspaceStore.closeFocused() }
                    .keyboardShortcut(shortcuts.chord(for: .closePane))
                Button("Focus Next Pane") { workspaceStore.focusNext() }
                    .keyboardShortcut(shortcuts.chord(for: .focusNextPane))
                Button("Focus Previous Pane") { workspaceStore.focusPrevious() }
                    .keyboardShortcut(shortcuts.chord(for: .focusPreviousPane))
                Divider()
                Button("New Tab") { workspaceStore.requestNewTab() }
                    .keyboardShortcut(shortcuts.chord(for: .newTab))
                Button("Close Tab") {
                    if let ws = workspaceStore.selectedWorkspace {
                        workspaceStore.closeTab(ws.selectedTabID)
                    }
                }
                .keyboardShortcut(shortcuts.chord(for: .closeTab))
                Button("Next Tab") { workspaceStore.nextTab() }
                    .keyboardShortcut(shortcuts.chord(for: .nextTab))
                Button("Previous Tab") { workspaceStore.previousTab() }
                    .keyboardShortcut(shortcuts.chord(for: .previousTab))
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    workspaceStore.sidebarCollapsed.toggle()
                }
                .keyboardShortcut(shortcuts.chord(for: .toggleSidebar))
                Button("Command Palette") {
                    workspaceStore.commandPaletteOpen.toggle()
                }
                .keyboardShortcut(shortcuts.chord(for: .commandPalette))
                Button("Find in Sidebar") {
                    workspaceStore.focusSidebarSearch()
                }
                .keyboardShortcut(shortcuts.chord(for: .findInSidebar))
                Button("Review Changes…") {
                    if let ws = workspaceStore.selectedWorkspace {
                        workspaceStore.openReview(for: ws)
                    }
                }
                .keyboardShortcut(shortcuts.chord(for: .reviewChanges))
                .disabled(workspaceStore.selectedWorkspace.flatMap {
                    workspaceStore.effectiveGitPath(for: $0)
                } == nil)
                Button("Reveal in Finder") {
                    workspaceStore.revealCurrentInFinder()
                }
                .keyboardShortcut(shortcuts.chord(for: .revealInFinder))
                Button("Copy Path") {
                    workspaceStore.copyCurrentPath()
                }
                .keyboardShortcut(shortcuts.chord(for: .copyPath))
                Button("Jump to Attention") {
                    workspaceStore.jumpToAttention()
                }
                .keyboardShortcut(shortcuts.chord(for: .jumpToAttention))
            }
            // Hijack the App menu's Settings… so ⌘, opens our in-window
            // sheet instead of trying to summon a separate scene.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    workspaceStore.settingsOpen = true
                }
                .keyboardShortcut(shortcuts.chord(for: .openSettings))
            }
        }
    }
}
