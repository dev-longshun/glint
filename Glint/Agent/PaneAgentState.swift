import Foundation

/// Which CLI agent the pane is running.
enum PaneAgentKind: String, Codable {
    case claude
    case codex
    case opencode
    case devin
    case omp
    case grok
    case pi
    case agy

    /// Human-facing label for the per-pane summary popover.
    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .opencode: return "OpenCode"
        case .devin:    return "Devin"
        case .omp:      return "OMP"
        case .grok:     return "Grok"
        case .pi:       return "Pi"
        case .agy:      return "Antigravity"
        }
    }

    /// Single source of truth for what a CLI-agent session id may look like.
    /// Used by Swift's `isValid(sessionId:)` validator AND interpolated into
    /// the OpenCode JS plugin's regex, so the same alphabet+length applies on
    /// both ingress sides. Bare character-class body (no anchors) — JS adds
    /// `^…$`; Swift's validator walks unicode scalars.
    static let sessionIdCharsetClass = "[A-Za-z0-9_-]"
    static let sessionIdMaxLength = 128

    /// Cheap whitelist for a CLI-agent session id before we paste it into a
    /// resume command (`claude --resume <id>`, `codex resume <id>`). The
    /// string ends up on the pane's stdin, so a stray quote/newline/space
    /// would break the command (or worse, smuggle extra input). Both Claude
    /// and Codex session ids are UUIDs in practice; we keep the alphabet a
    /// touch wider (alnum + `-`/`_`) to absorb minor format changes, then
    /// bound the length so a corrupt payload can't wedge an unbounded string.
    static func isValid(sessionId s: String) -> Bool {
        guard !s.isEmpty, s.count <= sessionIdMaxLength else { return false }
        return s.unicodeScalars.allSatisfy { sc in
            (sc.value >= 0x30 && sc.value <= 0x39) ||  // 0-9
            (sc.value >= 0x41 && sc.value <= 0x5A) ||  // A-Z
            (sc.value >= 0x61 && sc.value <= 0x7A) ||  // a-z
            sc == "-" || sc == "_"
        }
    }

    /// Shell command (with trailing newline) that boots the agent at session
    /// restore time. With a captured `sessionId`, jumps straight back to THAT
    /// pane's session (#45 fix — without it, multiple panes collapse onto the
    /// most-recent session). nil id ⇒ "resume the most-recent" fallback for
    /// pre-fix data or panes where no hook fired before shutdown.
    ///
    /// Defends in depth: any non-nil id that fails the charset whitelist is
    /// downgraded to the fallback form rather than being interpolated into
    /// the TTY string. This keeps the function safe even if a future caller
    /// forgets the outer validation step (the value lands on a real shell).
    ///
    /// `codexHome` carries the resolved `CODEX_HOME` path a non-default-home
    /// Codex pane was launched under, so the restart re-prefixes the resume
    /// command with it. Without this a pane started under e.g. `~/codex-test`
    /// resumes against the default `~/.codex`, where its session doesn't
    /// exist (#45 regression for the multi-home feature). nil/default ⇒ no
    /// prefix. Ignored by every kind other than `.codex`.
    ///
    /// `launchFlags` are the permission flags captured from the pane's live
    /// argv (see `permissionFlags(fromArguments:)`), so a pane started via an
    /// alias like `cc` → `claude --dangerously-skip-permissions` comes back in
    /// the same mode instead of the CLI default. Re-filtered through the
    /// whitelist here, same defense-in-depth as the session id.
    func restoreCommand(sessionId: String?, codexHome: String? = nil,
                        launchFlags: [String] = []) -> String {
        let validated: String? = sessionId.flatMap {
            PaneAgentKind.isValid(sessionId: $0) ? $0 : nil
        }
        let flags = self.permissionFlags(fromArguments: launchFlags)
        let f = flags.isEmpty ? "" : flags.joined(separator: " ") + " "
        switch self {
        case .claude:
            return validated.map { "claude \(f)--resume \($0)\n" } ?? "claude \(f)--continue\n"
        case .codex:
            let prefix = codexHome.map { "CODEX_HOME=\(posixShellQuoted($0)) " } ?? ""
            return validated.map { "\(prefix)codex resume \(f)\($0)\n" }
                ?? "\(prefix)codex resume \(f)--last\n"
        case .opencode:
            return validated.map { "opencode --session \($0)\n" } ?? "opencode --continue\n"
        case .devin:
            return validated.map { "devin --resume \($0)\n" } ?? "devin --continue\n"
        case .omp:
            return validated.map { "omp -r \($0)\n" } ?? "omp -c\n"
        case .grok:
            return validated.map { "grok \(f)--resume \($0)\n" } ?? "grok \(f)--continue\n"
        case .pi:
            // `pi --session-id <id>` uses an exact project session id,
            // creating it if missing — so a restored pane lands back in its
            // own session instead of being prompted to pick one (as the
            // interactive `--resume` would). Falls back to `pi --continue`
            // (resume the most-recent) when no id was captured.
            return validated.map { "pi --session-id \($0)\n" } ?? "pi --continue\n"
        case .agy:
            // Antigravity's hooks carry `conversationId` in every payload;
            // `--conversation <id>` resumes exactly that conversation, so
            // multiple agy panes in one workspace land back in their own
            // sessions instead of the most-recent one. Falls back to
            // `--continue` (resume the most-recent) when no id was captured.
            return validated.map { "agy --conversation \($0)\n" } ?? "agy --continue\n"
        }
    }

    // MARK: Launch permission flags

    /// A permission-related CLI flag worth replaying on restore. `aliases`
    /// are extra spellings accepted on ingress (e.g. `-a`); output always
    /// uses `name`. `takesValue` flags consume `--flag value` or `--flag=value`.
    private struct LaunchFlagSpec {
        let name: String
        var aliases: [String] = []
        var takesValue = false
    }

    /// Per-agent whitelist of flags remembered across a restart. Deliberately
    /// narrow — only permission / approval / sandbox switches. Prompts,
    /// models, dirs and `-c` overrides are ignored, since the result is typed
    /// onto a live shell. Kinds returning `[]` never carry flags.
    private var launchFlagSpecs: [LaunchFlagSpec] {
        switch self {
        case .claude:
            return [
                LaunchFlagSpec(name: "--dangerously-skip-permissions"),
                LaunchFlagSpec(name: "--permission-mode", takesValue: true),
            ]
        case .codex:
            // No `--full-auto`: Codex 0.158 renamed it `--approve-for-me` and
            // rejects the old spelling, so replaying it would break the resume.
            return [
                LaunchFlagSpec(name: "--dangerously-bypass-approvals-and-sandbox"),
                LaunchFlagSpec(name: "--approve-for-me"),
                LaunchFlagSpec(name: "--ask-for-approval", aliases: ["-a"], takesValue: true),
                LaunchFlagSpec(name: "--sandbox", aliases: ["-s"], takesValue: true),
            ]
        case .grok:
            return [
                LaunchFlagSpec(name: "--always-approve"),
                LaunchFlagSpec(name: "--permission-mode", takesValue: true),
                LaunchFlagSpec(name: "--sandbox", takesValue: true),
            ]
        case .opencode, .devin, .omp, .pi, .agy:
            return []
        }
    }

    static let launchFlagValueMaxLength = 64

    /// Flag values (`bypassPermissions`, `danger-full-access`, `never`, …) use
    /// the session-id alphabet with a shorter cap, and may not look like a flag.
    static func isValid(launchFlagValue v: String) -> Bool {
        !v.hasPrefix("-") && v.count <= launchFlagValueMaxLength && isValid(sessionId: v)
    }

    /// Pick the whitelisted permission flags out of an agent's argv (without
    /// argv[0]). Output is canonical — long spelling, `--flag value` as two
    /// tokens, argv order, first occurrence wins — so it is idempotent: the
    /// output fed back in returns itself, which is how `restoreCommand`
    /// re-validates persisted flags. A flag with a missing or invalid value is
    /// dropped whole; scanning stops at `--` (the rest is positional).
    func permissionFlags(fromArguments args: [String]) -> [String] {
        let specs = launchFlagSpecs
        guard !specs.isEmpty else { return [] }
        var out: [String] = []
        var seen: Set<String> = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            if arg == "--" { break }
            guard arg.hasPrefix("-") else { continue }
            var flag = arg
            var inlineValue: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                flag = String(arg[..<eq])
                inlineValue = String(arg[arg.index(after: eq)...])
            }
            guard let spec = specs.first(where: { $0.name == flag || $0.aliases.contains(flag) }),
                  !seen.contains(spec.name) else { continue }
            if spec.takesValue {
                var value = inlineValue
                if value == nil, i < args.count, !args[i].hasPrefix("-") {
                    value = args[i]
                    i += 1
                }
                guard let value, Self.isValid(launchFlagValue: value) else { continue }
                out += [spec.name, value]
            } else {
                guard inlineValue == nil else { continue }
                out.append(spec.name)
            }
            seen.insert(spec.name)
        }
        return out
    }
}

