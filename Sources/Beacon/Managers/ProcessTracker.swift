import Foundation
import AppKit
import Darwin

/// Raw per-PID sample produced by the nettop parser.
struct ProcessSample {
    let pid: Int32
    let processName: String
    /// Cumulative bytes_in reported by nettop for this PID in this snapshot.
    let bytesIn: UInt64
    /// Cumulative bytes_out reported by nettop for this PID in this snapshot.
    let bytesOut: UInt64
}

/// Resolved metadata for a PID — cached so we don't hit launch services repeatedly.
private struct ProcessIdentity {
    let displayName: String
    let bundleIdentifier: String?
    let bundlePath: String?
    /// The nettop process name this identity was resolved against. Used to
    /// detect PID reuse: macOS recycles PIDs, and a given PID reports a stable
    /// process name while it lives, so a changed name means a different process
    /// now holds this PID and the cached identity (and per-PID counters) are
    /// stale.
    let command: String
    /// True when a shell / terminal emulator was found in this process's
    /// parent-pid chain — i.e. the process was launched from a terminal. Drives
    /// the "Terminal" chip. Resolved once per PID and cached with the identity.
    let launchedFromTerminal: Bool
}

/// Owns per-PID state across nettop snapshots. Computes:
///   - per-PID delta bytes per snapshot
///   - per-PID instantaneous speed
///   - per-PID session-cumulative bytes (running sum of positive deltas)
/// Then aggregates across PIDs sharing a bundle identifier.
final class ProcessTracker {
    // MARK: - Per-PID State
    private struct PidState {
        var lastBytesIn: UInt64
        var lastBytesOut: UInt64
        var lastTimestamp: Date
        var sessionBytesIn: UInt64
        var sessionBytesOut: UInt64
        var identity: ProcessIdentity
    }

    private var pidStates: [Int32: PidState] = [:]
    private var identityCache: [Int32: ProcessIdentity] = [:]

    // MARK: - Per-PID-per-Connection State

    /// One nettop-reported flow under one PID. Same delta-tracking pattern as
    /// the per-PID totals — keep the last reported cumulative bytes so we can
    /// accumulate positive deltas into session totals.
    private struct ConnState {
        let proto: String
        let localIP: String
        let localPort: UInt16
        let remoteIP: String
        let remotePort: UInt16
        var lastBytesIn: UInt64
        var lastBytesOut: UInt64
        var sessionBytesIn: UInt64
        var sessionBytesOut: UInt64
    }

    /// Key uniquely identifying a flow within a PID. We include `localIP` so
    /// that a process holding the same local port on both stacks (a dual-stack
    /// listener at tcp4:8080 and tcp6:8080, or a transient outbound peer pair
    /// that happens to reuse a port number across families) doesn't collapse
    /// to a single key under the normalized "tcp" proto.
    private struct ConnKey: Hashable {
        let proto: String
        let localIP: String
        let localPort: UInt16
        let remoteIP: String
        let remotePort: UInt16
    }

    private var connStates: [Int32: [ConnKey: ConnState]] = [:]

    /// Aggregate by bundle-id so multi-process apps (Chrome, Electron) collapse to one row.
    /// Bundle-less processes (daemons, helpers without bundle metadata) key on processName.
    private struct BundleAccumulator {
        var displayName: String
        var bundleIdentifier: String?
        var bundlePath: String?
        var pids: [Int32] = []
        var downloadSpeed: Double = 0
        var uploadSpeed: Double = 0
        var totalBytesIn: UInt64 = 0
        var totalBytesOut: UInt64 = 0
        /// True if ANY contributing PID was launched from a terminal.
        var launchedFromTerminal: Bool = false
        /// Per-(proto, localPort) aggregation of connection state from all PIDs
        /// in the bundle. Inner key is the remote endpoint id so we can roll
        /// distinct remotes up into a single AppConnection.remotes list.
        var connAgg: [String: ConnAgg] = [:]
    }

