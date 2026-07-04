import Foundation

/// Per-app rolling time-series of (download, upload) speed, kept at three
/// resolutions so we can show anything from "last minute" to "last 30 days"
/// without holding millions of samples.
///
/// Why tiered (round-robin database style): 30 days of raw 1 Hz samples is
/// ~2.6M points *per app* — gigabytes once you have dozens of apps. Instead we
/// keep:
///
///   • raw    — 1 Hz samples, last 1 hour (3600), in-memory only
///   • minute — per-minute averages, last 24 hours (1440), persisted to disk
///   • hour   — per-hour  averages, last 30 days  (720),  persisted to disk
///
/// The graph picks the finest tier that still covers the requested range, so a
/// "Last 5 min" view is smooth (raw) while "Last 30 days" stays cheap (hourly).
/// Persisted footprint is ~70 KB per app; the raw tier is regenerated on launch.
final class SpeedHistoryStore {
    static let shared = SpeedHistoryStore()

    struct Sample: Equatable {
        let t: Date
        let down: Double
        let up: Double
    }

    /// Which stored tier a query should read from.
    enum Resolution { case raw, minute, hour }

    // MARK: - Tiers

    /// Raw 1 Hz, last hour. In-memory only (cheap to rebuild, large to persist).
    private var raw: [String: [Sample]] = [:]
    private let rawCap = 3600

    /// Averaged bucket: sum + count so we can compute the mean speed over the
    /// bucket's window. `internal` (not `private`) so the pure append logic can be
    /// unit-tested via `@testable import`.
    struct Bucket: Codable {
        let start: Date
        var downSum: Double
        var upSum: Double
        var count: Int
        var downAvg: Double { count > 0 ? downSum / Double(count) : 0 }
        var upAvg: Double { count > 0 ? upSum / Double(count) : 0 }
    }

    private var minute: [String: [Bucket]] = [:]
    private var hour: [String: [Bucket]] = [:]
    private let minuteCap = 1440     // 24 h × 60
    private let hourCap = 720        // 30 d × 24

    private let secondsPerMinute: TimeInterval = 60
    private let secondsPerHour: TimeInterval = 3600
    private let thirtyDays: TimeInterval = 30 * 24 * 3600

    // MARK: - Persistence

    /// Concurrent with barrier writes. The chart panels call `series()` from the
    /// main thread every tick; on a serial queue those reads serialized behind
    /// the 1 Hz ingest AND the periodic full-store JSON encode, so an open chart
    /// could stall the main thread for the duration of an encode. Reads now run
    /// concurrently and only mutation takes the barrier — and the encode itself
    /// happens OFF this queue entirely (see the autosave handler), so a reader
    /// can never queue behind it.
    private let queue = DispatchQueue(label: "computer.lighthouse.beacon.speedhistory", qos: .utility, attributes: .concurrent)
    /// Where the JSON encode + disk write run, so they never occupy `queue` (and
    /// thus never make a main-thread `series()` read wait behind them).
    private let encodeQueue = DispatchQueue(label: "computer.lighthouse.beacon.speedhistory-encode", qos: .utility)
    private let storeURL: URL
    /// Mutation counter (bumped under the barrier) vs the generation last flushed
    /// to disk. Replaces a `dirty` flag so a save that races a concurrent ingest
    /// can't mark the newer, unflushed mutation as saved.
    private var generation: UInt64 = 0
    private var savedGeneration: UInt64 = 0
    private var saveTimer: DispatchSourceTimer?

    private struct Persisted: Codable {
        var minute: [String: [Bucket]]
        var hour: [String: [Bucket]]
    }

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Beacon", isDirectory: true)
        // See LifetimeUsageStore: one-time migration of the pre-rebrand
        // "NetworkUsageMonitor" folder so history survives the rename.
        let legacyDir = support.appendingPathComponent("NetworkUsageMonitor", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("speed-history.json")
        load()
        startAutosaveTimer()
    }

    // MARK: - Ingest

    /// Feed one snapshot of per-app usages. Called once per tick (~1 Hz) from
    /// the view model immediately after `ProcessTracker` aggregation.
    func ingest(_ apps: [AppNetworkUsage]) {
        let now = Date()
        let minuteStart = floor(now, to: secondsPerMinute)
        let hourStart = floor(now, to: secondsPerHour)
        // Fold windows scale with each tier's bucket width (2× the resolution): a
        // backward clock step smaller than this folds losslessly into the current
        // bucket; a larger one rebases so the chart can't freeze. Computed here,
        // outside the async body, so the tier constants don't need `self.` inside.
        let minuteFold = 2 * secondsPerMinute
        let hourFold = 2 * secondsPerHour
        queue.async(flags: .barrier) {
            for app in apps {
                // Tier 1 — raw ring.
                var r = self.raw[app.id] ?? []
                r.append(Sample(t: now, down: app.downloadSpeed, up: app.uploadSpeed))
                if r.count > self.rawCap { r.removeFirst(r.count - self.rawCap) }
                self.raw[app.id] = r

                // Tier 2 — minute buckets.
                self.accumulate(
                    into: &self.minute, id: app.id, bucketStart: minuteStart,
                    down: app.downloadSpeed, up: app.uploadSpeed, cap: self.minuteCap,
                    foldWindow: minuteFold
                )
                // Tier 3 — hour buckets. Without a tier-scaled fold window the
                // default (120 s, tuned for 60 s minute buckets) would rebase — and
                // drop the accumulating partial hour — on any backward step that
                // merely crosses an hour boundary (e.g. a few-second NTP nudge near
                // :00). The 2 h window folds those and rebases only on a truly large
                // (multi-hour) jump.
                self.accumulate(
                    into: &self.hour, id: app.id, bucketStart: hourStart,
                    down: app.downloadSpeed, up: app.uploadSpeed, cap: self.hourCap,
                    foldWindow: hourFold
                )
            }
            self.generation &+= 1
        }
    }

