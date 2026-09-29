#!/usr/bin/env python3
"""Run production selection/arbitration methods with deterministic snapshot/queue stubs.

No sockets or running Glint instance are needed. Method bodies are extracted
verbatim so this tests the actual lifecycle, including when revisions are recorded.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Glint/WebRemote/WebRemoteServer.swift").read_text()


def method(name):
    match = re.search(r"^    (?:private |fileprivate |static )*func " + name + r"\(", source, re.M)
    if match is None:
        raise RuntimeError(f"Missing production method: {name}")
    # Server methods end at their class-level indentation.
    end = source.index("\n    }", match.end()) + len("\n    }")
    return source[match.start():end].replace("private func", "func").replace("fileprivate func", "func")


methods = [
    "panesToReconcileWhenSelecting", "isCurrentPaneSelection", "selectPane",
    "finishSelectionFailure", "resizePane", "removeClientLocked",
    "recordTerminalSizeLocked", "reconcileTerminalSizeLocked",
]
if "func shouldReleaseTerminalSize(" in source:
    methods.append("shouldReleaseTerminalSize")

stub = r'''
import Foundation

// Explicit FIFO drains preserve the server/main queue boundary without sleeps.
final class DispatchQueue {
    static let main = DispatchQueue()
    var jobs: [() -> Void] = []
    func async(execute: @escaping () -> Void) { jobs.append(execute) }
    func drain() { while !jobs.isEmpty { jobs.removeFirst()() } }
}
struct WebRemoteTerminalSize: Equatable { let columns: Int; let rows: Int }
struct Snapshot { let outputSequence: UInt64 = 0; let payload = Data() }
enum SnapshotResult { case success(Snapshot), failure(String) }
struct WebRemoteOutputBuffer {
    init(byteLimit: Int) {}
    mutating func take(after: UInt64? = nil) -> Data { Data() }
}
final class WorkspaceStore {
    static var current: WorkspaceStore? = WorkspaceStore()
    var grids: [String: WebRemoteTerminalSize] = [:]
    var snapshots: [(SnapshotResult) -> Void] = []
    func controlFocus(pane: String, activateApp: Bool) -> String? { nil }
    func webRemoteTerminalSnapshot(pane: String, size: WebRemoteTerminalSize,
                                   completion: @escaping (SnapshotResult) -> Void) {
        grids[pane] = size
        snapshots.append(completion)
    }
    func webRemoteSetTerminalSize(pane: String, size: WebRemoteTerminalSize) -> String? {
        grids[pane] = size
        return nil
    }
    func webRemoteReleaseTerminalSize(pane: String) { grids.removeValue(forKey: pane) }
}
final class WebRemoteClientConnection {
    var authenticated = true
    var subscribedPane: String?
    var pendingPane: String?
    var paneSelectionGeneration: UInt64 = 0
    var pendingSelectionOutput = WebRemoteOutputBuffer(byteLimit: 0)
    var terminalSize: WebRemoteTerminalSize?
    var terminalSizeRevision: UInt64 = 0
    func cancel() {}
    func sendTerminalOutput(_ data: Data, pane: String) -> Bool { true }
}
final class WebRemoteServer {
    static let maxSelectionOutputBytes = 1024
    let queue = DispatchQueue()
    var clients: [UUID: WebRemoteClientConnection] = [:]
    var terminalSizeRevision: UInt64 = 0
    func updateSubscribedPanesLocked() {}
    func sendJSON(_ object: [String: Any], to: UUID) {}
    func sendError(_ error: String, to: UUID) {}
    func dropSlowClientLocked(_ id: UUID) { removeClientLocked(id, cancelConnection: true) }
    // PRODUCTION_METHODS
}

let narrow = WebRemoteTerminalSize(columns: 80, rows: 24)
let wide = WebRemoteTerminalSize(columns: 120, rows: 40)
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); failures += 1 }
}
func drain(_ server: WebRemoteServer) {
    while !DispatchQueue.main.jobs.isEmpty || !server.queue.jobs.isEmpty {
        DispatchQueue.main.drain()
        server.queue.drain()
    }
}
func fixture() -> (WebRemoteServer, WorkspaceStore, UUID, UUID) {
    let server = WebRemoteServer(), store = WorkspaceStore()
    WorkspaceStore.current = store
    let a = UUID(), b = UUID()
    server.clients[a] = WebRemoteClientConnection()
    server.clients[b] = WebRemoteClientConnection()
    server.selectPane("pane", size: narrow, for: a)
    server.selectPane("pane", size: wide, for: b)
    drain(server)
    check(store.grids["pane"] == wide, "latest selection initially sets 120 columns")
    return (server, store, a, b)
}

for departure in ["disconnect", "switch", "failure"] {
    let (server, store, a, b) = fixture()
    switch departure {
    case "disconnect": server.removeClientLocked(b, cancelConnection: false)
    case "switch": server.selectPane("other", size: wide, for: b)
    default: store.snapshots[1](.failure("pane-not-ready"))
    }
    drain(server)
    check(store.grids["pane"] == narrow, "\(departure): pending A restores 80 columns")
    store.snapshots[0](.success(Snapshot()))
    drain(server)
    check(store.grids["pane"] == narrow, "\(departure): A stays at 80 after snapshot")
    if departure != "failure" {
        store.snapshots[1](.success(Snapshot()))
        drain(server)
        check(store.grids["pane"] == narrow, "\(departure): stale B callback is ignored")
    }
    server.removeClientLocked(a, cancelConnection: false)
    drain(server)
    check(store.grids["pane"] == nil, "\(departure): last owner releases grid")
}

// Completion order must not replace request order in last-request-wins arbitration.
for completionOrder in [[0, 1], [1, 0]] {
    let (server, store, _, _) = fixture()
    for index in completionOrder { store.snapshots[index](.success(Snapshot())); drain(server) }
    server.reconcileTerminalSizeLocked(for: "pane")
    drain(server)
    check(store.grids["pane"] == wide, "completion order \(completionOrder): B remains newest")
}

// An unrelated departure must not let an older subscribed request override pending B.
do {
    let (server, store, _, _) = fixture()
    store.snapshots[0](.success(Snapshot()))
    drain(server)
    let c = UUID(), client = WebRemoteClientConnection()
    client.subscribedPane = "pane"
    client.terminalSize = narrow
    server.clients[c] = client
    server.removeClientLocked(c, cancelConnection: false)
    drain(server)
    check(store.grids["pane"] == wide, "pending B wins over subscribed A")
}

// A real resize received after B's select must retain priority when B completes.
do {
    let (server, store, a, _) = fixture()
    store.snapshots[0](.success(Snapshot()))
    drain(server)
    server.resizePane("pane", size: narrow, for: a)
    drain(server)
    store.snapshots[1](.success(Snapshot()))
    drain(server)
    server.reconcileTerminalSizeLocked(for: "pane")
    drain(server)
    check(store.grids["pane"] == narrow, "newer resize wins over older snapshot completion")
}

if failures > 0 { exit(1) }
print("PASS: 7 terminal-size lifecycle scenarios")
'''

with tempfile.TemporaryDirectory(prefix="glint-web-remote-size-") as directory:
    path = Path(directory) / "main.swift"
    path.write_text(stub.replace("    // PRODUCTION_METHODS", "\n".join(map(method, methods))))
    subprocess.run(["swift", "-swift-version", "5", str(path)], check=True)
