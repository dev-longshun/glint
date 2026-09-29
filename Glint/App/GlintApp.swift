import AppKit
import OSLog
import SwiftUI

/// Stops a dead macOS view service from taking the whole session down.
///
/// macOS parents cross-process `NSRemoteView`s into our window's ordering
/// group for UI the app never asked for — the text-input cursor HUD
/// (`TextInputUI.xpc.CursorUIViewService`) and the data-detector helper
/// (`SafariPlatformSupport.Helper`) both appear there while a pane has
/// keyboard focus. When macOS reclaims one of those services, its remote view
/// can stay parented to the window. The next child window to order on screen
/// makes AppKit broadcast `containingWindowWillOrderOnScreen:` across the
/// whole ordering group; the orphaned remote view fails an internal ViewBridge
/// assertion, and the `NSInternalInconsistencyException` it raises unwinds with
/// no handler anywhere above it. Nothing of ours is on that stack — a healthy
/// process dies for a service it does not own, losing every terminal in the
/// window.
///
/// `-[NSWindow addChildWindow:ordered:]` is the narrowest frame that encloses
/// the entire broadcast (`_rebuildOrderingGroup:` → `_doOrderWindow:` →
/// `NSNotificationCenter` → the remote view), and every child-window
/// presentation the app can make — SwiftUI `.popover`, sheets, menus — funnels
/// through it. Wrapping that one method in `@try`/`@catch` is therefore enough
/// to contain the failure, and it is the *only* thing that is: the exception
/// never reaches `-[NSApplication reportException:]`, and an uncaught-exception
/// handler cannot resume execution. Both alternatives were measured against a
/// reproduction before landing this; see the tracker.
///
/// The `@catch` lives in ObjC (`ChildWindowExceptionGuard.m`) because Swift
/// cannot catch ObjC exceptions. This type owns the policy it applies.
@objc(GlintChildWindowExceptionGuard)
final class ChildWindowExceptionGuard: NSObject {
    private static let log = Logger(subsystem: "app.glint", category: "ChildWindowExceptionGuard")

    /// Swizzles `-[NSWindow addChildWindow:ordered:]`. Idempotent, and a no-op
    /// if AppKit ever stops responding to that selector, so a future macOS can
    /// only cost us the guard — never the launch.
    static func install() {
        glint_installChildWindowExceptionGuard()
    }

    /// Whether the swizzle is in place. Exposed so a test can catch the guard
    /// silently not being installed — an unguarded app looks completely normal
    /// until the day a view service dies.
    static var isInstalled: Bool { glint_childWindowExceptionGuardIsInstalled() }

    /// Recognises the "a view service died while its remote view was still in
    /// our ordering group" family, and nothing else. Anything that fails this
    /// test is re-thrown by the ObjC guard and still crashes loudly.
    ///
    /// Both halves are load-bearing. The name alone is far too broad —
    /// `NSInternalInconsistencyException` is also the standard raise for our
    /// own precondition failures. The stack is what pins it to AppKit's
    /// cross-process view plumbing: `ViewBridge` is the framework that owns
    /// `NSRemoteView`, and neither string can appear in a frame the app itself
    /// produced. An exception carrying no symbolicated stack is re-thrown
    /// rather than guessed at.
    @objc static func shouldSwallow(name: String, callStack: [String]) -> Bool {
        guard name == NSExceptionName.internalInconsistencyException.rawValue else { return false }
        return callStack.contains { $0.contains("NSRemoteView") || $0.contains("ViewBridge") }
    }

    /// Swallowing must never be silent: this is the only trace that a popover,
    /// sheet or menu quietly failed to present.
    @objc static func noteSwallowed(name: String, reason: String?) {
        log.fault(
            """
            swallowed orphaned remote-view exception in addChildWindow: \
            \(name, privacy: .public) — \(reason ?? "(no reason)", privacy: .public)
            """
        )
    }
}

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var updater = UpdaterController()
    @StateObject private var upstream = UpstreamTracker()
    @StateObject private var usage = UsageStore()
    @StateObject private var codexHomes = CodexHomeStore()
    @StateObject private var shortcuts = ShortcutStore()

    init() {
        // Before any window exists: a dead macOS view service left parented to
        // our window otherwise turns the next popover/sheet/menu into a crash.
        ChildWindowExceptionGuard.install()

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
                .environmentObject(workspaceStore.activity)
                .environmentObject(updater)
                .environmentObject(upstream)
                .environmentObject(usage)
                .environmentObject(codexHomes)
                .environmentObject(shortcuts)
                .frame(minWidth: 980, minHeight: 600)
                .preferredColorScheme(Theme.colorScheme)
                .onAppear {
                    updater.startDeferred()
                    upstream.start()
                }
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
                Button("Rename Workspace") { workspaceStore.requestRenameSelectedWorkspace() }
                    .keyboardShortcut(shortcuts.chord(for: .renameWorkspace))
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
