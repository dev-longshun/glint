import AppKit
import Combine
import SwiftUI

// MARK: - Key chord

/// A single keyboard chord: one key + a modifier set.
/// Codable for UserDefaults persistence.
struct KeyChord: Codable, Equatable, Hashable, Sendable {
    /// Lowercase character for letter/digit keys, or a well-known special name
    /// (`backspace`, `tab`, `escape`, `return`, `space`, `up`, `down`, `left`,
    /// `right`, `delete`, `/`, `[`, `]`, `,`, `.`).
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    var nsModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// SwiftUI menu / button binding.
    var keyEquivalent: KeyEquivalent {
        switch key {
        case "backspace", "delete": return .delete
        case "tab": return .tab
        case "escape": return .escape
        case "return": return .return
        case "space": return .space
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        default:
            if let ch = key.first { return KeyEquivalent(ch) }
            return KeyEquivalent("?")
        }
    }

    /// Caps for Settings / HUD, e.g. `["⌘", "⌫"]`.
    var displayCaps: [String] {
        var caps: [String] = []
        if control { caps.append("⌃") }
        if option { caps.append("⌥") }
        if shift { caps.append("⇧") }
        if command { caps.append("⌘") }
        caps.append(Self.displayKey(key))
        return caps
    }

    /// Single-line summary for conflict alerts.
    var displayString: String {
        displayCaps.joined()
    }

    static func displayKey(_ key: String) -> String {
        switch key {
        case "backspace", "delete": return "⌫"
        case "tab": return "⇥"
        case "escape": return "⎋"
        case "return": return "⏎"
        case "space": return "␣"
        case "up": return "↑"
        case "down": return "↓"
        case "left": return "←"
        case "right": return "→"
        default: return key.uppercased()
        }
    }

    /// Build from an `NSEvent` keyDown. Returns nil for pure modifier presses
    /// or keys we refuse to bind (function keys without a glyph, etc.).
    static func from(event: NSEvent) -> KeyChord? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

        let key: String?
        switch event.keyCode {
        case 51, 117: key = "backspace" // delete / forward-delete both map to ⌫ action
        case 48: key = "tab"
        case 53: key = "escape"
        case 36, 76: key = "return"
        case 49: key = "space"
        case 126: key = "up"
        case 125: key = "down"
        case 123: key = "left"
        case 124: key = "right"
        default:
            if let chars = event.charactersIgnoringModifiers?.lowercased(),
               let ch = chars.first, ch.isASCII, !ch.isWhitespace {
                // Strip option-generated special glyphs for letter keys: when
                // Option is held, charactersIgnoringModifiers still yields the
                // base letter on most layouts.
                key = String(ch)
            } else {
                key = nil
            }
        }
        guard let key else { return nil }

        // Require at least one modifier for printable single keys, so users
        // don't steal plain "d" from the terminal. Special keys (arrows, tab,
        // escape, return, backspace) may stand alone (command palette, etc.).
        let special: Set<String> = [
            "backspace", "tab", "escape", "return", "space",
            "up", "down", "left", "right",
        ]
        let hasModifier = flags.contains(.command)
            || flags.contains(.shift)
            || flags.contains(.option)
            || flags.contains(.control)
        if !special.contains(key) && !hasModifier {
            return nil
        }

        return KeyChord(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }
}

// MARK: - Shortcut identity

enum ShortcutID: String, Codable, CaseIterable, Identifiable, Sendable {
    // Workspace
    case newWorkspace
    case nextWorkspace
    case previousWorkspace
    case deleteWorkspace
    case archiveWorkspace
    case workspace1, workspace2, workspace3, workspace4, workspace5
    case workspace6, workspace7, workspace8, workspace9

    // Panes
    case splitRight
    case splitDown
    case closePane
    case focusNextPane
    case focusPreviousPane

    // Tabs
    case newTab
    case closeTab
    case nextTab
    case previousTab

    // Window / chrome
    case toggleSidebar
    case commandPalette
    case findInSidebar
    case reviewChanges
    case revealInFinder
    case copyPath
    case jumpToAttention
    case openSettings

    var id: String { rawValue }

    /// Group for Settings layout.
    enum Group: String, CaseIterable {
        case workspace
        case panes
        case tabs
        case window
    }

    var group: Group {
        switch self {
        case .newWorkspace, .nextWorkspace, .previousWorkspace,
             .deleteWorkspace, .archiveWorkspace,
             .workspace1, .workspace2, .workspace3, .workspace4, .workspace5,
             .workspace6, .workspace7, .workspace8, .workspace9:
            return .workspace
        case .splitRight, .splitDown, .closePane, .focusNextPane, .focusPreviousPane:
            return .panes
        case .newTab, .closeTab, .nextTab, .previousTab:
            return .tabs
        case .toggleSidebar, .commandPalette, .findInSidebar, .reviewChanges,
             .revealInFinder, .copyPath, .jumpToAttention, .openSettings:
            return .window
        }
    }

    /// English title key (LocalizedStringKey source).
    var title: String {
        switch self {
        case .newWorkspace: return "New Workspace"
        case .nextWorkspace: return "Next Workspace"
        case .previousWorkspace: return "Previous Workspace"
        case .deleteWorkspace: return "Delete Workspace"
        case .archiveWorkspace: return "Archive Workspace"
        case .workspace1: return "Workspace 1"
        case .workspace2: return "Workspace 2"
        case .workspace3: return "Workspace 3"
        case .workspace4: return "Workspace 4"
        case .workspace5: return "Workspace 5"
        case .workspace6: return "Workspace 6"
        case .workspace7: return "Workspace 7"
        case .workspace8: return "Workspace 8"
        case .workspace9: return "Workspace 9"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .closePane: return "Close Pane"
        case .focusNextPane: return "Focus Next Pane"
        case .focusPreviousPane: return "Focus Previous Pane"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .toggleSidebar: return "Toggle Sidebar"
        case .commandPalette: return "Command Palette"
        case .findInSidebar: return "Find in Sidebar"
        case .reviewChanges: return "Review Changes…"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        case .jumpToAttention: return "Jump to Attention"
        case .openSettings: return "Settings"
        }
    }

