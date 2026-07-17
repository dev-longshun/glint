import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

// MARK: - GitHub API models (file-level so they are not MainActor-isolated)

private struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, draft, prerelease, assets
    }
}

private struct GitHubAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

struct RemoteUpdateAsset: Sendable {
    let name: String
    let version: String
    let downloadURL: URL
    let sha256: String?
}

// MARK: - Updater

/// In-app updater for the fork: poll `dev-longshun/glint` GitHub Releases,
/// download the latest DMG, strip quarantine, replace this `.app`, relaunch.
///
/// Does **not** use Sparkle / Apple Developer signing. Designed for ad-hoc
/// DMG builds published by `.github/workflows/build-dmg.yml`.
@MainActor
final class UpdaterController: ObservableObject {

    // MARK: Config

    /// Fork that CI publishes our DMGs to. Keep in sync with `origin`.
    nonisolated static let githubOwner = "dev-longshun"
    nonisolated static let githubRepo = "glint"

    nonisolated private static let autoCheckKey = "GlintAutomaticallyChecksForUpdates"
    nonisolated private static let receiveBetaKey = "GlintReceiveBetaUpdates"
    nonisolated private static let lastCheckKey = "GlintLastUpdateCheckAt"

    // MARK: Published UI state

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var availableVersion: String?
    @Published private(set) var downloadProgress: Double = 0
    @Published var canCheckForUpdates: Bool = true