    /// Mutable scratch type used inside `BundleAccumulator.connAgg` while we
    /// build the per-bundle connection list. Keyed on the *service-side*
    /// `(proto, port)` — see `foldConnections` for why. Becomes `AppConnection`
    /// after the loop finishes.
    private struct ConnAgg {
        let proto: String       // normalized: "tcp" / "udp" (IP-family digit dropped)
        let port: UInt16        // service-side port
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var remotes: [String: RemoteAgg] = [:]
    }
    private struct RemoteAgg {
        let ip: String
        let port: UInt16
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
    }

    /// Feed one snapshot (one tick worth of per-PID rows) into the tracker.
    /// Returns the up-to-date aggregated `[AppNetworkUsage]` after applying
    /// this snapshot. The `connections` overload also folds per-flow byte
    /// deltas into the per-PID connection state.
    func ingest(snapshot: [ProcessSample], snapshotTime: Date) -> [AppNetworkUsage] {
        return ingest(snapshot: snapshot, connections: [], snapshotTime: snapshotTime)
    }

    func ingest(
        snapshot: [ProcessSample],
        connections: [ConnectionSample],
        snapshotTime: Date
    ) -> [AppNetworkUsage] {
        let seenPids = Set(snapshot.map { $0.pid })

        for sample in snapshot {
            // PID reuse vs. live exec. macOS recycles PIDs, and a live process
            // can also exec() a new image under the same PID. Both change the
            // nettop command, but only a *recycled* PID restarts its cumulative
            // byte counters near zero — a live exec keeps its sockets (and their
            // counters) climbing. So drop the stale per-PID state only when the
            // command changed AND the counters regressed. That stops a new
            // process from inheriting the dead one's totals (misattributed
            // traffic) without wrongly resetting a still-running process that
            // merely renamed (which would lose its in-flight delta and
            // undercount).
            if let prior = pidStates[sample.pid],
               prior.identity.command != sample.processName,
               sample.bytesIn < prior.lastBytesIn || sample.bytesOut < prior.lastBytesOut {
                pidStates[sample.pid] = nil
                connStates[sample.pid] = nil
                lastSpeedByPid[sample.pid] = nil
                identityCache[sample.pid] = nil
            }

            let identity = resolveIdentity(pid: sample.pid, fallbackName: sample.processName)

            if var state = pidStates[sample.pid] {
                // Diff against last snapshot for this PID
                let inDelta = (sample.bytesIn >= state.lastBytesIn)
                    ? (sample.bytesIn - state.lastBytesIn) : 0
                let outDelta = (sample.bytesOut >= state.lastBytesOut)
                    ? (sample.bytesOut - state.lastBytesOut) : 0

                state.sessionBytesIn = state.sessionBytesIn &+ inDelta
                state.sessionBytesOut = state.sessionBytesOut &+ outDelta
                state.lastBytesIn = sample.bytesIn
                state.lastBytesOut = sample.bytesOut

                // Per-PID speed = positive byte delta ÷ elapsed time. Guard the
                // interval exactly like NetworkMonitor guards the header total: a
                // non-positive interval (wall clock stepped back) or an
                // implausibly large one (machine slept) makes delta/dt a garbage
                // rate, so suppress the speed for this tick while still banking
                // the bytes. Without this, a per-app row could spike (or a NaN/inf
                // could flow into the speed-history chart) while the guarded
                // header total disagrees.
                let rawDt = snapshotTime.timeIntervalSince(state.lastTimestamp)
                let anomalousInterval = rawDt <= 0 || rawDt > Self.maxPlausibleInterval
                // No upper clamp needed: past maxPlausibleInterval the tick is
                // anomalous and the speed is zeroed, so dt never divides there.
                let dt = max(0.1, rawDt)
                lastSpeedByPid[sample.pid] = anomalousInterval
                    ? (download: 0, upload: 0)
                    : (download: Double(inDelta) / dt, upload: Double(outDelta) / dt)

                state.lastTimestamp = snapshotTime
                state.identity = identity
                pidStates[sample.pid] = state
            } else {
                // First time seeing this PID — initialize, no speed yet.
                pidStates[sample.pid] = PidState(
                    lastBytesIn: sample.bytesIn,
                    lastBytesOut: sample.bytesOut,
                    lastTimestamp: snapshotTime,
                    sessionBytesIn: 0,
                    sessionBytesOut: 0,
                    identity: identity
                )
                lastSpeedByPid[sample.pid] = (download: 0, upload: 0)
            }
        }

        // PIDs that were tracked but didn't appear in this snapshot have zero
        // current speed. Keep their state briefly (processes flicker in and out
        // of nettop output between active sockets), then prune the truly dead
        // ones so our dictionaries don't grow without bound over a multi-day
        // session — a real leak, since every short-lived process the OS ever
        // spawns would otherwise stay resident forever and slow aggregation.
        for pid in pidStates.keys where !seenPids.contains(pid) {
            lastSpeedByPid[pid] = (download: 0, upload: 0)
        }
        prunePids(notSeenSince: snapshotTime.addingTimeInterval(-pidRetentionGrace))

        ingestConnections(connections)

        return aggregateByBundle()
    }

