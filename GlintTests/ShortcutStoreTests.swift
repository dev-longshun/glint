import XCTest
@testable import Glint

final class ShortcutStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ShortcutStore.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ShortcutStore.defaultsKey)
        super.tearDown()
    }

    @MainActor
    func testDefaultsIncludeDeleteAndArchive() {
        let store = ShortcutStore()
        XCTAssertEqual(store.chord(for: .deleteWorkspace).key, "backspace")
        XCTAssertTrue(store.chord(for: .deleteWorkspace).command)
        XCTAssertEqual(store.chord(for: .archiveWorkspace).key, "0")
        XCTAssertTrue(store.chord(for: .archiveWorkspace).command)
        XCTAssertTrue(store.chord(for: .workspace1).option)
        XCTAssertFalse(store.chord(for: .workspace1).command)
    }

    @MainActor
    func testSetAndConflict() {
        let store = ShortcutStore()
        let chord = KeyChord(key: "n", command: true) // default new workspace
        let conflict = store.set(.copyPath, chord: chord)
        XCTAssertEqual(conflict, .newWorkspace)
        XCTAssertFalse(store.isCustomized(.copyPath))

        let ok = KeyChord(key: "k", command: true, shift: true)
        XCTAssertNil(store.set(.copyPath, chord: ok))
        XCTAssertTrue(store.isCustomized(.copyPath))
        XCTAssertEqual(store.chord(for: .copyPath), ok)
    }

    @MainActor
    func testResetRestoresDefault() {
        let store = ShortcutStore()
        _ = store.set(.newWorkspace, chord: KeyChord(key: "e", command: true))
        XCTAssertTrue(store.isCustomized(.newWorkspace))
        store.reset(.newWorkspace)
        XCTAssertFalse(store.isCustomized(.newWorkspace))
        XCTAssertEqual(store.chord(for: .newWorkspace), ShortcutStore.defaultChord(for: .newWorkspace))
    }

    @MainActor
    func testPersistenceRoundTrip() {
        let store = ShortcutStore()
        _ = store.set(.archiveWorkspace, chord: KeyChord(key: "9", command: true, shift: true))

        let reloaded = ShortcutStore()
        XCTAssertEqual(reloaded.chord(for: .archiveWorkspace).key, "9")
        XCTAssertTrue(reloaded.chord(for: .archiveWorkspace).shift)
        XCTAssertTrue(reloaded.isCustomized(.archiveWorkspace))
    }

    func testKeyChordDisplayCaps() {
        let c = KeyChord(key: "backspace", command: true)
        XCTAssertEqual(c.displayCaps, ["⌘", "⌫"])
        let o = KeyChord(key: "1", option: true)
        XCTAssertEqual(o.displayCaps, ["⌥", "1"])
    }

    func testCodableRoundTrip() throws {
        let original = KeyChord(key: "p", command: true, shift: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyChord.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