    static func workspaceIndex(_ n: Int) -> ShortcutID? {
        switch n {
        case 1: return .workspace1
        case 2: return .workspace2
        case 3: return .workspace3
        case 4: return .workspace4
        case 5: return .workspace5
        case 6: return .workspace6
        case 7: return .workspace7
        case 8: return .workspace8
        case 9: return .workspace9
        default: return nil
        }
    }

    static var ordered: [ShortcutID] { allCases }

    static func inGroup(_ group: Group) -> [ShortcutID] {
        allCases.filter { $0.group == group }
    }
}

// MARK: - Store

@MainActor
final class ShortcutStore: ObservableObject {
    nonisolated static let defaultsKey = "glint.shortcuts"

    /// Overrides only — missing keys fall back to `defaultChord`.
    /// Public so Settings can disable “Reset All” when empty.
    @Published private(set) var overrides: [ShortcutID: KeyChord] = [:]

    init() {
        load()
    }

    func chord(for id: ShortcutID) -> KeyChord {
        overrides[id] ?? Self.defaultChord(for: id)
    }

    func isCustomized(_ id: ShortcutID) -> Bool {
        overrides[id] != nil
    }

    /// Returns the conflicting action if `chord` is already bound elsewhere.
    func conflict(for chord: KeyChord, excluding: ShortcutID) -> ShortcutID? {
        for id in ShortcutID.allCases where id != excluding {
            if self.chord(for: id) == chord { return id }
        }
        return nil
    }

    /// Assign a chord. Returns the conflict id if rejected.
    @discardableResult
    func set(_ id: ShortcutID, chord: KeyChord) -> ShortcutID? {
        if let other = conflict(for: chord, excluding: id) {
            return other
        }
        if chord == Self.defaultChord(for: id) {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = chord
        }
        persist()
        objectWillChange.send()
        return nil
    }

    func reset(_ id: ShortcutID) {
        overrides.removeValue(forKey: id)
        persist()
        objectWillChange.send()
    }

    func resetAll() {
        overrides.removeAll()
        persist()
        objectWillChange.send()
    }

    // MARK: Defaults

    nonisolated static func defaultChord(for id: ShortcutID) -> KeyChord {
        switch id {
        case .newWorkspace:
            return KeyChord(key: "n", command: true)
        case .nextWorkspace:
            return KeyChord(key: "]", command: true, shift: true)
        case .previousWorkspace:
            return KeyChord(key: "[", command: true, shift: true)
        case .deleteWorkspace:
            return KeyChord(key: "backspace", command: true)
        case .archiveWorkspace:
            return KeyChord(key: "0", command: true)
        // ⌘1…9 — AppKit menu shortcuts are reliable with Command; pure Option
        // remaps digits to symbols (¡™£…) and fails to fire in the terminal.
        case .workspace1: return KeyChord(key: "1", command: true)
        case .workspace2: return KeyChord(key: "2", command: true)
        case .workspace3: return KeyChord(key: "3", command: true)
        case .workspace4: return KeyChord(key: "4", command: true)
        case .workspace5: return KeyChord(key: "5", command: true)
        case .workspace6: return KeyChord(key: "6", command: true)
        case .workspace7: return KeyChord(key: "7", command: true)
        case .workspace8: return KeyChord(key: "8", command: true)
        case .workspace9: return KeyChord(key: "9", command: true)
        case .splitRight:
            return KeyChord(key: "d", command: true)
        case .splitDown:
            return KeyChord(key: "d", command: true, shift: true)
        case .closePane:
            return KeyChord(key: "w", command: true)
        case .focusNextPane:
            return KeyChord(key: "]", command: true)
        case .focusPreviousPane:
            return KeyChord(key: "[", command: true)
        case .newTab:
            return KeyChord(key: "t", command: true)
        case .closeTab:
            return KeyChord(key: "w", command: true, shift: true)
        case .nextTab:
            return KeyChord(key: "tab", control: true)
        case .previousTab:
            return KeyChord(key: "tab", shift: true, control: true)
        case .toggleSidebar:
            return KeyChord(key: "/", command: true)
        case .commandPalette:
            return KeyChord(key: "p", command: true, shift: true)
        case .findInSidebar:
            return KeyChord(key: "f", command: true, option: true)
        case .reviewChanges:
            return KeyChord(key: "r", command: true, shift: true)
        case .revealInFinder:
            return KeyChord(key: "f", command: true, shift: true)
        case .copyPath:
            return KeyChord(key: "c", command: true, shift: true)
        case .jumpToAttention:
            return KeyChord(key: "a", command: true, shift: true)
        case .openSettings:
            return KeyChord(key: ",", command: true)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        guard let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data) else {
            return
        }
        var map: [ShortcutID: KeyChord] = [:]
        for (raw, chord) in decoded {
            guard let id = ShortcutID(rawValue: raw) else { continue }
            map[id] = chord
        }
        overrides = map
    }

    private func persist() {
        var raw: [String: KeyChord] = [:]
        for (id, chord) in overrides {
            raw[id.rawValue] = chord
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - SwiftUI helpers

extension View {
    /// Apply a user-configurable chord as a keyboard shortcut.
    func keyboardShortcut(_ chord: KeyChord) -> some View {
        keyboardShortcut(chord.keyEquivalent, modifiers: chord.modifiers)
    }
}
