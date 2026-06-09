import Foundation
import AppKit
import GhosttyKit

/// Owns the single `ghostty_app_t` for the process and pumps its tick loop.
///
/// Lifecycle:
///   ghostty_init() → ghostty_config_new + load_default_files + finalize →
///   ghostty_app_new(runtime_config, config) → timer fires ghostty_app_tick
///   while alive.
final class GhosttyManager {
    static let shared = GhosttyManager()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var timer: DispatchSourceTimer?

    private init() {
        bootstrap()
    }

    private func bootstrap() {
        // ghostty reads argv[0] to learn the executable path, so we must
        // pass the real process argv (lives for the whole process).
        let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if rc != 0 {
            NSLog("ghostty_init failed: \(rc)")
            return
        }

        guard let cfg = ghostty_config_new() else {
            NSLog("ghostty_config_new returned nil")
            return
        }
        self.config = cfg
        ghostty_config_load_default_files(cfg)
        applyGlintTheme(cfg)
        ghostty_config_finalize(cfg)

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in GhosttyManager.fromUD(ud)?.tickSoon() },
            action_cb: GhosttyManager.handleAction,
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: GhosttyManager.writeClipboard,
            close_surface_cb: GhosttyManager.closeSurface
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("ghostty_app_new returned nil")
            return
        }
        self.app = app

        startTickLoop()
    }

    private func startTickLoop() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        // 60 Hz tick for steady output draining + animation
        t.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16))
        t.setEventHandler { [weak self] in
            guard let app = self?.app else { return }
            ghostty_app_tick(app)
        }
        t.resume()
        self.timer = t
    }

    private func tickSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let app = self?.app else { return }
            ghostty_app_tick(app)
        }
    }

    static func fromUD(_ ud: UnsafeMutableRawPointer?) -> GhosttyManager? {
        guard let ud else { return nil }
        return Unmanaged<GhosttyManager>.fromOpaque(ud).takeUnretainedValue()
    }

    // MARK: clipboard / close stubs

    /// Inline overrides so ghostty's surface matches our chrome. User-tweakable
    /// fields (font family/size, cursor style/blink, scrollback) are read out
    /// of `UserDefaults` so we don't need a Combine subscription on the store
    /// inside this lower layer.
    private func applyGlintTheme(_ cfg: ghostty_config_t) {
        let defaults = UserDefaults.standard
        let family = defaults.string(forKey: "glint.terminalFontFamily") ?? "SF Mono"
        let size: Double = {
            let v = defaults.double(forKey: "glint.terminalFontSize")
            return v == 0 ? 13 : v
        }()
        let cursorStyle = defaults.string(forKey: "glint.terminalCursorStyle") ?? "block"
        let cursorBlink = (defaults.object(forKey: "glint.terminalCursorBlink") as? Bool) ?? true
        let scrollback: Int = {
            let v = defaults.integer(forKey: "glint.terminalScrollback")
            return v == 0 ? 10_000 : v
        }()

        let overrides = """
        background = 0B0A14
        foreground = ECEDF2
        cursor-color = 5E5CE6
        cursor-style = \(cursorStyle)
        cursor-style-blink = \(cursorBlink)
        selection-background = 5E5CE6
        selection-foreground = ECEDF2
        font-family = \(family)
        font-family = Menlo
        font-size = \(size)
        scrollback-limit = \(scrollback)
        window-padding-x = 14
        window-padding-y = 12
        window-padding-balance = true
        adjust-cell-height = 10%
        macos-titlebar-style = hidden
        """
        let source = "glint-inline"
        overrides.withCString { ovr in
            source.withCString { src in
                ghostty_config_load_string(cfg, ovr, UInt(strlen(ovr)), src)
            }
        }
    }

    /// Rebuild the config from current user defaults and push it into the
    /// running ghostty_app. Existing surfaces pick up the new font / cursor /
    /// scrollback settings via ghostty's internal ConfigChange propagation —
    /// no surface recreation required.
    func reloadConfig() {
        guard let app else { return }
        guard let newCfg = ghostty_config_new() else {
            NSLog("ghostty_config_new returned nil during reload")
            return
        }
        ghostty_config_load_default_files(newCfg)
        applyGlintTheme(newCfg)
        ghostty_config_finalize(newCfg)
        ghostty_app_update_config(app, newCfg)
        // ghostty takes the config from here. We keep a reference for parity
        // with bootstrap; we don't free the previous one because ghostty may
        // still be holding it during in-flight reload propagation. The few
        // extra config objects accumulated over a session are bounded by how
        // often a user changes settings (~tens of bytes per knob).
        self.config = newCfg
    }

    private static let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, _, contentPtr, count, _ in
        guard let contentPtr, count > 0 else { return }
        let content = contentPtr.pointee
        guard let cstr = content.data else { return }
        let s = String(cString: cstr)
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    /// ghostty action dispatcher. Most actions we ignore (return true to say
    /// "handled"); we intercept GHOSTTY_ACTION_PWD to drive event-driven cwd
    /// updates instead of polling.
    private static let handleAction: ghostty_runtime_action_cb = { _, target, action in
        if action.tag == GHOSTTY_ACTION_PWD,
           target.tag == GHOSTTY_TARGET_SURFACE,
           let surface = target.target.surface,
           let pwdC = action.action.pwd.pwd {
            let cwd = String(cString: pwdC)
            if let ud = ghostty_surface_userdata(surface) {
                let view = Unmanaged<GhosttySurfaceView>.fromOpaque(ud).takeUnretainedValue()
                DispatchQueue.main.async {
                    view.cachedCwd = cwd
                    NotificationCenter.default.post(name: .ghosttyCwdChanged, object: view)
                }
            }
        }
        return true
    }

    private static let closeSurface: ghostty_runtime_close_surface_cb = { ud, _ in
        // Surface owner (PaneSurface) is who registered ud here.
        // We don't act here; the AppKit owner can poll surface state.
        _ = ud
    }
}
