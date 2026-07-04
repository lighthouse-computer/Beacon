import XCTest
@testable import Beacon

final class ProcessTrackerTests: XCTestCase {
    /// Two snapshots one second apart for a single PID. Verifies:
    ///   - first snapshot establishes baseline (no speed yet)
    ///   - second snapshot computes speed from delta
    ///   - cumulative session bytes accumulate
    func test_singlePid_deltaProducesSpeed() {
        let tracker = ProcessTracker()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1.0)

        let s0 = [ProcessSample(pid: 1234, processName: "ExampleApp",
                                 bytesIn: 1000, bytesOut: 500)]
        let s1 = [ProcessSample(pid: 1234, processName: "ExampleApp",
                                 bytesIn: 11_000, bytesOut: 1500)]

        _ = tracker.ingest(snapshot: s0, snapshotTime: t0)
        let result = tracker.ingest(snapshot: s1, snapshotTime: t1)

        XCTAssertEqual(result.count, 1)
        let app = result[0]
        XCTAssertEqual(app.downloadSpeed, 10_000, accuracy: 1)
        XCTAssertEqual(app.uploadSpeed, 1_000, accuracy: 1)
        XCTAssertEqual(app.totalBytesIn, 10_000)
        XCTAssertEqual(app.totalBytesOut, 1_000)
    }

    /// PID delivers a decreasing byte count (socket churn / counter reset).
    /// Tracker must treat that as zero delta — never go negative or overflow.
    func test_decreasingBytes_isClampedToZero() {
        let tracker = ProcessTracker()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1.0)

        _ = tracker.ingest(
            snapshot: [ProcessSample(pid: 99, processName: "Foo",
                                     bytesIn: 5000, bytesOut: 5000)],
            snapshotTime: t0
        )
        let result = tracker.ingest(
            snapshot: [ProcessSample(pid: 99, processName: "Foo",
                                     bytesIn: 100, bytesOut: 100)],
            snapshotTime: t1
        )

        XCTAssertEqual(result[0].downloadSpeed, 0)
        XCTAssertEqual(result[0].uploadSpeed, 0)
        XCTAssertEqual(result[0].totalBytesIn, 0)
        XCTAssertEqual(result[0].totalBytesOut, 0)
    }

    /// Two PIDs with the same processName must collapse into one row when neither
    /// resolves to a bundle id (the aggregation key falls back to displayName).
    func test_multiplePids_sameProcessName_aggregate() {
        let tracker = ProcessTracker()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1.0)

        _ = tracker.ingest(snapshot: [
            ProcessSample(pid: 1, processName: "Helper", bytesIn: 0, bytesOut: 0),
            ProcessSample(pid: 2, processName: "Helper", bytesIn: 0, bytesOut: 0),
        ], snapshotTime: t0)
        let result = tracker.ingest(snapshot: [
            ProcessSample(pid: 1, processName: "Helper", bytesIn: 1000, bytesOut: 0),
            ProcessSample(pid: 2, processName: "Helper", bytesIn: 2000, bytesOut: 0),
        ], snapshotTime: t1)

        // PID 1 and PID 2 may or may not collapse depending on whether
        // NSRunningApplication resolves them to a bundle. In a test environment
        // they typically don't — so they share the fallback displayName ("Helper")
        // and collapse to one row.
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].totalBytesIn, 3000)
        XCTAssertEqual(Set(result[0].pids), Set([1, 2]))
    }

    /// Outbound flows group by the SERVICE-side (remote) port, not the
    /// ephemeral local port. Two HTTPS connections from different local ports to
    /// two different servers (both remote :443) collapse into ONE tcp:443
    /// connection carrying two distinct remote peers, sorted by bytes desc.
    func test_connections_groupByServicePort_withRemoteRollup() {
        let tracker = ProcessTracker()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1)

        // Baseline (0 bytes) establishes the flows. Local ports are ephemeral;
        // the service is the remote :443.
        _ = tracker.ingest(snapshot: [
            ProcessSample(pid: 100, processName: "App", bytesIn: 0, bytesOut: 0)
        ], connections: [
            ConnectionSample(pid: 100, proto: "tcp4", localIP: "10.0.0.1",
                             localPort: 50001, remoteIP: "1.1.1.1", remotePort: 443,
                             bytesIn: 0, bytesOut: 0),
            ConnectionSample(pid: 100, proto: "tcp4", localIP: "10.0.0.1",
                             localPort: 50002, remoteIP: "8.8.8.8", remotePort: 443,
                             bytesIn: 0, bytesOut: 0),
        ], snapshotTime: t0)

        // Second tick — both connections moved bytes.
        let usages = tracker.ingest(snapshot: [
            ProcessSample(pid: 100, processName: "App", bytesIn: 1500, bytesOut: 200)
        ], connections: [
            ConnectionSample(pid: 100, proto: "tcp4", localIP: "10.0.0.1",
                             localPort: 50001, remoteIP: "1.1.1.1", remotePort: 443,
                             bytesIn: 1000, bytesOut: 100),
            ConnectionSample(pid: 100, proto: "tcp4", localIP: "10.0.0.1",
                             localPort: 50002, remoteIP: "8.8.8.8", remotePort: 443,
                             bytesIn:  500, bytesOut: 100),
        ], snapshotTime: t1)

        let app = usages.first(where: { $0.pids.contains(100) })!
        XCTAssertEqual(app.connections.count, 1, "both flows share service port 443")
        let conn = app.connections[0]
        XCTAssertEqual(conn.port, 443)
        XCTAssertEqual(conn.proto, "tcp")               // IP-family digit dropped
        XCTAssertEqual(conn.service, "https")
        XCTAssertEqual(conn.bytesIn, 1500)
        XCTAssertEqual(conn.bytesOut, 200)
        XCTAssertEqual(conn.remotes.count, 2)
        XCTAssertEqual(conn.remotes[0].ip, "1.1.1.1",
                       "highest-bytes remote should be first")
    }

    /// A PID absent beyond the retention grace window must be evicted so the
    /// tracker's per-PID maps stay bounded over a long-running session.
    func test_stalePid_isPrunedAfterGraceWindow() {
        let tracker = ProcessTracker()
        let t0 = Date()

        _ = tracker.ingest(snapshot: [
            ProcessSample(pid: 99, processName: "dl", bytesIn: 1_000_000, bytesOut: 0)
        ], snapshotTime: t0)

        // 200s later (> the 120s grace) and PID 99 is gone.
        let later = t0.addingTimeInterval(200)
        let result = tracker.ingest(snapshot: [
            ProcessSample(pid: 1, processName: "other", bytesIn: 50, bytesOut: 0)
        ], snapshotTime: later)

        XCTAssertNil(result.first(where: { $0.pids.contains(99) }),
                     "stale PID should be pruned once absent beyond the grace window")
        XCTAssertNotNil(result.first(where: { $0.pids.contains(1) }),
                        "the live PID should still be reported")
    }

    /// PID reuse: the kernel recycles a PID into a different process whose
    /// cumulative byte counters restart near zero. The new process must NOT
    /// inherit the dead process's session totals. Detected by command-change
    /// AND a counter regression. (pid 31337 is well above the live PID range on
    /// a dev box, so resolveIdentity falls back to the nettop name.)
    func test_pidReuse_resetsCountersForNewProcess() {
        let tracker = ProcessTracker()
        let t0 = Date()

        // "curl" runs and accumulates 4000 bytes in over two ticks.
        _ = tracker.ingest(
            snapshot: [ProcessSample(pid: 31337, processName: "curl",
                                     bytesIn: 1000, bytesOut: 0)],
            snapshotTime: t0
        )
        let curl = tracker.ingest(
            snapshot: [ProcessSample(pid: 31337, processName: "curl",
                                     bytesIn: 5000, bytesOut: 0)],
            snapshotTime: t0.addingTimeInterval(1.0)
        )
        XCTAssertEqual(curl.first?.totalBytesIn, 4000)

        // pid 31337 recycled into "python", reporting its own (lower) counter.
        // This is the new process's baseline tick.
        let reused = tracker.ingest(
            snapshot: [ProcessSample(pid: 31337, processName: "python",
                                     bytesIn: 200, bytesOut: 0)],
            snapshotTime: t0.addingTimeInterval(2.0)
        )
        XCTAssertEqual(reused.count, 1)
        XCTAssertEqual(reused[0].displayName, "python")
        XCTAssertEqual(reused[0].totalBytesIn, 0,
                       "recycled PID must not inherit the prior process's bytes")

        // From its own baseline the new process accumulates correctly.
        let python = tracker.ingest(
            snapshot: [ProcessSample(pid: 31337, processName: "python",
                                     bytesIn: 700, bytesOut: 0)],
            snapshotTime: t0.addingTimeInterval(3.0)
        )
        XCTAssertEqual(python.first?.totalBytesIn, 500)
    }

    /// A live process that exec()s a new image keeps its PID and its
    /// monotonically-climbing counters; only the reported name changes. That is
    /// NOT a PID reuse — counters must keep accumulating, not reset (otherwise
    /// the in-flight delta is lost and usage is undercounted).
    func test_pidExecWithoutFork_keepsAccumulating() {
        let tracker = ProcessTracker()
        let t0 = Date()

        _ = tracker.ingest(
            snapshot: [ProcessSample(pid: 31338, processName: "bash",
                                     bytesIn: 1000, bytesOut: 0)],
            snapshotTime: t0
        )
        _ = tracker.ingest(
            snapshot: [ProcessSample(pid: 31338, processName: "bash",
                                     bytesIn: 3000, bytesOut: 0)],
            snapshotTime: t0.addingTimeInterval(1.0)
        )
        // exec(): name changes to "ssh" but the counter keeps CLIMBING (5000 >
        // 3000) — same kernel process, so its 2000 session bytes survive and
        // the new delta is added.
        let execed = tracker.ingest(
            snapshot: [ProcessSample(pid: 31338, processName: "ssh",
                                     bytesIn: 5000, bytesOut: 0)],
            snapshotTime: t0.addingTimeInterval(2.0)
        )
        XCTAssertEqual(execed.count, 1)
        XCTAssertEqual(execed[0].totalBytesIn, 4000,
                       "a live exec (climbing counter) must not reset session bytes")
    }

    /// Guard against over-invalidation: a stable PID reporting the same name
    /// every tick keeps accumulating across many ticks.
    func test_stablePid_keepsAccumulating() {
        let tracker = ProcessTracker()
        let t0 = Date()

        _ = tracker.ingest(
            snapshot: [ProcessSample(pid: 31339, processName: "rsync",
                                     bytesIn: 1000, bytesOut: 0)],
            snapshotTime: t0
        )
        var last: [AppNetworkUsage] = []
        for i in 1...5 {
            last = tracker.ingest(
                snapshot: [ProcessSample(pid: 31339, processName: "rsync",
                                         bytesIn: 1000 + UInt64(i) * 1000, bytesOut: 0)],
                snapshotTime: t0.addingTimeInterval(Double(i))
            )
        }
        XCTAssertEqual(last.first?.totalBytesIn, 5000)
    }
}
