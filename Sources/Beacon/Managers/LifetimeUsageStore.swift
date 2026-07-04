import Foundation
import Combine

/// Saturating UInt64 add: clamps at `.max` instead of wrapping. Lifetime totals
/// are "all-time" counters where a silent wrap would make the displayed total
/// jump *backwards* to a tiny number; saturating keeps them monotonic even on a
/// pathological (corrupt baseline / bad upstream counter) input.
@inline(__always)
func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : sum
}

/// Per-app entry as persisted to disk.
struct LifetimeUsage: Codable, Identifiable, Equatable {
    /// Stable app identifier — same key the live tracker uses (bundle id or name).
    let id: String
    var displayName: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var totalBytesIn: UInt64
    var totalBytesOut: UInt64
    var firstSeen: Date
    var lastSeen: Date

    var totalBytes: UInt64 { saturatingAdd(totalBytesIn, totalBytesOut) }
}

/// Cross-session cumulative store. The live ProcessTracker only knows about
/// bytes observed during the current run; this layer adds each snapshot's
/// per-app delta into a persisted lifetime counter so the popover can show
/// "all-time" data across launches.
///
/// Threading model (v1.4.3 rewrite):
/// * All mutable state lives on the serial `queue`. The only thing on the
///   main thread is `entries` itself — kept as an @Published *mirror* updated
///   via `DispatchQueue.main.async` at the end of each ingest. Views read the
///   mirror; nothing reads the queue-owned dictionary on the main thread.
/// * Persistence (`saveNow`) reads + writes inside the queue's barrier so a
///   tick's writes never interleave with the encode. The `dirty` flag is
///   only cleared after a *successful* write, so an encode failure schedules
///   a retry on the next tick.
/// * `resetAll` and the on-quit blocking save both round-trip through the
///   queue, so they observe a consistent snapshot.
///
/// Eviction:
/// * ONLY zero-byte rows are dropped: entries that have recorded **no** all-time
///   bytes (transient daemons / installers / one-shot CLIs that registered but
///   never moved measurable traffic) and have been idle past `idleEvictionGrace`
///   (30 days). A row with ANY all-time bytes is kept forever — this is an
///   "all-time" store, so a real total must never be silently deleted (e.g. just
///   because the app wasn't running for a week). Keeps `lifetime.json` bounded
///   without ever losing data the user cares about.
///
/// IMPORTANT limitation: we can only count what we saw. Bytes the OS transfers
/// when the menu-bar app isn't running are unrecoverable — there's no system
/// API that gives us retroactive per-process counters.
final class LifetimeUsageStore: ObservableObject {
    static let shared = LifetimeUsageStore()

    /// Public, main-thread snapshot. Views observe this. Updated by an async
    /// dispatch from the persistence queue at the end of each ingest.
    @Published private(set) var entries: [String: LifetimeUsage] = [:]

    // MARK: - Queue-owned state

    /// Authoritative dictionary — all mutations happen on `queue`.
    private var queueEntries: [String: LifetimeUsage] = [:]
    /// Token for the LiveUIGate subscription that flushes on open.
    private var gateToken: UUID?
    /// Last seen session totals per app id (queue-owned).
    private var lastSessionBytes: [String: (UInt64, UInt64)] = [:]
    /// Dirty flag (queue-owned).
    private var dirty: Bool = false

    private let queue = DispatchQueue(label: "computer.lighthouse.beacon.lifetime", qos: .utility)
    private let storeURL: URL
    private var saveTimer: DispatchSourceTimer?
    /// Idle-eviction grace. Only **zero-byte** rows that have been idle this long
    /// are dropped on save; rows with real all-time bytes are kept regardless of
    /// age. See `shouldEvict`.
    private let idleEvictionGrace: TimeInterval = 30 * 24 * 3600

    /// Bumped when the on-disk shape changes. Persisted as `{ "schema": N, "entries": {...} }`.
    /// v0 (implicit) was the bare `[String: LifetimeUsage]` shape from v1.0–1.4.2.
    /// v1 added the wrapper. Load supports both for backward compat.
    private static let currentSchema: Int = 1

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Beacon", isDirectory: true)
        // One-time migration from the pre-rebrand folder (the app shipped as
        // "NetworkUsageMonitor" before Beacon 1.0). Move it wholesale so
        // accumulated usage history survives the rename; whichever store
        // initialises first migrates both JSON files, since they share this dir.
        let legacyDir = support.appendingPathComponent("NetworkUsageMonitor", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("lifetime.json")
        load()
        startAutosaveTimer()

        // When a UI surface opens, push the current authoritative state into the
        // mirror immediately so the popover renders fresh all-time data without
        // waiting for the next ingest tick. `snapshot()` is queue-synchronized,
        // so it can never be stale relative to in-flight ingests. The observer
        // runs on main (LiveUIGate is main-confined).
        gateToken = LiveUIGate.shared.addObserver { [weak self] visible in
            guard let self = self, visible else { return }
            self.entries = self.snapshot()
        }
    }

