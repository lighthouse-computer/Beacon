import Foundation
import os.log

// MARK: - Snapshot
/// One sample's worth of network data: per-PID summary rows + the per-PID
/// connection rows that fell underneath them in nettop's output + the total
/// instantaneous speed across the whole system.
struct NetworkSnapshot {
    let timestamp: Date
    let totalDownloadSpeed: Double
    let totalUploadSpeed: Double
    let processes: [ProcessSample]
    /// Per-connection samples, each tagged with the PID they belong to (resolved
    /// from the most recent preceding process row in the nettop output).
    let connections: [ConnectionSample]
}

/// Per-connection sample produced by the parser, with its PID resolved by the
/// streaming layer. Lives here (not in ProcessTracker) so the model that the
/// monitor emits is self-contained.
struct ConnectionSample {
    let pid: Int32
    let proto: String           // tcp4 / tcp6 / udp4 / udp6
    let localIP: String
    let localPort: UInt16
    let remoteIP: String
    let remotePort: UInt16
    let bytesIn: UInt64
    let bytesOut: UInt64
}

// MARK: - NetworkMonitor
/// Per-cycle `nettop -L 1` spawner.
///
/// Why per-cycle and not one long-lived nettop:
///   - In any non-`-L` mode, nettop runs an interactive ncurses display that
///     emits escape sequences instead of CSV — unparseable.
///   - With `-L N` (non-interactive mode) nettop *does* emit CSV, but it
///     fully buffers stdout when stdout is a pipe and only flushes on
///     buffer-full or process exit. A long-lived `-L 999999` would deliver
///     zero data for the first ~60 seconds.
///   - `-L 1` produces one snapshot and exits in ~60ms, which forces a
///     buffer flush. Pacing the loop ourselves at ~1Hz gives a live meter.
///
/// Architecture:
///   - Serial dispatch queue runs one cycle at a time: spawn → read → parse → emit.
///   - Deltas are computed across spawns using per-PID cumulative byte counts.
final class NetworkMonitor {
    // MARK: - Configuration
    private let nettopPath = "/usr/bin/nettop"
    private let cycleInterval: TimeInterval = 1.0
    /// Hard ceiling on one nettop spawn. `-L 1` normally exits in ~60ms; if a
    /// spawn is still running after this long it has wedged (kernel stall, stuck
    /// socket enumeration), so we kill it and move on. Without this, a single
    /// hung spawn blocks the serial queue forever and the live meter dies
    /// silently with no recovery until the app is restarted.
    private let spawnTimeout: TimeInterval = 5.0
    private let logger = OSLog(
        subsystem: "computer.lighthouse.beacon.macos",
        category: "NetworkMonitor"
    )

    // MARK: - Process State
    private let queue = DispatchQueue(label: "computer.lighthouse.beacon.spawn", qos: .utility)
    /// Separate queue for the per-spawn watchdog timer so it can fire while the
    /// spawn queue is blocked reading/awaiting the nettop process.
    private let watchdogQueue = DispatchQueue(label: "computer.lighthouse.beacon.watchdog", qos: .utility)
    private var stopped = true
    private var currentProcess: Process?

