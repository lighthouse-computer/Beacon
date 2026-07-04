import XCTest
@testable import Beacon

final class FormatUtilityTests: XCTestCase {
    // MARK: - formatSpeed

    func test_formatSpeed_zero() {
        XCTAssertEqual(FormatUtility.formatSpeed(0), "0 B/s")
        XCTAssertEqual(FormatUtility.formatSpeed(-1), "0 B/s")
    }

    func test_formatSpeed_nonFinite_rendersZeroNotNaN() {
        // A degenerate upstream rate (NaN/±inf from a divide on a bad dt) must
        // never surface as "nan B/s" / "inf GB/s".
        XCTAssertEqual(FormatUtility.formatSpeed(.nan), "0 B/s")
        XCTAssertEqual(FormatUtility.formatSpeed(.infinity), "0 B/s")
        XCTAssertEqual(FormatUtility.formatSpeed(-.infinity), "0 B/s")
    }

    func test_formatSpeed_bytesPerSecond_noDecimals() {
        XCTAssertEqual(FormatUtility.formatSpeed(7), "7 B/s")
        XCTAssertEqual(FormatUtility.formatSpeed(512), "512 B/s")
    }

    func test_formatSpeed_kilobytesPerSecond_oneDecimal() {
        XCTAssertEqual(FormatUtility.formatSpeed(2048), "2.0 KB/s")
        XCTAssertEqual(FormatUtility.formatSpeed(1024 * 4.5), "4.5 KB/s")
    }

    func test_formatSpeed_megabytesPerSecond_twoDecimals() {
        let twoMB = 1024.0 * 1024.0 * 2.5
        XCTAssertEqual(FormatUtility.formatSpeed(twoMB), "2.50 MB/s")
    }

    func test_formatSpeed_terabytesPerSecond_twoDecimals() {
        let oneTb = 1024.0 * 1024.0 * 1024.0 * 1024.0
        XCTAssertEqual(FormatUtility.formatSpeed(oneTb), "1.00 TB/s")
    }

    func test_formatSpeed_capsAtTerabytes() {
        let onePb = 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0
        // Largest unit in the table is now TB; PB-magnitude values still render in TB.
        XCTAssertTrue(FormatUtility.formatSpeed(onePb).hasSuffix(" TB/s"))
    }

    // MARK: - formatBytes

    func test_formatBytes_zero() {
        XCTAssertEqual(FormatUtility.formatBytes(0), "0 B")
    }

    func test_formatBytes_units() {
        XCTAssertEqual(FormatUtility.formatBytes(900), "900 B")
        XCTAssertEqual(FormatUtility.formatBytes(2048), "2 KB")
        XCTAssertEqual(FormatUtility.formatBytes(UInt64(1.5 * 1024 * 1024)), "1.5 MB")
        XCTAssertEqual(FormatUtility.formatBytes(UInt64(3.2 * 1024 * 1024 * 1024)), "3.2 GB")
    }
}