    // MARK: - Ingest

    /// Feed the latest snapshot of app aggregations. Computes the per-app delta
    /// against the previous tick of the same session and adds it to the
    /// lifetime counter. Safe to call every tick. Returns immediately; the
    /// mutation runs on the persistence queue and the main-thread mirror is
    /// updated when done.
    func ingest(_ apps: [AppNetworkUsage]) {
        let now = Date()
        queue.async { [self] in
            var changed = false
            for app in apps {
                // On the first sighting of an app this session we have no
                // baseline to diff its session-cumulative counters against, so
                // treat the current counters AS the baseline and bank zero.
                // Diffing against (0,0) instead would re-count the whole
                // session-so-far — which is exactly what made "Reset all-time
                // data" silently re-accumulate: resetAll() clears this baseline
                // while ProcessTracker keeps its (already large) session
                // counters, so the next tick re-banked the entire session total
                // back onto the freshly-wiped lifetime store.
                let baseline = lastSessionBytes[app.id]
                lastSessionBytes[app.id] = (app.totalBytesIn, app.totalBytesOut)
                let dIn:  UInt64
                let dOut: UInt64
                if let prev = baseline {
                    dIn  = app.totalBytesIn  >= prev.0 ? app.totalBytesIn  - prev.0 : 0
                    dOut = app.totalBytesOut >= prev.1 ? app.totalBytesOut - prev.1 : 0
                } else {
                    dIn = 0
                    dOut = 0
                }

                if dIn == 0 && dOut == 0 && queueEntries[app.id] != nil { continue }

                if var existing = queueEntries[app.id] {
                    existing.totalBytesIn  = saturatingAdd(existing.totalBytesIn,  dIn)
                    existing.totalBytesOut = saturatingAdd(existing.totalBytesOut, dOut)
                    existing.lastSeen = now
                    existing.displayName = app.displayName
                    existing.bundleIdentifier = app.bundleIdentifier ?? existing.bundleIdentifier
                    existing.bundlePath = app.bundlePath ?? existing.bundlePath
                    queueEntries[app.id] = existing
                } else {
                    queueEntries[app.id] = LifetimeUsage(
                        id: app.id,
                        displayName: app.displayName,
                        bundleIdentifier: app.bundleIdentifier,
                        bundlePath: app.bundlePath,
                        totalBytesIn: dIn,
                        totalBytesOut: dOut,
                        firstSeen: now,
                        lastSeen: now
                    )
                }
                changed = true
            }
            if changed {
                dirty = true
                let snapshot = queueEntries
                DispatchQueue.main.async {
                    // Only push to the @Published mirror (which re-renders the
                    // popover) while a surface is visible. The data is fully
                    // accumulated on the queue regardless; a later gate-open
                    // flush reads it via snapshot().
                    if LiveUIGate.shared.isVisible {
                        self.entries = snapshot
                    }
                }
            }
        }
    }

    /// Authoritative snapshot of the lifetime table, read directly from the
    /// serial queue — independent of UI visibility and the gated `entries`
    /// mirror. Use this for correctness checks (and tests) that must observe the
    /// banked data whether or not any window is open. Synchronous: blocks the
    /// caller until the queue drains pending ingests, so the result reflects all
    /// ingests issued before this call.
    func snapshot() -> [String: LifetimeUsage] {
        queue.sync { queueEntries }
    }

    /// Sorted top-N. Reads the main-thread mirror — safe from any thread the
    /// view system calls us on, but designed for SwiftUI on main.
    func topByLifetime(limit: Int = 10) -> [LifetimeUsage] {
        entries.values
            .filter { $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }
            .prefix(limit)
            .map { $0 }
    }

    func resetAll() {
        queue.async { [self] in
            queueEntries.removeAll()
            lastSessionBytes.removeAll()
            dirty = true
            let snapshot = queueEntries
            // User-initiated reset: publish unconditionally (the popover is open
            // when this is invoked) so the cleared list shows immediately.
            DispatchQueue.main.async {
                self.entries = snapshot
            }
            _writeBlockingOnQueue()
        }
    }

    // MARK: - Persistence