    // MARK: - Totals Tracking (across snapshots)
    private var previousTotalsByPid: [Int32: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var previousSnapshotTime: Date?

    /// Emitted on the main queue after each parsed snapshot.
    var onSnapshot: ((NetworkSnapshot) -> Void)?

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self = self, self.stopped else { return }
            self.stopped = false
            self.runCycle()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            currentProcess?.terminate()
            currentProcess = nil
        }
    }

    deinit { stop() }

    // MARK: - Cycle

    private func runCycle() {
        if stopped { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nettopPath)
        // -n  no DNS resolution (cheaper, and an explicit non-goal — we never
        //     make network calls of our own)
        // -L 1  one CSV snapshot then exit (~60ms). Required: any non-`-L`
        //       mode emits ncurses escape codes, not CSV.
        //
        // We dropped `-P` (process-only mode) in 1.3.0 so nettop also includes
        // per-connection sub-rows under each process. That's what powers the
        // graph panel's Port / Service / IP breakdown. Output volume goes from
        // ~25 lines to ~100-200, still well under any cost worth optimizing.
        proc.arguments = ["-n", "-L", "1"]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        // Close both pipe ends explicitly when the cycle returns. In the current
        // structure (one self-rescheduling GCD work item per cycle) ARC already
        // reclaims these fds when the work item's autorelease pool drains, so this
        // is not fixing a present leak — it makes the reclamation independent of
        // that pool-drain timing, so a future refactor to a long-lived repeating
        // timer block (which would NOT drain per fire) can't silently reintroduce a
        // 2-fd-per-cycle leak that would exhaust the fd table in minutes.
        defer {
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
        }
        // Force the C locale so nettop emits unlocalized integers (no thousands
        // separators that would shatter the comma-split) and stable ASCII column
        // headers. The CSV parser assumes both; a localized environment could
        // silently corrupt byte accounting. Inherit the rest of the environment.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        proc.environment = env

        do {
            try proc.run()
            currentProcess = proc

            // Watchdog: terminate the spawn if it overruns spawnTimeout. The
            // timer runs on a separate queue so it fires even while this queue
            // blocks in readDataToEndOfFile / waitUntilExit. terminate() closes
            // nettop's stdout, which unblocks the read and lets waitUntilExit
            // return — so the cycle always makes progress and reschedules.
            let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
            watchdog.schedule(deadline: .now() + spawnTimeout)
            watchdog.setEventHandler { [weak proc] in
                if proc?.isRunning == true {
                    proc?.terminate()
                }
            }
            watchdog.resume()
            // defer guarantees the watchdog is cancelled on every exit path
            // from this do-block — including any future `try` added between
            // here and the end — so the timer source can never leak.
            defer { watchdog.cancel() }

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            currentProcess = nil

            if proc.terminationStatus != 0 {
                os_log(
                    "nettop exited non-zero (status=%d, reason=%d)",
                    log: logger, type: .error,
                    Int(proc.terminationStatus),
                    Int(proc.terminationReason.rawValue)
                )
            } else if let text = String(data: data, encoding: .utf8) {
                processOutput(text)
            }
        } catch {
            os_log(
                "Failed to launch nettop: %{public}@",
                log: logger, type: .error, error.localizedDescription
            )
        }

        if !stopped {
            queue.asyncAfter(deadline: .now() + cycleInterval) { [weak self] in
                self?.runCycle()
            }
        }
    }

    private func processOutput(_ text: String) {
        var samples: [ProcessSample] = []
        var connections: [ConnectionSample] = []
        // PID inherited by connection rows from the most recent process row
        // above them in nettop's output. Reset between snapshots (each call to
        // this method is one snapshot).
        var currentPid: Int32?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = NettopLineParser.parseRow(line: String(line)) else { continue }
            switch row {
            case .process(let p):
                currentPid = p.pid
                samples.append(ProcessSample(
                    pid: p.pid,
                    processName: p.processName,
                    bytesIn: p.bytesIn,
                    bytesOut: p.bytesOut
                ))
            case .connection(let c):
                guard let pid = currentPid else { continue }
                connections.append(ConnectionSample(
                    pid: pid,
                    proto: c.proto,
                    localIP: c.localIP,
                    localPort: c.localPort,
                    remoteIP: c.remoteIP,
                    remotePort: c.remotePort,
                    bytesIn: c.bytesIn,
                    bytesOut: c.bytesOut
                ))
            }
        }
        guard !samples.isEmpty else { return }

        let now = Date()
        var totalIn: Double = 0
        var totalOut: Double = 0
        // Interval since the previous snapshot. A non-positive value means the
        // wall clock stepped backward (NTP correction / manual change); an
        // abnormally large value means the machine slept between cycles. In both
        // cases the cumulative byte delta ÷ this interval is a garbage rate (a
        // backward step would divide by the 0.1 floor → a ~10× phantom spike), so
        // we re-baseline this tick and report zero instead of a spike.
        let rawInterval = previousSnapshotTime.map { now.timeIntervalSince($0) }
        let anomalousInterval = rawInterval.map { $0 <= 0 || $0 > 10 * cycleInterval } ?? false
        // No upper clamp needed: any interval past 10× cycle is anomalous and the
        // speeds are suppressed outright below, so dt never divides in that case.
        let dt = max(0.1, rawInterval ?? cycleInterval)

        let seenPids = Set(samples.map { $0.pid })
        for sample in samples {
            if let prev = previousTotalsByPid[sample.pid] {
                if sample.bytesIn  >= prev.bytesIn  { totalIn  += Double(sample.bytesIn  - prev.bytesIn) }
                if sample.bytesOut >= prev.bytesOut { totalOut += Double(sample.bytesOut - prev.bytesOut) }
            }
            previousTotalsByPid[sample.pid] = (sample.bytesIn, sample.bytesOut)
        }
        // Drop entries for PIDs nettop didn't report this cycle. Without this,
        // every PID the system ever spawns stays in the map for the life of
        // the process — slow leak over multi-day sessions. ProcessTracker has
        // its own per-PID retention with a 120s grace; this top-level map
        // only needs a baseline for "next cycle" so eager pruning is fine.
        for pid in previousTotalsByPid.keys where !seenPids.contains(pid) {
            previousTotalsByPid[pid] = nil
        }

        // Suppress speeds on the very first cycle (no baseline yet) and on any
        // anomalous interval (clock step / sleep-wake) so neither produces a
        // wrong or spiked number. The byte baseline above is still updated so the
        // next cycle measures cleanly.
        let isFirstCycle = previousSnapshotTime == nil
        let suppressSpeed = isFirstCycle || anomalousInterval
        previousSnapshotTime = now

        let snapshot = NetworkSnapshot(
            timestamp: now,
            totalDownloadSpeed: suppressSpeed ? 0 : totalIn / dt,
            totalUploadSpeed:   suppressSpeed ? 0 : totalOut / dt,
            processes: samples,
            connections: connections
        )

        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }
}
