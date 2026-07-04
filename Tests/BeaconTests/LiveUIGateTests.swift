import XCTest
@testable import Beacon

/// Covers the LiveUIGate refcount/observer contract and the store-gating
/// behavior that depends on it — the seam that gives instant popover open while
/// keeping hidden surfaces from doing per-tick work. These run on the main
/// thread (XCTest default), which the gate requires.
final class LiveUIGateTests: XCTestCase {

    /// The gate must always start each test closed. It's a process-wide
    /// singleton, so balance every retain — assert the precondition so a leak in
    /// one test can't silently corrupt another.
    override func setUp() {
        super.setUp()
        XCTAssertFalse(LiveUIGate.shared.isVisible,
                       "gate leaked open from a previous test — retains/releases unbalanced")
    }

    func test_retainRelease_togglesVisibility() {
        let gate = LiveUIGate.shared
        XCTAssertFalse(gate.isVisible)
        gate.retain()
        XCTAssertTrue(gate.isVisible)
        gate.release()
        XCTAssertFalse(gate.isVisible)
    }

    func test_refcount_staysOpenUntilLastRelease() {
        let gate = LiveUIGate.shared
        gate.retain()              // 1 — popover, say
        gate.retain()              // 2 — a chart panel
        XCTAssertTrue(gate.isVisible)
        gate.release()             // 1 — panel closed
        XCTAssertTrue(gate.isVisible, "still open while another surface holds it")
        gate.release()             // 0 — popover closed
        XCTAssertFalse(gate.isVisible)
    }

    func test_overRelease_isClampedAtZero() {
        let gate = LiveUIGate.shared
        gate.release()             // nothing held — must not go negative
        XCTAssertFalse(gate.isVisible)
        gate.retain()
        XCTAssertTrue(gate.isVisible, "one retain after an over-release still opens cleanly")
        gate.release()
        XCTAssertFalse(gate.isVisible)
    }

    func test_observer_firesOnTransitionsOnly() {
        let gate = LiveUIGate.shared
        var events: [Bool] = []
        let token = gate.addObserver { events.append($0) }
        defer { gate.removeObserver(token) }

        gate.retain()              // closed → open  : fires true
        gate.retain()              // open  → open   : no fire
        gate.release()             // open  → open   : no fire
        gate.release()             // open  → closed : fires false

        XCTAssertEqual(events, [true, false],
                       "observer should fire only on actual open↔closed transitions")
    }

    /// The core architectural guarantee: while no surface is visible, an ingest
    /// does NOT update the @Published `entries` mirror (so a hidden popover does
    /// no per-tick work) — but the data is still banked and becomes visible the
    /// moment the gate opens.
    func test_storeMirror_isGated_thenFlushesOnOpen() {
        let store = LifetimeUsageStore.shared
        let id = "gatetest.\(UUID().uuidString)"

        // Gate closed: ingest twice (first = baseline, second = +5000 banked).
        store.ingest([makeUsage(id: id, bytesIn: 1_000, bytesOut: 0)])
        store.ingest([makeUsage(id: id, bytesIn: 6_000, bytesOut: 0)])

        // Data IS banked (authoritative snapshot), regardless of UI visibility.
        XCTAssertEqual(store.snapshot()[id]?.totalBytesIn, 5_000)
        // ...but the gated UI mirror has NOT picked up this id while closed.
        XCTAssertNil(store.entries[id],
                     "entries mirror must not update while no surface is visible")

        // Open the gate: the store's observer flushes the latest snapshot into
        // the mirror synchronously.
        LiveUIGate.shared.retain()
        defer { LiveUIGate.shared.release() }
        XCTAssertEqual(store.entries[id]?.totalBytesIn, 5_000,
                       "opening the gate flushes the current snapshot into the mirror")
    }

    private func makeUsage(id: String, bytesIn: UInt64, bytesOut: UInt64) -> AppNetworkUsage {
        AppNetworkUsage(
            id: id, displayName: id, bundleIdentifier: nil, bundlePath: nil,
            pids: [], downloadSpeed: 0, uploadSpeed: 0,
            totalBytesIn: bytesIn, totalBytesOut: bytesOut,
            origin: .unknown, trust: .unknown,
            connections: [], launchedFromTerminal: false
        )
    }
}
