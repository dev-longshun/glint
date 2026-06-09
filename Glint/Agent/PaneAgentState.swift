import Foundation

/// Which CLI agent the pane is running. Right now only Claude Code is
/// wired through; codex/aider/etc. can be added when their hooks land.
enum PaneAgentKind: String, Codable {
    case claude
    case codex
}

enum PaneAgentStatus: String, Codable {
    case idle              // session live, no active turn
    case thinking          // user prompted, agent working
    case tool              // a tool just fired
    case needsPermission   // agent is asking for user approval
    case compacting        // auto-compacting context window
    case justCompleted     // turn just finished — transient, fades to idle
}

struct PaneAgentState: Codable, Equatable {
    var kind: PaneAgentKind
    var status: PaneAgentStatus
    var detail: String?       // tool name, notification text, …
    var updatedAt: Date
}
