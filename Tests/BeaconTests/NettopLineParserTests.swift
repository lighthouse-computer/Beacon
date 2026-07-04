import XCTest
@testable import Beacon

final class NettopLineParserTests: XCTestCase {
    // MARK: - Reject Cases

    func test_emptyLine_returnsNil() {
        XCTAssertNil(NettopLineParser.parse(line: ""))
        XCTAssertNil(NettopLineParser.parse(line: "   "))
    }

    func test_headerLine_returnsNil() {
        let header = "time,,interface,state,bytes_in,bytes_out,bytes_in_dupe,bytes_in_ooo,bytes_out_re,rtt_avg"
        XCTAssertNil(NettopLineParser.parse(line: header))
    }

    func test_lineWithTooFewColumns_returnsNil() {
        XCTAssertNil(NettopLineParser.parse(line: "12:00:00.0,foo.123,,,500"))
    }

    func test_connectionSubRow_emptyProcField_returnsNil() {
        // Sub-rows in -P mode have an empty col[1].
        let sub = "12:00:00.0,,tcp,Listen,10,20,0,0,0,0"
        XCTAssertNil(NettopLineParser.parse(line: sub))
    }

    func test_procFieldWithoutDot_returnsNil() {
        let bad = "12:00:00.0,nopiderehere,,,100,200,0,0,0,0"
        XCTAssertNil(NettopLineParser.parse(line: bad))
    }

    func test_nonNumericByteColumns_returnsNil() {
        let bad = "12:00:00.0,App.123,,,not_a_number,200,0,0,0,0"
        XCTAssertNil(NettopLineParser.parse(line: bad))
    }

    // MARK: - Happy Path

    func test_normalProcessRow_parses() {
        let line = "12:00:00.0,Google Chrome.42,,,123456,7890,0,0,0,0"
        let row = NettopLineParser.parse(line: line)
        XCTAssertEqual(row, ParsedNettopRow(
            pid: 42,
            processName: "Google Chrome",
            bytesIn: 123456,
            bytesOut: 7890
        ))
    }

    func test_processNameWithDots_keepsAllButLastDotAsName() {
        // Helper processes often look like "com.apple.WebKit.GPU.1234".
        let line = "12:00:00.0,com.apple.WebKit.GPU.1234,,,99,100,0,0,0,0"
        let row = NettopLineParser.parse(line: line)
        XCTAssertEqual(row?.pid, 1234)
        XCTAssertEqual(row?.processName, "com.apple.WebKit.GPU")
    }

    func test_whitespaceInByteColumns_isTolerated() {
        let line = "12:00:00.0,App.7,,, 500 , 600 ,0,0,0,0"
        let row = NettopLineParser.parse(line: line)
        XCTAssertEqual(row?.bytesIn, 500)
        XCTAssertEqual(row?.bytesOut, 600)
    }

    func test_largeByteValues_parseWithoutOverflow() {
        // ~5 GB, well within UInt64.
        let line = "12:00:00.0,App.1,,,5368709120,1073741824,0,0,0,0"
        let row = NettopLineParser.parse(line: line)
        XCTAssertEqual(row?.bytesIn, 5_368_709_120)
        XCTAssertEqual(row?.bytesOut, 1_073_741_824)
    }

    // MARK: - Connection sub-rows (no -P)

    func test_tcp4Connection_parses() {
        let line = "12:00:00.0,tcp4 100.96.0.1:59215<->17.188.185.132:5223,utun4,Established,29316,292993,24,0,36538,23.16 ms,131072,139264,RD,-,cubic,-,-,-,-,so,"
        guard case .connection(let c)? = NettopLineParser.parseRow(line: line) else {
            return XCTFail("expected connection row")
        }
        XCTAssertEqual(c.proto, "tcp4")
        XCTAssertEqual(c.localIP, "100.96.0.1")
        XCTAssertEqual(c.localPort, 59215)
        XCTAssertEqual(c.remoteIP, "17.188.185.132")
        XCTAssertEqual(c.remotePort, 5223)
        XCTAssertEqual(c.bytesIn, 29316)
        XCTAssertEqual(c.bytesOut, 292993)
    }

    func test_tcp6Connection_parsesAddressWithColons() {
        // IPv6 uses `.` for the port separator since `:` is part of the address.
        let line = "12:00:00.0,tcp6 2606:4700:cf1:1000::1.64984<->2606:4700:4700::1111.443,utun4,Established,1451,2989,0,0,0,15.53 ms,131072,139264,BE,-,cubic,-,-,-,-,so,"
        guard case .connection(let c)? = NettopLineParser.parseRow(line: line) else {
            return XCTFail("expected connection row")
        }
        XCTAssertEqual(c.proto, "tcp6")
        XCTAssertEqual(c.localIP, "2606:4700:cf1:1000::1")
        XCTAssertEqual(c.localPort, 64984)
        XCTAssertEqual(c.remoteIP, "2606:4700:4700::1111")
        XCTAssertEqual(c.remotePort, 443)
    }

    func test_udpWildcardListen_isDroppedBecauseBytesBlank() {
        // Wildcard listen sub-rows have blank bytes_in/bytes_out columns; the
        // parser returns nil so they don't fight for attention in the UI.
        let line = "12:00:00.0,udp4 *:5353<->*:*,en0,,,,,,,,786896,,CTL,,,,,,,so,"
        XCTAssertNil(NettopLineParser.parseRow(line: line))
    }

    func test_processRow_routesThroughParseRow_asProcess() {
        let line = "12:00:00.0,Google Chrome.42,,,123456,7890,0,0,0,0"
        guard case .process(let p)? = NettopLineParser.parseRow(line: line) else {
            return XCTFail("expected process row")
        }
        XCTAssertEqual(p.processName, "Google Chrome")
        XCTAssertEqual(p.pid, 42)
    }
}