    private func accumulate(
        into store: inout [String: [Bucket]],
        id: String, bucketStart: Date,
        down: Double, up: Double, cap: Int, foldWindow: TimeInterval
    ) {
        store[id] = Self.appendingSample(store[id] ?? [], bucketStart: bucketStart,
                                         down: down, up: up, cap: cap, foldWindow: foldWindow)
    }

    /// Pure, testable bucket append. Folds one sample into `bucketStart`'s bucket
    /// and trims to `cap`. Keeps the array's `start` values **monotonically
    /// non-decreasing** even when the wall clock steps backward (NTP correction /
    /// manual set / VM clock jump).
    ///
    /// Why this matters: the old `==` check appended a brand-new bucket whenever
    /// `bucketStart != last.start`, so a backward step inserted an out-of-order
    /// (older) bucket at the tail. That breaks the graph's monotonic time axis and,
    /// worse, makes the `count > cap` trim `removeFirst` evict the *front* (which
    /// is no longer the oldest), silently dropping good history.
    ///
    /// Two backward regimes, split at `foldWindow`:
    /// * **Small step** (NTP jitter, ≤ `foldWindow` behind the tail): fold into
    ///   the most recent bucket — lossless, no axis disturbance.
    /// * **Large step** (manual clock change / VM restore): folding would freeze
    ///   the series — every sample lands in that one tail bucket until the clock
    ///   re-passes its start (an hour-long "frozen chart" for an hour's step). So
    ///   instead REBASE: drop buckets whose start is now in the future (per the
    ///   new clock those timestamps haven't happened yet) and resume recording at
    ///   `bucketStart`. The axis stays monotonic and the chart keeps moving.
    static func appendingSample(
        _ arr: [Bucket], bucketStart: Date, down: Double, up: Double, cap: Int,
        foldWindow: TimeInterval = 120
    ) -> [Bucket] {
        var arr = arr
        if var last = arr.last, last.start >= bucketStart {
            if last.start.timeIntervalSince(bucketStart) <= foldWindow {
                last.downSum += down
                last.upSum += up
                last.count += 1
                arr[arr.count - 1] = last
            } else {
                // Large backward step — rebase onto the new clock.
                arr.removeAll { $0.start > bucketStart }
                if var tail = arr.last, tail.start == bucketStart {
                    tail.downSum += down
                    tail.upSum += up
                    tail.count += 1
                    arr[arr.count - 1] = tail
                } else {
                    arr.append(Bucket(start: bucketStart, downSum: down, upSum: up, count: 1))
                }
            }
        } else {
            arr.append(Bucket(start: bucketStart, downSum: down, upSum: up, count: 1))
        }
        if arr.count > cap { arr.removeFirst(arr.count - cap) }
        return arr
    }