enum PaneAgentStatus: String, Codable {
    case idle              // session live, no active turn
    case thinking          // user prompted, agent working
    case tool              // a tool just fired
    case needsPermission   // agent is asking for user approval
    case compacting        // auto-compacting context window
    case justCompleted     // turn just finished — transient, fades to idle
    case failed            // turn ended in an API/transport error (StopFailure)
    case needsReply        // turn ended, agent idle waiting for user input (OMP NeedsReply)

    /// "Float to top" / "jump to next" priority — the single source of truth
    /// shared by the sidebar sort (`SidebarView`) and ⌘⇧A
    /// (`WorkspaceStore.jumpToAttention`) so the two always land on the same
    /// "most worth seeing next" pane. A blocking `.needsPermission` outranks
    /// unread results (a turn that `.failed`, `.justCompleted`, or
    /// `.needsReply`), which all float above everything else. Exhaustive, so
    /// adding a new case is a compile error here — decide its rank in one
    /// place, not at every call site. This is a coarser axis than
    /// `WorkspaceStore.statusRank` (the status-dot ranking, which ranks
    /// `.failed` above `.justCompleted`); here they're peers, so a local
    /// just-completed pane can win a tie against a remote one.
    var attentionRank: Int {
        switch self {
        case .needsPermission:                          return 0   // blocking → top
        case .failed, .justCompleted, .needsReply:      return 1   // unread results
        case .idle, .thinking, .tool, .compacting:      return Self.sinkAttentionRank
        }
    }

