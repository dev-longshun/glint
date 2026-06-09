import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let frameDefaultsKey = "glint.mainWindowFrame"
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.configureMainWindow()
            self.patchMainMenu()
        }
    }

    /// SwiftUI auto-adds File > Close Window bound to Cmd+W; that competes with
    /// our "close pane" shortcut and ends up closing the entire window first.
    /// Strip the shortcut from the system close items so only our handler runs.
    private func patchMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for topItem in mainMenu.items {
            guard let submenu = topItem.submenu else { continue }
            for item in submenu.items {
                if item.action == #selector(NSWindow.performClose(_:))
                    && item.keyEquivalent == "w" {
                    item.keyEquivalent = ""
                    item.keyEquivalentModifierMask = []
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-suspenders: save the frame at quit even if didMove /
        // didEndLiveResize never fired this session (e.g. user opens, never
        // touches the window, quits).
        persistMainWindowFrame()
    }

    private func configureMainWindow() {
        guard let window = NSApp.windows.first else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarSeparatorStyle = .none
        // Sidebar inset to nothing — we draw chrome ourselves
        window.toolbar = nil

        // We manage the frame ourselves. SwiftUI's WindowGroup assigns its
        // own `frameAutosaveName` (derived from the modifier chain on
        // ContentView) and re-asserts it after we set our own — so
        // `setFrameAutosaveName` looked like it took effect but got
        // overwritten silently. Instead persist the frame in UserDefaults
        // and apply it on launch, listening for move/resize to update.
        mainWindow = window
        if let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let rect = NSRectFromString(saved)
            if rect.width > 0 && rect.height > 0 {
                window.setFrame(rect, display: true, animate: false)
            } else {
                applyDefaultFrame(window)
            }
        } else {
            applyDefaultFrame(window)
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(persistMainWindowFrame),
                       name: NSWindow.didMoveNotification, object: window)
        nc.addObserver(self, selector: #selector(persistMainWindowFrame),
                       name: NSWindow.didEndLiveResizeNotification, object: window)
    }

    private func applyDefaultFrame(_ window: NSWindow) {
        window.setContentSize(NSSize(width: 1320, height: 824))
        window.center()
    }

    @objc private func persistMainWindowFrame() {
        guard let window = mainWindow else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameDefaultsKey)
    }
}
