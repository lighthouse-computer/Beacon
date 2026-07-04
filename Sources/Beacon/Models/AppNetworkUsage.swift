import Foundation
import AppKit

/// Per-application aggregated network usage. Multiple PIDs belonging to the same
/// bundle (Chrome helpers, Electron renderers, etc.) collapse into one row.
struct AppNetworkUsage: Identifiable, Equatable {
    /// Stable identifier — bundle id if known, otherwise the process name.
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let bundlePath: String?

    /// PIDs that contributed to this row in the latest sample.
    let pids: [Int32]

    /// Instantaneous speed (bytes / second), summed across pids.
    let downloadSpeed: Double
    let uploadSpeed: Double

    /// Session-cumulative bytes transferred (since this app started monitoring).
    let totalBytesIn: UInt64
    let totalBytesOut: UInt64

    /// System vs user-installed classification.
    let origin: ProcessOrigin
    /// Code-signature trust verdict.
    let trust: ProcessTrust

    /// Per-service-port connection breakdown, sorted by total bytes desc.
    /// Empty until we get any per-connection rows from nettop.
    let connections: [AppConnection]

    /// True when this app was launched from a terminal / shell (any of its
    /// PIDs has a shell or terminal emulator in its parent-pid chain). Drives
    /// the "Terminal" chip in the row. Live-only — not persisted.
    let launchedFromTerminal: Bool

    /// Convenience: is this app actively moving bytes right now?
    /// 128 B/s threshold cuts socket keepalive noise but still catches any
    /// daemon doing real work — previously was 1 KB/s which routinely hid
    /// every background process even when the meter showed traffic in total.
    var isActive: Bool {
        (downloadSpeed + uploadSpeed) >= 128
    }

    /// Total transferred (in + out) — used for sorting by lifetime data.
    var totalBytes: UInt64 {
        totalBytesIn &+ totalBytesOut
    }

    /// Total speed (in + out).
    var totalSpeed: Double {
        downloadSpeed + uploadSpeed
    }

    /// App icon, resolved from bundle path. Optional because daemons / helpers may not have one.
    var icon: NSImage? {
        guard let path = bundlePath else { return nil }
        return IconCache.shared.icon(forBundlePath: path)
    }

    // `Equatable` is compiler-synthesized — every stored property is itself
    // `Equatable`, so the synthesised conformance compares all fields including
    // displayName / bundle metadata. The previous hand-rolled `==` omitted
    // those, so late-resolved bundle info wouldn't re-trigger a SwiftUI diff.
}

/// One *service* an app talks to, grouped by the service-side port — e.g.
/// "tcp · 443 · https — 12.3 MB / 1.1 MB".
///
/// Why group on the service port and not the local port: for outbound client
/// traffic (≈all of it) the local port is an ephemeral throwaway (50708, …)
/// while the *remote* port is the real service (443=https, 5223=apns). Keying
/// on the local port produced dozens of meaningless one-off rows with blank
/// service names. We key on the service-side `(proto, port)` instead and list
/// the distinct remote peers underneath.
struct AppConnection: Identifiable, Equatable, Hashable {
    /// Stable id within an app row — `"tcp:443"` form (IP family digit dropped).
    var id: String { "\(proto):\(port)" }
    /// Transport without the IP-family digit: "tcp" / "udp".
    let proto: String
    /// Service-side port (remote port for outbound; local port for listeners).
    let port: UInt16
    /// Human-readable service name (e.g. "https"). nil when we don't know it.
    let service: String?
    let bytesIn: UInt64
    let bytesOut: UInt64
    /// Distinct remote peers that used this service, sorted by bytes desc.
    let remotes: [RemoteEndpoint]

    var totalBytes: UInt64 { bytesIn &+ bytesOut }
}

/// One remote peer of an `AppConnection`. The `*` placeholder appears for
/// listen sockets / connectionless wildcards.
struct RemoteEndpoint: Identifiable, Equatable, Hashable {
    var id: String { "\(ip):\(port)" }
    let ip: String              // "*" for wildcard
    let port: UInt16            // 0 for wildcard
    let bytesIn: UInt64
    let bytesOut: UInt64

    var totalBytes: UInt64 { bytesIn &+ bytesOut }
    var isWildcard: Bool { ip == "*" || port == 0 }
}

/// Bounded LRU cache for NSWorkspace icons. NSImages aren't tiny (~32–128 KB
/// each at our display size) and a long-running session accumulates a path
/// per ever-launched app: capping at `maxEntries` keeps total icon memory
/// bounded. The eviction order is access-time, so the rows the user actually
/// looks at stay hot.
final class IconCache {
    static let shared = IconCache()
    private let queue = DispatchQueue(label: "computer.lighthouse.beacon.iconcache")
    /// Off-main worker for `prewarm` so NSWorkspace's disk-touching icon load
    /// never runs on the render path. Serial — one icon resolve at a time is
    /// plenty, and it keeps duplicate loads for the same path rare.
    private let resolveQueue = DispatchQueue(label: "computer.lighthouse.beacon.iconcache-resolve", qos: .utility)
    private let maxEntries = 200
    /// Insertion / access order — last element is most-recently-used.
    private var order: [String] = []
    private var cache: [String: NSImage] = [:]

    func icon(forBundlePath path: String) -> NSImage? {
        // Fast path: cache hit under the lock.
        if let hit = (queue.sync { () -> NSImage? in
            if let hit = cache[path] { touch(path); return hit }
            return nil
        }) { return hit }
        // Miss: resolve OUTSIDE the lock — the NSWorkspace lookup touches disk,
        // and holding the lock across it would stall every concurrent reader for
        // the duration (the old first-render hitch). A racing double-load of the
        // same path is benign: last writer wins, both images are identical.
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 18, height: 18)
        queue.sync {
            if cache[path] == nil { order.append(path) }
            cache[path] = icon
            while order.count > maxEntries {
                let evict = order.removeFirst()
                cache.removeValue(forKey: evict)
            }
        }
        return icon
    }

    /// Resolve any not-yet-cached paths on a background queue so the next render
    /// hits the cache. Called once per tick with the current snapshot's paths;
    /// returns immediately (the membership check itself runs off-main too).
    func prewarm(_ paths: [String]) {
        resolveQueue.async { [weak self] in
            guard let self = self else { return }
            let misses = self.queue.sync { paths.filter { self.cache[$0] == nil } }
            for path in misses { _ = self.icon(forBundlePath: path) }
        }
    }

    /// Move `path` to the end of the order array. O(n) per access — fine at
    /// maxEntries=200 with hover-rate use; a linked-list LRU is overkill here.
    private func touch(_ path: String) {
        if let idx = order.firstIndex(of: path) { order.remove(at: idx) }
        order.append(path)
    }
}