    /// The rank at which a status stops floating / no longer counts as "needs
    /// you". `jumpToAttention` ignores panes at this rank or higher.
    static let sinkAttentionRank = 2

    /// Lowest (most urgent) attention rank in a collection. Keeping this on the
    /// attention axis prevents callers from first collapsing multiple panes
    /// through the unrelated status-dot ordering.
    static func bestAttentionRank<S: Sequence>(in statuses: S) -> Int
    where S.Element == PaneAgentStatus {
        statuses.reduce(sinkAttentionRank) { min($0, $1.attentionRank) }
    }
}

struct PaneAgentState: Codable, Equatable {
    var kind: PaneAgentKind
    var status: PaneAgentStatus
    var detail: String?       // tool name, notification text, …
    var updatedAt: Date       // last status change — bumped on every hook event
    /// When the CURRENT turn began (user sent the request). Unlike `updatedAt`,
    /// this is NOT reset on intermediate tool/thinking transitions, so the
    /// sidebar can show total turn elapsed time rather than per-step time.
    var turnStartedAt: Date

    init(kind: PaneAgentKind, status: PaneAgentStatus, detail: String? = nil,
         updatedAt: Date, turnStartedAt: Date? = nil) {
        self.kind = kind
        self.status = status
        self.detail = detail
        self.updatedAt = updatedAt
        self.turnStartedAt = turnStartedAt ?? updatedAt
    }
}