    /// Bound to Settings "Check for updates automatically".
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: Self.autoCheckKey)
        }
    }

    /// Include GitHub prereleases (our CI tags every DMG as prerelease).
    @Published var receiveBetaUpdates: Bool {
        didSet {
            UserDefaults.standard.set(receiveBetaUpdates, forKey: Self.receiveBetaKey)
        }
    }

    private var availableAsset: RemoteUpdateAsset?
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var autoCheckScheduled = false

    // MARK: Init

    init() {
        // Default auto-check on for fork builds; first launch seeds true.
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoCheckKey)
        }
        // Fork DMGs are prereleases; default include them so "Check" finds something.
        if UserDefaults.standard.object(forKey: Self.receiveBetaKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.receiveBetaKey)
        }
        automaticallyChecksForUpdates = UserDefaults.standard.bool(forKey: Self.autoCheckKey)
        receiveBetaUpdates = UserDefaults.standard.bool(forKey: Self.receiveBetaKey)
    }

    // MARK: Lifecycle

    /// Called once from the main window `onAppear`. Schedules a quiet background
    /// check when automatic checks are enabled (throttled to once per hour).
    func startDeferred() {
        guard !autoCheckScheduled else { return }
        autoCheckScheduled = true
        guard automaticallyChecksForUpdates else { return }

        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < 3600 { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.automaticallyChecksForUpdates else { return }
            self.checkForUpdates(userInitiated: false)
        }
    }

    // MARK: Public actions

    func checkForUpdates() {
        checkForUpdates(userInitiated: true)
    }

    /// One-click install: if no remote asset known yet, check first, then
    /// download → unquarantine → replace → relaunch.
    func installAndRelaunch() {
        guard installTask == nil else { return }
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            do {
                if self.availableAsset == nil {
                    try await self.performCheck(userInitiated: true)
                }
                guard let asset = self.availableAsset else { return }
                try await self.performInstall(asset: asset)
            } catch is CancellationError {
                // ignore
            } catch {
                self.phase = .failed
                self.statusMessage = error.localizedDescription
                self.canCheckForUpdates = true
            }
        }
    }

    // MARK: Check

    private func checkForUpdates(userInitiated: Bool) {
        guard checkTask == nil, installTask == nil else { return }
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkTask = nil }
            do {
                try await self.performCheck(userInitiated: userInitiated)
            } catch is CancellationError {
                // ignore
            } catch {
                if userInitiated || self.phase == .checking {
                    self.phase = .failed
                    self.statusMessage = error.localizedDescription
                }
                self.canCheckForUpdates = true
            }
        }
    }

    private func performCheck(userInitiated: Bool) async throws {
        phase = .checking
        statusMessage = String(localized: "Checking for updates…")
        canCheckForUpdates = false
        availableVersion = nil
        availableAsset = nil
        downloadProgress = 0

        let releases = try await Self.fetchReleases()
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        let local = Self.currentVersionString()
        guard let asset = Self.pickAsset(from: releases, includePrerelease: receiveBetaUpdates) else {
            phase = .upToDate
            statusMessage = String(localized: "No update packages found on GitHub Releases.")
            canCheckForUpdates = true
            return
        }

        if !Self.isRemoteVersion(asset.version, newerThan: local) {
            phase = .upToDate
            statusMessage = String(localized: "You're up to date.")
            canCheckForUpdates = true
            _ = userInitiated
            return
        }

        availableAsset = asset
        availableVersion = asset.version
        phase = .available
        statusMessage = String(
            format: String(localized: "Update available: %@"),
            asset.version
        )
        canCheckForUpdates = true
    }

    // MARK: Install pipeline

    private func performInstall(asset: RemoteUpdateAsset) async throws {
        phase = .downloading
        statusMessage = String(localized: "Downloading update…")
        canCheckForUpdates = false
        downloadProgress = 0

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let dmgURL = workDir.appendingPathComponent(asset.name)
        try await Self.download(url: asset.downloadURL, to: dmgURL) { [weak self] fraction in
            Task { @MainActor in
                self?.downloadProgress = fraction
            }
        }

        if let expected = asset.sha256 {
            statusMessage = String(localized: "Verifying download…")
            let actual = try Self.sha256Hex(of: dmgURL)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }
        }

        phase = .installing
        statusMessage = String(localized: "Installing update…")
        downloadProgress = 1

        let mountPoint = workDir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try await Self.run("/usr/bin/hdiutil", arguments: [
            "attach", dmgURL.path,
            "-nobrowse",
            "-readonly",
            "-mountpoint", mountPoint.path,
        ])

        defer {
            try? Self.runSync("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
        }

        guard let sourceApp = Self.findApp(in: mountPoint) else {
            throw UpdateError.appNotFoundInDMG
        }

        try? await Self.run("/usr/bin/xattr", arguments: [
            "-dr", "com.apple.quarantine", sourceApp.path,
        ])

        // Stage a copy we still own after the DMG detaches.
        let stagedApp = workDir.appendingPathComponent("Glint.app")
        if FileManager.default.fileExists(atPath: stagedApp.path) {
            try FileManager.default.removeItem(at: stagedApp)
        }
        try Self.runSync("/usr/bin/ditto", arguments: [sourceApp.path, stagedApp.path])
        try? await Self.run("/usr/bin/xattr", arguments: [
            "-dr", "com.apple.quarantine", stagedApp.path,
        ])
        try? await Self.run("/usr/bin/codesign", arguments: [
            "--force", "--deep", "--sign", "-", stagedApp.path,
        ])

        try? await Self.run("/usr/bin/hdiutil", arguments: [
            "detach", mountPoint.path, "-force",
        ])

        let destApp = Bundle.main.bundleURL
        try Self.writeAndLaunchReplaceHelper(
            stagedApp: stagedApp,
            destApp: destApp,
            workDir: workDir
        )

        phase = .installing
        statusMessage = String(localized: "Restarting…")
        try await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    // MARK: Network

    nonisolated private static func fetchReleases() async throws -> [GitHubRelease] {
        let url = URL(string:
            "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases?per_page=15"
        )!
        var request = URLRequest(url: url)
        request.setValue("Glint/\(currentVersionString())", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    nonisolated private static func download(
        url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = DownloadDelegate(destination: destination, onProgress: onProgress, continuation: cont)
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            // Retain delegate for the lifetime of the task.
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: Version helpers

    nonisolated static func currentVersionString() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// Prefer a non-draft release with a `Glint-*.dmg` asset. Newest first
    /// (GitHub returns releases reverse-chronologically).
    nonisolated fileprivate static func pickAsset(
        from releases: [GitHubRelease],
        includePrerelease: Bool
    ) -> RemoteUpdateAsset? {
        for rel in releases {
            if rel.draft { continue }
            if rel.prerelease && !includePrerelease { continue }
            guard let asset = rel.assets.first(where: {
                $0.name.hasPrefix("Glint-") && $0.name.hasSuffix(".dmg")
            }) else { continue }
            let version = versionFrom(assetName: asset.name, tag: rel.tagName, releaseName: rel.name)
            let sha = asset.digest.flatMap { dig -> String? in
                let prefix = "sha256:"
                if dig.lowercased().hasPrefix(prefix) {
                    return String(dig.dropFirst(prefix.count))
                }
                return nil
            }
            return RemoteUpdateAsset(
                name: asset.name,
                version: version,
                downloadURL: asset.browserDownloadURL,
                sha256: sha
            )
        }
        return nil
    }

    /// `Glint-0.1.27-dev.4.dmg` → `0.1.27-dev.4`; fall back to tag / name.
    nonisolated static func versionFrom(assetName: String, tag: String, releaseName: String?) -> String {
        if assetName.hasPrefix("Glint-"), assetName.hasSuffix(".dmg") {
            let v = String(assetName.dropFirst("Glint-".count).dropLast(".dmg".count))
            if !v.isEmpty { return v }
        }
        if let releaseName, releaseName.lowercased().hasPrefix("glint ") {
            return String(releaseName.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        if tag.hasPrefix("dmg-") {
            // dmg-0.1.27.4 → 0.1.27-dev.4
            let rest = String(tag.dropFirst(4))
            if let lastDot = rest.lastIndex(of: ".") {
                let base = String(rest[..<lastDot])
                let n = String(rest[rest.index(after: lastDot)...])
                return "\(base)-dev.\(n)"
            }
        }
        return tag
    }

    /// True when `remote` should be offered as an upgrade over `local`.
    nonisolated static func isRemoteVersion(_ remote: String, newerThan local: String) -> Bool {
        let r = parseVersion(remote)
        let l = parseVersion(local)
        // Unknown / placeholder local ("dev", "0", empty) → always offer.
        if l.numbers.isEmpty || local == "dev" || local == "0" || local == "0.0" {
            return true
        }
        let maxCount = max(r.numbers.count, l.numbers.count)
        for i in 0..<maxCount {
            let rv = i < r.numbers.count ? r.numbers[i] : 0
            let lv = i < l.numbers.count ? l.numbers[i] : 0
            if rv != lv { return rv > lv }
        }
        if r.devBuild != l.devBuild {
            return r.devBuild > l.devBuild
        }
        return false
    }

    struct ParsedVersion: Equatable {
        var numbers: [Int]
        var devBuild: Int
    }

    /// Parses `0.1.27-dev.4`, `0.1.27`, `dmg-0.1.27.4`, plain `dev`.
    nonisolated static func parseVersion(_ raw: String) -> ParsedVersion {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("dmg-") { s = String(s.dropFirst(4)) }
        if s.lowercased().hasPrefix("v") { s = String(s.dropFirst()) }

        var devBuild = 0
        if let range = s.range(of: #"-dev\.(\d+)"#, options: .regularExpression) {
            let numPart = s[range].drop(while: { !$0.isNumber })
            devBuild = Int(numPart) ?? 0
            s = String(s[..<range.lowerBound])
        } else if s.filter({ $0 == "." }).count >= 3,
                  let range = s.range(of: #"\.(\d+)$"#, options: .regularExpression) {
            // tag form 0.1.27.4 → base 0.1.27, dev 4
            let numPart = s[range].drop(while: { !$0.isNumber })
            devBuild = Int(numPart) ?? 0
            s = String(s[..<range.lowerBound])
        }

        let numbers = s.split(separator: ".").compactMap { Int($0) }
        return ParsedVersion(numbers: numbers, devBuild: devBuild)
    }

    // MARK: File helpers

    nonisolated private static func findApp(in mountPoint: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        if let direct = items.first(where: { $0.lastPathComponent == "Glint.app" }) {
            return direct
        }
        return items.first(where: { $0.pathExtension == "app" })
    }

    nonisolated private static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Spawns a detached shell helper that waits for this process to exit,
    /// swaps the app bundle, strips quarantine, and reopens Glint.
    nonisolated private static func writeAndLaunchReplaceHelper(
        stagedApp: URL,
        destApp: URL,
        workDir: URL
    ) throws {
        let scriptURL = workDir.appendingPathComponent("replace.sh")
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -euo pipefail
        SRC=\(shellQuote(stagedApp.path))
        DEST=\(shellQuote(destApp.path))
        WORK=\(shellQuote(workDir.path))
        TARGET_PID=\(ourPID)
        LOG="$WORK/replace.log"
        exec >>"$LOG" 2>&1
        echo "Glint replace helper starting pid=$$ waiting for $TARGET_PID"
        for i in $(seq 1 150); do
          if ! kill -0 "$TARGET_PID" 2>/dev/null; then
            break
          fi
          sleep 0.2
        done
        sleep 0.5
        if [ ! -d "$SRC" ]; then
          echo "staged app missing: $SRC"
          exit 1
        fi
        BACKUP="${DEST}.glint-update-backup"
        rm -rf "$BACKUP"
        if [ -d "$DEST" ]; then
          mv "$DEST" "$BACKUP"
        fi
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        /usr/bin/codesign --force --deep --sign - "$DEST" 2>/dev/null || true
        rm -rf "$BACKUP"
        /usr/bin/open "$DEST"
        ( sleep 8; rm -rf "$WORK" ) &
        echo "done"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        try process.run()
    }

    nonisolated private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    nonisolated private static func run(
        _ launchPath: String,
        arguments: [String]
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runSync(launchPath, arguments: arguments)
        }.value
    }

    @discardableResult
    nonisolated private static func runSync(
        _ launchPath: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw UpdateError.commandFailed(
                launchPath,
                process.terminationStatus,
                stderr.isEmpty ? stdout : stderr
            )
        }
        return stdout
    }
}

// MARK: - Download delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onProgress: @Sendable (Double) -> Void
    let continuation: CheckedContinuation<Void, Error>
    var session: URLSession?
    private var finished = false

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                finish(.failure(UpdateError.httpStatus(http.statusCode)))
                return
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            onProgress(1)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case httpStatus(Int)
    case checksumMismatch
    case appNotFoundInDMG
    case commandFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return String(
                format: String(localized: "GitHub returned HTTP %lld."),
                Int64(code)
            )
        case .checksumMismatch:
            return String(localized: "Download checksum mismatch. Please try again.")
        case .appNotFoundInDMG:
            return String(localized: "Couldn't find Glint.app inside the downloaded DMG.")
        case .commandFailed(let cmd, let status, let detail):
            let snippet = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty {
                return String(
                    format: String(localized: "%@ failed (exit %lld)."),
                    cmd, Int64(status)
                )
            }
            return String(
                format: String(localized: "%@ failed (exit %lld): %@"),
                cmd, Int64(status), snippet
            )
        }
    }
}
