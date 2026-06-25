import Foundation

/// One-off launch-time tracer used to pin down the macOS 15.x StateObject
/// init crash (issue #43). Writes every mark to BOTH NSLog (so Console.app
/// catches it live) AND a per-launch file under `~/Library/Logs/Glint/`
/// (so a crash an instant later still leaves a complete trail on disk).
///
/// This file is DIAGNOSTIC SCAFFOLDING — only ship it in the `*-diag.*`
/// builds we hand to reporters. Remove once the offending init is found.
enum LaunchDiagnostic {
    /// Per-launch log file: `~/Library/Logs/Glint/launch-diagnostic-<ISO>.log`.
    /// One file per launch makes "find the run that crashed" obvious.
    private static let logURL: URL? = {
        let fm = FileManager.default
        guard let lib = try? fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = lib.appendingPathComponent("Logs/Glint", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("launch-diagnostic-\(stamp()).log",
                                          isDirectory: false)
    }()

    /// Opened lazily; kept open for the process lifetime. nil if disk write
    /// failed (we still NSLog so Console catches the trace).
    private static let fileHandle: FileHandle? = {
        guard let url = logURL else { return nil }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    /// Serializes file writes so two threads can't interleave a line.
    private static let queue = DispatchQueue(label: "glint.launch-diagnostic")

    static func mark(_ tag: String) {
        let line = "\(stamp()) [\(threadLabel())] \(tag)\n"
        NSLog("[glint.diag] %@", line.trimmingCharacters(in: .newlines))
        queue.sync {
            if let data = line.data(using: .utf8), let fh = fileHandle {
                try? fh.write(contentsOf: data)
            }
        }
    }

    private static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private static func threadLabel() -> String {
        Thread.isMainThread ? "main" : (Thread.current.name ?? "bg")
    }
}
