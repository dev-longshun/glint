import SwiftUI

struct StatusbarView: View {
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: Theme.green.opacity(0.4), radius: 3)
                Text("connected")
            }
            statusChip(symbol: "arrow.triangle.branch", text: "main · clean")
            statusChip(text: "\(paneCount)×panes")

            Spacer()

            statusChip(text: "UTF-8")
            statusChip(text: "zsh 5.9")
            Text("⌘D split  ⌘⇧D vsplit  ⌘W close")
                .foregroundStyle(Theme.text4)
        }
        .font(.glintStatus)
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(
            Color.black.opacity(0.35)
                .overlay(Rectangle().fill(Theme.divider).frame(height: 1), alignment: .top)
        )
    }

    @ViewBuilder
    private func statusChip(symbol: String? = nil, text: String) -> some View {
        HStack(spacing: 5) {
            if let s = symbol { Image(systemName: s).font(.system(size: 10)) }
            Text(text)
        }
    }

    private var paneCount: Int { store.currentPanes.count }
}