    /// Same delta-tracking pattern as `pidStates` but per-flow. Cumulative
    /// per-flow bytes nettop reports → positive delta → accumulate.
    ///
    /// Closed-flow pruning: when nettop reports any rows for a PID, the
    /// reported flow set is exhaustive for that tick. Any key in
    /// `connStates[pid]` not present in this tick's report belongs to a
    /// closed socket and is dropped. We deliberately don't prune PIDs absent
    /// from `samples` entirely (a PID can stay tracked across idle ticks via
    /// the pidStates grace), only flows for PIDs that *did* report.
    private func ingestConnections(_ samples: [ConnectionSample]) {
        var seenByPid: [Int32: Set<ConnKey>] = [:]
        for c in samples {
            let key = ConnKey(proto: c.proto, localIP: c.localIP,
                              localPort: c.localPort,
                              remoteIP: c.remoteIP, remotePort: c.remotePort)
            seenByPid[c.pid, default: []].insert(key)
            var byKey = connStates[c.pid] ?? [:]
            if var state = byKey[key] {
                let inDelta  = c.bytesIn  >= state.lastBytesIn  ? c.bytesIn  - state.lastBytesIn  : 0
                let outDelta = c.bytesOut >= state.lastBytesOut ? c.bytesOut - state.lastBytesOut : 0
                state.sessionBytesIn  = state.sessionBytesIn  &+ inDelta
                state.sessionBytesOut = state.sessionBytesOut &+ outDelta
                state.lastBytesIn  = c.bytesIn
                state.lastBytesOut = c.bytesOut
                byKey[key] = state
            } else {
                byKey[key] = ConnState(
                    proto: c.proto,
                    localIP: c.localIP,
                    localPort: c.localPort,
                    remoteIP: c.remoteIP,
                    remotePort: c.remotePort,
                    lastBytesIn: c.bytesIn,
                    lastBytesOut: c.bytesOut,
                    sessionBytesIn: 0,
                    sessionBytesOut: 0
                )
            }
            connStates[c.pid] = byKey
        }
        for (pid, seen) in seenByPid {
            guard var byKey = connStates[pid] else { continue }
            for k in byKey.keys where !seen.contains(k) {
                byKey[k] = nil
            }
            connStates[pid] = byKey
        }
    }

    /// Grace window before a PID absent from nettop output is evicted. Long
    /// enough to ride out a process going idle (no active socket) for a couple
    /// of minutes without losing its rolling state and re-paying identity
    /// resolution; short enough to keep memory bounded.
    private let pidRetentionGrace: TimeInterval = 120

    /// Upper bound on a plausible inter-snapshot interval (~10× the 1 Hz cadence).
    /// Past this we assume a sleep/clock anomaly and suppress the derived per-PID
    /// speed rather than report a spike. Mirrors NetworkMonitor's 10×cycleInterval.
    private static let maxPlausibleInterval: TimeInterval = 10

    /// Evict PIDs not seen since `cutoff` from every per-PID map. Cumulative
    /// All-Time totals are unaffected — those live in LifetimeUsageStore, which
    /// has already banked each PID's bytes incrementally.
    private func prunePids(notSeenSince cutoff: Date) {
        // Collect first, then mutate — never mutate a dictionary mid-iteration.
        let dead = pidStates.compactMap { $0.value.lastTimestamp < cutoff ? $0.key : nil }
        guard !dead.isEmpty else { return }
        for pid in dead {
            pidStates[pid] = nil
            lastSpeedByPid[pid] = nil
            identityCache[pid] = nil
            connStates[pid] = nil
        }
    }

