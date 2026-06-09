import SwiftUI

struct PaneView: View {
    @EnvironmentObject var store: WorkspaceStore
    let paneID: PaneID

    var body: some View {
        let isFocused = store.currentFocusedPane == paneID
        let wsID = store.selectedWorkspaceID ?? UUID()
        let cwd = store.currentPanes[paneID]?.workingDirectory
        ZStack {
            Theme.bgPane
            PaneSurfaceRepresentable(
                surfaceView: store.surfaceView(workspaceID: wsID, paneID: paneID, cwd: cwd),
                focused: .constant(isFocused)
            )
            if !isFocused {
                Theme.bgPane.opacity(0.45)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focus(paneID) }
    }
}
