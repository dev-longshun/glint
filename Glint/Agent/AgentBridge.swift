import Foundation
import Darwin

/// Listens on a per-user Unix domain socket. CLI agents (Claude Code,
/// Codex, …) post one JSON line per hook event:
///
///     {"pane":"<workspace-uuid>:<pane-seq>","hook":"UserPromptSubmit"}
///
/// The bridge parses, posts `.glintAgentEvent` on the main queue, and
/// `WorkspaceStore` translates it into pane state.
final class AgentBridge {
    static let shared = AgentBridge()

    private(set) var socketPath: String = ""
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "glint.agent.bridge", qos: .utility)

    private init() {}

    /// Bind + listen. Path is short on purpose (sun_path is 104 chars on Darwin).
    func start() {
        let path = "/tmp/glint-\(getuid())-agent.sock"
        socketPath = path

        // Reap any stale socket from a previous run.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[glint] agent socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                let dstPtr = dst.baseAddress!.assumingMemoryBound(to: CChar.self)
                _ = strlcpy(dstPtr, src, dst.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, addrLen)
            }
        }
        guard bindRC == 0 else {
            NSLog("[glint] agent bind(\(path)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("[glint] agent listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
        NSLog("[glint] agent bridge listening on \(path)")
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in self?.serve(fd: client) }
    }

    private func serve(fd: Int32) {
        defer { close(fd) }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = tmp.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n <= 0 { break }
            buf.append(tmp, count: n)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                handle(line: line)
            }
            // Sanity cap so a hostile/buggy client can't OOM us.
            if buf.count > (1 << 20) { break }
        }
    }

    private struct HookEnvelope: Decodable {
        let pane: String
        let hook: String
        let agent: String?
    }

    private func handle(line: Data) {
        guard let env = try? JSONDecoder().decode(HookEnvelope.self, from: line) else {
            NSLog("[glint] agent: malformed hook line (\(line.count) bytes)")
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .glintAgentEvent,
                object: nil,
                userInfo: [
                    "pane": env.pane,
                    "hook": env.hook,
                    "agent": env.agent ?? "claude",
                ]
            )
        }
    }
}

extension Notification.Name {
    static let glintAgentEvent = Notification.Name("glint.agent.event")
}
