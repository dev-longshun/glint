import SwiftUI

struct PaneTreeView: View {
    let node: SplitNode

    var body: some View {
        switch node {
        case .leaf(let id):
            PaneView(paneID: id)
        case .split(let dir, _, let a, let b):
            if dir == .horizontal {
                HSplit(a: a, b: b)
            } else {
                VSplit(a: a, b: b)
            }
        }
    }
}

private struct HSplit: View {
    let a: SplitNode
    let b: SplitNode
    var body: some View {
        HStack(spacing: 1) {
            PaneTreeView(node: a)
            Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1)
            PaneTreeView(node: b)
        }
    }
}

private struct VSplit: View {
    let a: SplitNode
    let b: SplitNode
    var body: some View {
        VStack(spacing: 1) {
            PaneTreeView(node: a)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            PaneTreeView(node: b)
        }
    }
}
