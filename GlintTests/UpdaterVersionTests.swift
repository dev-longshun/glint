import XCTest
@testable import Glint

final class UpdaterVersionTests: XCTestCase {
    func testParseDevVersion() {
        let p = UpdaterController.parseVersion("0.1.27-dev.4")
        XCTAssertEqual(p.numbers, [0, 1, 27])
        XCTAssertEqual(p.devBuild, 4)
    }

    func testParseTagForm() {
        let p = UpdaterController.parseVersion("dmg-0.1.27.4")
        XCTAssertEqual(p.numbers, [0, 1, 27])
        XCTAssertEqual(p.devBuild, 4)
    }

    func testRemoteNewerDev() {
        XCTAssertTrue(UpdaterController.isRemoteVersion("0.1.27-dev.5", newerThan: "0.1.27-dev.4"))
        XCTAssertFalse(UpdaterController.isRemoteVersion("0.1.27-dev.4", newerThan: "0.1.27-dev.4"))
        XCTAssertFalse(UpdaterController.isRemoteVersion("0.1.27-dev.3", newerThan: "0.1.27-dev.4"))
    }

    func testPlaceholderLocalAlwaysOffers() {
        XCTAssertTrue(UpdaterController.isRemoteVersion("0.1.27-dev.1", newerThan: "dev"))
        XCTAssertTrue(UpdaterController.isRemoteVersion("0.1.27-dev.1", newerThan: "0"))
    }

    func testVersionFromAssetName() {
        let v = UpdaterController.versionFrom(
            assetName: "Glint-0.1.27-dev.4.dmg",
            tag: "dmg-0.1.27.4",
            releaseName: "Glint 0.1.27-dev.4"
        )
        XCTAssertEqual(v, "0.1.27-dev.4")
    }
}