    /// Sidecar map of last-tick speeds per PID. Kept separate so the PID state struct
    /// stays focused on cumulative tracking.
    private var lastSpeedByPid: [Int32: (download: Double, upload: Double)] = [:]

    /// Merge one PID's connection state into the bundle accumulator. Multiple
    /// PIDs of the same app sharing a local port (e.g. several Chrome helpers
    /// each talking on tcp:443) collapse into one AppConnection row, and their
    /// remote endpoints fold into one combined list.
    private func foldConnections(into acc: inout BundleAccumulator, pid: Int32) {
        guard let flows = connStates[pid] else { return }
        for (_, c) in flows {
            // Drop flows that never moved bytes — listen sockets / metadata that
            // would just clutter the per-app list.
            if c.sessionBytesIn == 0 && c.sessionBytesOut == 0 { continue }

            // Pick the SERVICE side. For an outbound/established flow the local
            // port is an ephemeral throwaway and the remote port is the actual
            // service (443=https, …). For a listener (remote is the "*"
            // wildcard) the local port IS the service. Grouping on the service
            // port is what makes the breakdown readable.
            let isListener = (c.remoteIP == "*" || c.remotePort == 0)
            let servicePort = isListener ? c.localPort : c.remotePort
            let normProto = normalizedProto(c.proto)

            let key = "\(normProto):\(servicePort)"
            var agg = acc.connAgg[key] ?? ConnAgg(proto: normProto, port: servicePort)
            agg.bytesIn  = agg.bytesIn  &+ c.sessionBytesIn
            agg.bytesOut = agg.bytesOut &+ c.sessionBytesOut

            // Peer rollup: the remote endpoint for outbound, "*" for listeners.
            // Key on the IP only (the port equals the service port for outbound,
            // so it carries no extra info in the peer line).
            let peerIP = isListener ? "*" : c.remoteIP
            let peerPort = isListener ? UInt16(0) : c.remotePort
            let remoteKey = peerIP
            var rem = agg.remotes[remoteKey] ?? RemoteAgg(ip: peerIP, port: peerPort)
            rem.bytesIn  = rem.bytesIn  &+ c.sessionBytesIn
            rem.bytesOut = rem.bytesOut &+ c.sessionBytesOut
            agg.remotes[remoteKey] = rem

            acc.connAgg[key] = agg
        }
    }

    /// Drop the trailing IP-family digit so tcp4/tcp6 (and udp4/udp6) to the
    /// same service collapse into one row.
    private func normalizedProto(_ proto: String) -> String {
        if proto.hasPrefix("tcp") { return "tcp" }
        if proto.hasPrefix("udp") { return "udp" }
        return proto
    }

