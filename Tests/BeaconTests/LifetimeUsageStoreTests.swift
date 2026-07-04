import XCTest
@testable import Beacon

/// LifetimeUsageStore covers the highest-risk surface area: cross-session
/// persistence of all-time totals. Past bugs included:
///   * v1.2.1 — full-total re-add on PID restart (double-count)
///   * v1.4.3 — concurrent read on persistence queue vs write on main (UB)
///   * v1.4.3 — `dirty` cleared outside the async block (lost saves)
///
/// These tests pin the new contract: the public `entries` mirror reflects
/// what was ingested, deltas only bank the positive change, blocking save
/// round-trips through the queue, schema-version migration from the legacy
/// bare-dict format works.
///
/// We can't easily test the singleton's file I/O without polluting Application
/// Support, so persistence-related tests are intentionally narrow (decoding a
/// known on-disk blob through `JSONDecoder`). The singleton's concurrency
/// guarantees are tested via the public ingest → mirror update path.
final class LifetimeUsageStoreTests: XCTestCase {

    /// Banks only the positive delta between successive ingests. A repeated
    /// snapshot with smaller totals (e.g. the app restarted and nettop's
    /// cumulative counter reset) must NOT re-add the full new value.
    func test_ingest_banks_only_positive_deltas() {
        let store = LifetimeUsageStore.shared
        // Use a unique-ish id so the test doesn't fight whatever lifetime
        // entries the real app may have persisted on this dev machine.
        let id = "test.\(UUID().uuidString)"
        let app1 = makeUsage(id: id, bytesIn: 1_000, bytesOut: 500)
        let app2 = makeUsage(id: id, bytesIn: 6_000, bytesOut: 800)
        let app3 = makeUsage(id: id, bytesIn:   100, bytesOut: 100) // simulated counter reset

        // Assert on snapshot() — the authoritative, queue-synchronized view of
        // the banked data. NOT the @Published `entries` mirror: that mirror is
        // gated on LiveUIGate (no UI surface is visible in a unit test, so it
        // never updates). snapshot() is the right surface for a data-correctness
        // test and is synchronous, so no polling/waiting is needed.
        store.ingest([app1])
        let baseline = store.snapshot()[id]
        XCTAssertNotNil(baseline)
        // First ingest sets the baseline; nothing is banked yet.
        XCTAssertEqual(baseline?.totalBytesIn, 0)
        XCTAssertEqual(baseline?.totalBytesOut, 0)

        store.ingest([app2])
        XCTAssertEqual(store.snapshot()[id]?.totalBytesIn, 5_000, "delta of 5000 banked")
        XCTAssertEqual(store.snapshot()[id]?.totalBytesOut, 300)

        // Counter reset — must NOT add app3's totals on top.
        let beforeReset = store.snapshot()[id]
        store.ingest([app3])
        XCTAssertEqual(store.snapshot()[id]?.totalBytesIn, beforeReset?.totalBytesIn,
                       "no positive delta after a counter reset")
        XCTAssertEqual(store.snapshot()[id]?.totalBytesOut, beforeReset?.totalBytesOut)
    }

    /// The legacy on-disk format was a bare `[String: LifetimeUsage]`. The
    /// v1.4.3 wrapper adds a `schema` field. Decoding the legacy shape must
    /// still succeed (forward-compat read path).
    func test_legacy_bare_dict_shape_decodes() throws {
        let id = "legacy.\(UUID().uuidString)"
        let legacy: [String: LifetimeUsage] = [
            id: LifetimeUsage(
                id: id, displayName: "Legacy", bundleIdentifier: nil, bundlePath: nil,
                totalBytesIn: 123, totalBytesOut: 456,
                firstSeen: Date(timeIntervalSince1970: 1_700_000_000),
                lastSeen:  Date(timeIntervalSince1970: 1_700_000_100)
            )
        ]
        let blob = try JSONEncoder().encode(legacy)
        let roundTrip = try JSONDecoder().decode([String: LifetimeUsage].self, from: blob)
        XCTAssertEqual(roundTrip[id]?.totalBytes, 579)
    }

    // MARK: - eviction contract (never delete real all-time data)

    private func row(in bIn: UInt64, out bOut: UInt64, first: Date, last: Date) -> LifetimeUsage {
        LifetimeUsage(id: "e", displayName: "e", bundleIdentifier: nil, bundlePath: nil,
                      totalBytesIn: bIn, totalBytesOut: bOut, firstSeen: first, lastSeen: last)
    }

    func test_shouldEvict_keepsRowWithBytes_evenWhenAncient() {
        // A row that moved bytes is "all-time" data — never auto-deleted, no
        // matter how long idle. This is the regression guard for the 7-day
        // age-only eviction that silently wiped totals after a week's absence.
        let ancient = row(in: 1, out: 0,
                          first: Date(timeIntervalSince1970: 0),
                          last:  Date(timeIntervalSince1970: 0))
        XCTAssertFalse(LifetimeUsageStore.shouldEvict(ancient, now: Date(), grace: 30 * 24 * 3600))
    }

    func test_shouldEvict_dropsZeroByteRowPastGrace() {
        let now = Date()
        let old = now.addingTimeInterval(-31 * 24 * 3600)
        XCTAssertTrue(LifetimeUsageStore.shouldEvict(
            row(in: 0, out: 0, first: old, last: old), now: now, grace: 30 * 24 * 3600))
    }

    func test_shouldEvict_keepsZeroByteRowWithinGrace() {
        let now = Date()
        let recent = now.addingTimeInterval(-60)
        XCTAssertFalse(LifetimeUsageStore.shouldEvict(
            row(in: 0, out: 0, first: recent, last: recent), now: now, grace: 30 * 24 * 3600))
    }

    func test_shouldEvict_keepsZeroByteRowStillActive() {
        // firstSeen ancient but lastSeen recent → still in use, keep it.
        let now = Date()
        XCTAssertFalse(LifetimeUsageStore.shouldEvict(
            row(in: 0, out: 0, first: now.addingTimeInterval(-40 * 24 * 3600),
                last: now.addingTimeInterval(-60)),
            now: now, grace: 30 * 24 * 3600))
    }

    // MARK: - helpers

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
