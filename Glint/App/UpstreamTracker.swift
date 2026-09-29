import Foundation
import SwiftUI

// MARK: - GitHub compare API models (file-level so they are not MainActor-isolated)

private struct GitHubCompare: Decodable, Sendable {
    let aheadBy: Int
    let commits: [GitHubCompareCommit]

    enum CodingKeys: String, CodingKey {
        case aheadBy = "ahead_by"
        case commits
    }
}

private struct GitHubCompareCommit: Decodable, Sendable {
    let sha: String
    let commit: Detail

    struct Detail: Decodable, Sendable {
        let message: String
        let author: Signature?
    }

    struct Signature: Decodable, Sendable {
        let date: Date?
    }
}

// MARK: - Tracker

/// Fork-maintenance aid: how many commits upstream (`chenbstack/glint`) has
/// that this fork's `main` on GitHub doesn't, shown as a sidebar badge so
/// merges can be planned. Compares the pushed `main`, not a local checkout —
/// a local merge clears the count once it's pushed and the next poll runs.
///
/// Uses the cross-fork compare API unauthenticated (60 requests / hour per
/// IP); we poll hourly, alongside the updater's own hourly release check.
@MainActor
final class UpstreamTracker: ObservableObject {

    nonisolated static let upstreamOwner = "chenbstack"
    nonisolated static let upstreamRepo = "glint"
    nonisolated static let branch = "main"
    nonisolated private static let enabledKey = "glint.showUpstreamCommits"
    nonisolated private static let pollInterval: TimeInterval = 3600
    /// Newest-first commits kept for the popover; the count stays exact.
    nonisolated private static let listLimit = 15

    struct Commit: Identifiable, Sendable {
        let sha: String
        let title: String
        let date: Date?
        var id: String { sha }
    }

    /// Commits upstream has that our `main` lacks (GitHub's `ahead_by`).
    @Published private(set) var newCommitCount = 0
    /// Most recent of those commits, newest first, capped at `listLimit`.
    @Published private(set) var recentCommits: [Commit] = []
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isChecking = false

    /// Bound to Settings ▸ Updates "Show upstream commits".
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled {
                refresh()
            } else {
                newCommitCount = 0
                recentCommits = []
            }
        }
    }

    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var started = false

    init() {
        enabled = (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    /// `github.com/<fork>/compare/main...chenbstack:main` — upstream's
    /// unmerged commits, the same range the badge counts.
    var compareURL: URL {
        URL(string: "https://github.com/\(UpdaterController.githubOwner)/\(UpdaterController.githubRepo)/compare/\(Self.baseRef)...\(Self.upstreamOwner):\(Self.branch)")!
    }

    /// Called once from the main window `onAppear`: a first check shortly
    /// after launch, then hourly.
    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        guard enabled, checkTask == nil else { return }
        isChecking = true
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.checkTask = nil
                self.isChecking = false
            }
            do {
                let compare = try await Self.fetchCompare()
                // Toggled off mid-flight: don't resurrect the badge.
                guard self.enabled else { return }
                self.newCommitCount = compare.aheadBy
                self.recentCommits = compare.commits.reversed().prefix(Self.listLimit).map {
                    Commit(
                        sha: $0.sha,
                        title: $0.commit.message.split(separator: "\n", maxSplits: 1)
                            .first.map(String.init) ?? "",
                        date: $0.commit.author?.date
                    )
                }
                self.lastCheckedAt = Date()
            } catch {
                // Offline / rate limited: keep the last known count rather
                // than flashing the badge away.
                NSLog("[glint] upstream check failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: Network

    /// Base side of the comparison: our fork's `main`. Debug builds can pin
    /// an older ref (`GLINT_DEBUG_UPSTREAM_BASE=<sha>`) to exercise the badge
    /// when the fork is fully caught up.
    nonisolated private static var baseRef: String {
        #if DEBUG
        if let ref = ProcessInfo.processInfo.environment["GLINT_DEBUG_UPSTREAM_BASE"], !ref.isEmpty {
            return ref
        }
        #endif
        return branch
    }

    nonisolated private static func fetchCompare() async throws -> GitHubCompare {
        let fork = "\(UpdaterController.githubOwner)/\(UpdaterController.githubRepo)"
        let url = URL(string:
            "https://api.github.com/repos/\(fork)/compare/\(baseRef)...\(upstreamOwner):\(branch)"
        )!
        var request = URLRequest(url: url)
        request.setValue("Glint/\(UpdaterController.currentVersionString())", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubCompare.self, from: data)
    }
}