    /// Convert the bundle's `connAgg` scratch into a sorted `[AppConnection]`.
    /// Top-level rows sorted by total bytes desc; remotes inside each row also
    /// sorted by total bytes desc.
    private func materializeConnections(_ agg: [String: ConnAgg]) -> [AppConnection] {
        agg.values.map { v -> AppConnection in
            let remotes = v.remotes.values
                .map { RemoteEndpoint(ip: $0.ip, port: $0.port,
                                      bytesIn: $0.bytesIn, bytesOut: $0.bytesOut) }
                .sorted { $0.totalBytes > $1.totalBytes }
            return AppConnection(
                proto: v.proto,
                port: v.port,
                service: ServiceDirectory.name(forPort: v.port, proto: v.proto),
                bytesIn: v.bytesIn,
                bytesOut: v.bytesOut,
                remotes: remotes
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    private func aggregateByBundle() -> [AppNetworkUsage] {
        var accumulators: [String: BundleAccumulator] = [:]

        for (pid, state) in pidStates {
            let key = state.identity.bundleIdentifier ?? state.identity.displayName
            let speed = lastSpeedByPid[pid] ?? (download: 0, upload: 0)

            if var acc = accumulators[key] {
                acc.pids.append(pid)
                acc.downloadSpeed += speed.download
                acc.uploadSpeed += speed.upload
                acc.totalBytesIn = acc.totalBytesIn &+ state.sessionBytesIn
                acc.totalBytesOut = acc.totalBytesOut &+ state.sessionBytesOut
                acc.launchedFromTerminal = acc.launchedFromTerminal || state.identity.launchedFromTerminal
                foldConnections(into: &acc, pid: pid)
                accumulators[key] = acc
            } else {
                var acc = BundleAccumulator(
                    displayName: state.identity.displayName,
                    bundleIdentifier: state.identity.bundleIdentifier,
                    bundlePath: state.identity.bundlePath,
                    pids: [pid],
                    downloadSpeed: speed.download,
                    uploadSpeed: speed.upload,
                    totalBytesIn: state.sessionBytesIn,
                    totalBytesOut: state.sessionBytesOut,
                    launchedFromTerminal: state.identity.launchedFromTerminal
                )
                foldConnections(into: &acc, pid: pid)
                accumulators[key] = acc
            }
        }

        return accumulators.map { (key, acc) in
            let representativePid = acc.pids.first ?? 0
            let origin = ProcessClassifier.origin(
                bundlePath: acc.bundlePath,
                bundleIdentifier: acc.bundleIdentifier,
                pid: representativePid
            )
            // Non-blocking on purpose: this runs on the main thread every tick, and
            // the synchronous `trust(...)` would run a disk-touching signature check
            // on a cache miss. `cachedTrust` offloads that to a background queue and
            // returns `.unknown` for one tick, so a flurry of new paths can't stall
            // the run loop (and, by extension, the menu-bar click handler).
            let trust = ProcessClassifier.cachedTrust(bundlePath: acc.bundlePath, origin: origin)

            return AppNetworkUsage(
                id: key,
                displayName: acc.displayName,
                bundleIdentifier: acc.bundleIdentifier,
                bundlePath: acc.bundlePath,
                pids: acc.pids.sorted(),
                downloadSpeed: acc.downloadSpeed,
                uploadSpeed: acc.uploadSpeed,
                totalBytesIn: acc.totalBytesIn,
                totalBytesOut: acc.totalBytesOut,
                origin: origin,
                trust: trust,
                connections: materializeConnections(acc.connAgg),
                launchedFromTerminal: acc.launchedFromTerminal
            )
        }
    }

    // MARK: - Identity Resolution

    /// Tiered lookup:
    ///   1. NSRunningApplication(processIdentifier:) — gives bundle + display name for GUI apps.
    ///   2. proc_pidpath → walk up to .app → Bundle(url:) → metadata.
    ///   3. Fallback to nettop-provided process name.
    private func resolveIdentity(pid: Int32, fallbackName: String) -> ProcessIdentity {
        // Return the cached identity only if it was resolved against the same
        // nettop command. A changed command means either the kernel recycled
        // this PID into a new process OR a live process exec'd a new image —
        // both need a fresh identity, so we fall through and re-resolve. The
        // *counter* reset that must accompany a genuine PID reuse is handled in
        // ingest(), which can see the byte-counter regression that tells reuse
        // (counters restart near zero) apart from a live exec (counters keep
        // climbing). Comparing the command (not the display name) avoids false
        // misses for bundle helpers whose display name differs from their
        // process name.
        if let cached = identityCache[pid], cached.command == fallbackName {
            return cached
        }

        // 1. NSRunningApplication
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            let display = app.localizedName ?? fallbackName
            let bundleId = app.bundleIdentifier
            let bundlePath = app.bundleURL?.path
            let identity = ProcessIdentity(
                displayName: display,
                bundleIdentifier: bundleId,
                bundlePath: bundlePath,
                command: fallbackName,
                launchedFromTerminal: false
            )
            identityCache[pid] = identity
            return identity
        }

        // Past the GUI-app tier we're looking at a CLI tool, daemon, or helper.
        // Whether it descends from a shell / terminal decides both the "Terminal"
        // chip AND (below) whether to prefer the binary's own name. Compute it
        // once here (cached with the identity) so the ppid walk never repeats.
        let fromTerminal = Self.launchedFromTerminal(pid: pid)
        let execPath = Self.executablePath(forPid: pid)

        // 2. Enclosing .app bundle → rich metadata (display name, bundle id).
        if let execPath = execPath,
           let appURL = Self.enclosingAppBundle(forExecutablePath: execPath),
           let bundle = Bundle(url: appURL) {
            let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? appURL.deletingPathExtension().lastPathComponent
            let identity = ProcessIdentity(
                displayName: display,
                bundleIdentifier: bundle.bundleIdentifier,
                bundlePath: appURL.path,
                command: fallbackName,
                launchedFromTerminal: fromTerminal
            )
            identityCache[pid] = identity
            return identity
        }

        // 3. No bundle. nettop's process name is usually the right label, so keep
        // it by default — it's often more descriptive than a bare binary name
        // ("SomeVendorAgent" vs "helper"). Prefer the executable's own filename
        // only in the two cases the product actually needs it:
        //   • the nettop name carries no identity — a bare version string like
        //     "2.1.99", pure digits, or empty (the "row with only a version"
        //     bug); or
        //   • the process was launched from a terminal, where the binary name is
        //     what the user recognizes.
        // bundlePath stays nil here (as before): this is a name-only fix and must
        // not newly change icon / origin / signature behavior for CLI processes.
        let display: String = {
            if let execPath = execPath, fromTerminal || Self.looksUnhelpful(fallbackName) {
                let base = URL(fileURLWithPath: execPath).lastPathComponent
                if !base.isEmpty { return base }
            }
            return fallbackName
        }()
        let identity = ProcessIdentity(
            displayName: display,
            bundleIdentifier: nil,
            bundlePath: nil,
            command: fallbackName,
            launchedFromTerminal: fromTerminal
        )
        identityCache[pid] = identity
        return identity
    }

    /// True when nettop's process name carries no useful identity — a bare
    /// version string like "2.1.99", all digits ("12345"), or empty — so the
    /// executable's own filename is the better display name. Names with any
    /// letter ("7zip", "1Password", "ffmpeg") are left untouched.
    private static func looksUnhelpful(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let versionish = CharacterSet(charactersIn: "0123456789.")
        return trimmed.unicodeScalars.allSatisfy { versionish.contains($0) }
    }

    private static func executablePath(forPid pid: Int32) -> String? {
        let bufSize = Int(4 * 1024) // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN
        var buffer = [CChar](repeating: 0, count: bufSize)
        let result = proc_pidpath(pid, &buffer, UInt32(bufSize))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func enclosingAppBundle(forExecutablePath path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        // Walk up at most 10 levels looking for an .app ancestor.
        for _ in 0..<10 {
            if url.pathExtension == "app" { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    // MARK: - Terminal-launch detection

    /// Shell / terminal-emulator / multiplexer process names. If any ancestor in
    /// the parent-pid chain is one of these, the process was launched from a
    /// terminal and earns the "Terminal" chip. Compared case-insensitively
    /// against `proc_name`, which reports the binary's own name (e.g. "zsh",
    /// "Terminal", "iTerm2").
    private static let terminalLaunchers: Set<String> = [
        // shells
        "zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh",
        // terminal emulators
        "terminal", "iterm2", "iterm", "wezterm", "wezterm-gui",
        "alacritty", "kitty", "ghostty", "hyper", "warp", "tabby", "rio",
        // multiplexers
        "tmux", "screen",
        // login-shell wrapper
        "login",
    ]

    /// Walk the parent-pid chain (bounded) looking for a terminal/shell
    /// ancestor. Uses the same libproc surface as ProcessControl. Any read
    /// failure — e.g. an ancestor owned by another user we can't inspect — ends
    /// the walk and returns false rather than guessing.
    private static func launchedFromTerminal(pid: Int32) -> Bool {
        var current = pid
        for _ in 0..<16 {
            guard let ppid = parentPid(of: current), ppid > 1 else { return false }
            if let name = procName(of: ppid),
               terminalLaunchers.contains(name.lowercased()) {
                return true
            }
            current = ppid
        }
        return false
    }

    /// Parent pid via the kernel's BSD task info. Returns nil if the process is
    /// gone or its info can't be read.
    private static func parentPid(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// The process's binary name (`proc_name`), or nil if it can't be read.
    private static func procName(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let read = proc_name(pid, &buffer, UInt32(buffer.count))
        guard read > 0 else { return nil }
        return String(cString: buffer)
    }
}
