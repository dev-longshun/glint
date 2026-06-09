import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    /// When false the area refuses to initiate window-dragging on mouseDown.
    /// Default is false so sidebars / panes don't grab the window by accident;
    /// the toolbar opts in explicitly.
    let allowsWindowDrag: Bool

    init(material: NSVisualEffectView.Material = .sidebar,
         blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
         state: NSVisualEffectView.State = .followsWindowActiveState,
         allowsWindowDrag: Bool = false) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.allowsWindowDrag = allowsWindowDrag
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v: NSVisualEffectView = allowsWindowDrag
            ? NSVisualEffectView()
            : NoDragVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

private final class NoDragVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}