    /// Synchronous load (init-time only, before the timer starts).
    private func load() {
        // No file yet (first launch) — nothing to load, and nothing to protect.
        guard let data = try? Data(contentsOf: storeURL) else { return }
        // v1 wrapper first.
        if let wrapped = try? JSONDecoder().decode(PersistedWrapper.self, from: data) {
            queueEntries = wrapped.entries
        } else if let legacy = try? JSONDecoder().decode([String: LifetimeUsage].self, from: data) {
            // v0 — bare dictionary, what shipped through 1.4.2. Migrate by
            // re-saving in the new shape on the first save tick.
            queueEntries = legacy
            dirty = true
        } else {
            // The file exists but neither shape decoded — it's corrupt or
            // truncated (e.g. power loss mid-write before atomic writes shipped,
            // or disk damage). Do NOT continue with an empty dict: the first
            // save would overwrite the user's real all-time totals with `{}`.
            // Move the bad file aside for post-mortem and keep dirty=false so we
            // don't immediately re-save over a fresh (empty) file either.
            let backup = storeURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storeURL, to: backup)
        }
        // Initial load runs in init before any UI exists; seed the mirror so a
        // synchronous early read sees loaded data. The gate-open flush later
        // re-reads via snapshot().
        entries = queueEntries
    }

    /// Flush every 30s if there's pending work. Cheap because the entries
    /// dict is small (~hundreds of bundles, max).
    private func startAutosaveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?._writeIfDirtyOnQueue()
        }
        saveTimer = timer
        timer.resume()
    }

    /// Public async save trigger — schedules a flush on the persistence queue.
    /// Use `saveBlocking()` instead when the caller needs the bytes on disk
    /// before continuing (e.g., app quit).
    func saveNow() {
        queue.async { [self] in _writeIfDirtyOnQueue() }
    }

    /// Synchronous save — blocks the caller until the encode + atomic write
    /// completes. Used from `quit` so we don't terminate while bytes are still
    /// queued. The old `saveNow()` returned immediately while the dispatch
    /// was pending — quit raced it and lost the last few seconds.
    func saveBlocking() {
        queue.sync { _writeBlockingOnQueue() }
    }

    /// Must be called on `queue`. Encodes + atomically writes the current
    /// entries dict. Only clears `dirty` on success so an I/O failure schedules
    /// a retry on the next tick.
    private func _writeIfDirtyOnQueue() {
        guard dirty else { return }
        _writeBlockingOnQueue()
    }

    private func _writeBlockingOnQueue() {
        evictIdleEntriesOnQueue()
        let wrapper = PersistedWrapper(schema: Self.currentSchema, entries: queueEntries)
        do {
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: storeURL, options: .atomic)
            dirty = false
        } catch {
            // Non-fatal — leave dirty=true so next tick retries.
        }
    }

    /// Whether a lifetime row is safe to drop at save time. Pure + testable so
    /// the "never delete real data" contract is pinned by a unit test.
    ///
    /// We evict ONLY rows that never recorded any bytes (`totalBytes == 0`) and
    /// have been idle (both first and last sighting) past `grace`. A row with any
    /// all-time bytes is never auto-deleted — silently dropping a real total (e.g.
    /// after the app was closed for a week, so every persisted row's `lastSeen` is
    /// now old) would destroy exactly the data this store exists to keep.
    static func shouldEvict(_ entry: LifetimeUsage, now: Date, grace: TimeInterval) -> Bool {
        guard entry.totalBytes == 0 else { return false }
        let cutoff = now.addingTimeInterval(-grace)
        return entry.lastSeen < cutoff && entry.firstSeen < cutoff
    }

    /// Drop idle zero-byte rows (see `shouldEvict`). Done at save time so we don't
    /// pay the scan cost every tick.
    private func evictIdleEntriesOnQueue() {
        let now = Date()
        var changed = false
        for (id, entry) in queueEntries {
            if Self.shouldEvict(entry, now: now, grace: idleEvictionGrace) {
                queueEntries.removeValue(forKey: id)
                lastSessionBytes.removeValue(forKey: id)
                changed = true
            }
        }
        if changed {
            let snapshot = queueEntries
            // Eviction at save time: only re-render the popover if it's actually
            // visible; otherwise a later gate-open flush picks up the change.
            DispatchQueue.main.async {
                if LiveUIGate.shared.isVisible {
                    self.entries = snapshot
                }
            }
        }
    }

    deinit {
        saveTimer?.cancel()
        // No sync save here. This is a process-lifetime singleton (the only
        // strong reference is `shared`), so deinit never runs in practice; and a
        // `queue.sync` from deinit would deadlock outright if it ever ran *on*
        // `queue`. Durability is already covered by the 30s autosave timer and
        // the explicit `saveBlocking()` on app quit.
    }

    // MARK: - On-disk shape

    /// Versioned wrapper persisted to lifetime.json. Adding a field here that
    /// isn't backward-compatible means bumping `currentSchema` and adding a
    /// migration branch in `load()`.
    private struct PersistedWrapper: Codable {
        let schema: Int
        let entries: [String: LifetimeUsage]
    }
}
