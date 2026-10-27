import XCTest
@testable import Beacon

final class LaunchArgsTests: XCTestCase {
    func test_versionFlagAlone_isRecognised() {
        XCTAssertTrue(BeaconMain.wantsVersion(["--version"]))
    }

    func test_noArgsOrOtherArgs_arePlainLaunch() {
        XCTAssertFalse(BeaconMain.wantsVersion([]))
        XCTAssertFalse(BeaconMain.wantsVersion(["--other"]))
        XCTAssertFalse(BeaconMain.wantsVersion(["--version", "x"]))
        XCTAssertFalse(BeaconMain.wantsVersion(["-NSDocumentRevisionsDebugMode", "YES"]))
    }
}