    private func floor(_ date: Date, to seconds: TimeInterval) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / seconds).rounded(.down) * seconds)
    }

    /// Bucket-mean decimation to ≤ `target` points. "Last 1 hour" reads the raw
    /// tier — 3600 samples → 7200 LineMarks across the two series — and Charts
    /// re-lays-out every mark on every 1 Hz tick, a measurable main-thread cost
    /// per open panel. ~720 points is denser than any panel is wide, so nothing
    /// visible is lost; averaging matches what the minute/hour tiers already do.
    /// Ranges that fit under `target` pass through untouched.
    private static func downsample(_ samples: [Sample], target: Int) -> [Sample] {
        guard samples.count > target, target > 0 else { return samples }
        let stride = Int((Double(samples.count) / Double(target)).rounded(.up))
        var out: [Sample] = []
        out.reserveCapacity(samples.count / stride + 1)
        var i = 0
        while i < samples.count {
            let chunk = samples[i..<min(i + stride, samples.count)]
            let n = Double(chunk.count)
            out.append(Sample(
                t: chunk[chunk.startIndex].t,
                down: chunk.reduce(0) { $0 + $1.down } / n,
                up: chunk.reduce(0) { $0 + $1.up } / n
            ))
            i += stride
        }
        return out
    }

    // MARK: - Query

    /// Time-series for one app over `range`, at the appropriate resolution.
    /// Empty if we have no data for that id/range yet.
    func series(forId id: String, range: GraphTimeRange) -> [Sample] {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-range.seconds)
            switch range.resolution {
            case .raw:
                return Self.downsample((raw[id] ?? []).filter { $0.t >= cutoff }, target: 720)
            case .minute:
                return (minute[id] ?? [])
                    .filter { $0.start >= cutoff }
                    .map { Sample(t: $0.start, down: $0.downAvg, up: $0.upAvg) }
            case .hour:
                return (hour[id] ?? [])
                    .filter { $0.start >= cutoff }
                    .map { Sample(t: $0.start, down: $0.downAvg, up: $0.upAvg) }
            }
        }
    }

    // MARK: - Persistence impl

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            // File exists but didn't decode — corrupt/truncated. Move it aside
            // so the next save doesn't silently overwrite recoverable history
            // with an empty store. History is non-critical (raw tier rebuilds
            // live), but a `.corrupt` copy aids diagnosis and avoids a quiet
            // data loss.
            let backup = storeURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storeURL, to: backup)
            return
        }
        // Drop anything already past its retention window (e.g. the app was
        // closed for a week) so we don't show stale gaps.
        let now = Date()
        minute = decoded.minute.mapValues { $0.filter { now.timeIntervalSince($0.start) <= 24 * 3600 } }
        hour = decoded.hour.mapValues { $0.filter { now.timeIntervalSince($0.start) <= self.thirtyDays } }
        pruneEmptyAndDeadApps(now: now)
    }

    private func startAutosaveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Snapshot under the barrier (a COW dictionary copy — microseconds),
            // then encode + write on encodeQueue so the store stays readable for
            // the whole duration of the encode.
            var payload: Persisted?
            var gen: UInt64 = 0
            self.queue.sync(flags: .barrier) {
                guard self.generation != self.savedGeneration else { return }
                self.pruneEmptyAndDeadApps(now: Date())
                payload = Persisted(minute: self.minute, hour: self.hour)
                gen = self.generation
            }
            guard let snapshot = payload else { return }
            // Already on encodeQueue (the timer's target) — encode inline.
            self.write(snapshot, upTo: gen, synchronously: true)
        }
        saveTimer = timer
        timer.resume()
    }

    /// Tiered eviction:
    ///   * Apps with no hour samples in 30 days are dropped entirely (the
    ///     existing key-set cap).
    ///   * Apps with stale RAW samples (newest > 10 min old) have their raw
    ///     buffer cleared so quiet apps stop carrying 60 stale points each.
    ///   * Apps with stale MINUTE samples (newest > 24h old) have their
    ///     minute buffer cleared.
    /// The hour tier is the long-term store; quiet apps keep their hour data
    /// until they cross the 30-day line.
    private func pruneEmptyAndDeadApps(now: Date) {
        let oneDay: TimeInterval = 86_400
        let tenMin: TimeInterval = 600
        let dead = hour.compactMap { (id, buckets) -> String? in
            guard let last = buckets.last else { return id }   // no buckets → dead
            return now.timeIntervalSince(last.start) > thirtyDays ? id : nil
        }
        for id in dead {
            hour[id] = nil
            minute[id] = nil
            raw[id] = nil
        }
        for (id, arr) in raw {
            if let last = arr.last, now.timeIntervalSince(last.t) > tenMin {
                raw[id] = nil
            }
        }
        for (id, arr) in minute {
            if let last = arr.last, now.timeIntervalSince(last.start) > oneDay {
                minute[id] = nil
            }
        }
    }

    /// Synchronous flush — blocks the caller until the encode + atomic write
    /// completes. Used on app quit: an async save would still be queued when
    /// `terminate()` runs, losing the last window of history (mirrors
    /// `LifetimeUsageStore.saveBlocking`).
    func saveBlocking() {
        var payload: Persisted?
        var gen: UInt64 = 0
        queue.sync(flags: .barrier) {
            guard generation != savedGeneration else { return }
            payload = Persisted(minute: minute, hour: hour)
            gen = generation
        }
        guard let snapshot = payload else { return }
        write(snapshot, upTo: gen, synchronously: true)
    }

    /// Encode + atomically write `snapshot`, then mark everything up to `gen` as
    /// flushed. Only advances `savedGeneration` on a *successful* write so a
    /// failed flush (disk full, sandbox hiccup) is retried on the next autosave
    /// instead of silently dropping that window's history — mirrors the
    /// deliberately-correct retry contract in LifetimeUsageStore. Runs on
    /// `encodeQueue` (or the caller's thread on the quit path) — never on `queue`,
    /// so readers can't stall behind the encode.
    private func write(_ snapshot: Persisted, upTo gen: UInt64, synchronously: Bool = false) {
        let work = { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: self.storeURL, options: .atomic)
                self.queue.async(flags: .barrier) {
                    self.savedGeneration = max(self.savedGeneration, gen)
                }
            } catch {
                // Non-fatal — savedGeneration stays behind so the next autosave retries.
            }
        }
        if synchronously { work() } else { encodeQueue.async(execute: work) }
    }

    deinit {
        saveTimer?.cancel()
    }
}
