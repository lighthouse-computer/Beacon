import Foundation
import Combine

/// Top-level view model: subscribes to the long-lived NetworkMonitor stream and
/// publishes the two things the UI cares about — the total speed (for the menu
/// bar title) and the per-app aggregated list (for the popover).
class NetworkViewModel: ObservableObject {
    /// Total speed shown in the popover header. GATED: only assigned while a
    /// live UI surface is visible, so a hidden-but-alive popover isn't forced to
    /// re-render every tick through this channel. The menu-bar title does NOT
    /// read this — it gets its own always-on feed via `onSpeedUpdate` so it
    /// keeps ticking regardless of visibility.
    @Published var currentSpeed = NetworkSpeed(timestamp: Date(), downloadSpeed: 0, uploadSpeed: 0)
    /// Per-app list that drives the popover. Also gated on visibility.
    @Published var appUsages: [AppNetworkUsage] = []

    /// Always-on speed feed for the menu-bar title. Fired every tick whether or
    /// not any window is open. AppKit-side (a label update), not SwiftUI — so it
    /// never re-renders the popover.
    var onSpeedUpdate: ((NetworkSpeed) -> Void)?

    private let networkMonitor = NetworkMonitor()
    private let processTracker = ProcessTracker()

    /// Latest values retained every tick regardless of visibility, so they can
    /// be flushed into the gated @Published properties the instant a surface
    /// opens — the first frame is current, not up to a second stale.
    private var latestSpeed = NetworkSpeed(timestamp: Date(), downloadSpeed: 0, uploadSpeed: 0)
    private var latestUsages: [AppNetworkUsage] = []
    private var gateToken: UUID?

    func startMonitoring() {
        // Flush the latest snapshot into the published properties the moment the
        // gate opens, so an opening popover shows current data immediately
        // rather than waiting for the next tick.
        gateToken = LiveUIGate.shared.addObserver { [weak self] visible in
            guard let self = self, visible else { return }
            self.currentSpeed = self.latestSpeed
            self.appUsages = self.latestUsages
        }

        networkMonitor.onSnapshot = { [weak self] snapshot in
            guard let self = self else { return }

            let speed = NetworkSpeed(
                timestamp: snapshot.timestamp,
                downloadSpeed: snapshot.totalDownloadSpeed,
                uploadSpeed: snapshot.totalUploadSpeed
            )
            self.latestSpeed = speed
            // Always feed the menu bar — it must tick whether or not a window is
            // open. This is an AppKit label update, not SwiftUI observation.
            self.onSpeedUpdate?(speed)

            let usages = self.processTracker.ingest(
                snapshot: snapshot.processes,
                connections: snapshot.connections,
                snapshotTime: snapshot.timestamp
            )
            self.latestUsages = usages

            // Only drive the SwiftUI surfaces while one is visible. While hidden
            // the views stay alive (instant reopen) but receive no
            // objectWillChange, so they do zero per-tick work — the decoupling
            // that keeps a long-idle popover from loading the run loop.
            // The list only re-publishes on actual change (AppNetworkUsage is
            // Equatable): on a quiet system the per-tick aggregation output is
            // identical, and skipping the assign skips the full SwiftUI
            // filter+sort+row-diff pass for the whole visible list.
            if LiveUIGate.shared.isVisible {
                self.currentSpeed = speed
                if self.appUsages != usages { self.appUsages = usages }
            }

            // Resolve icons for any new bundle paths off-main BEFORE a row needs
            // them: AppNetworkUsage.icon is read inside SwiftUI `body`, and an
            // IconCache miss there does NSWorkspace disk I/O on the main thread
            // (a visible first-render hitch on popover open).
            IconCache.shared.prewarm(usages.compactMap { $0.bundlePath })

            // The stores accumulate EVERY tick regardless of UI visibility —
            // history and all-time totals must stay correct whether or not any
            // window is open. Only their @Published UI mirrors are gated, inside
            // the stores themselves.
            LifetimeUsageStore.shared.ingest(usages)
            SpeedHistoryStore.shared.ingest(usages)
            LatestSnapshotStore.shared.update(usages)
        }

        networkMonitor.start()
    }

    func stopMonitoring() {
        networkMonitor.stop()
        networkMonitor.onSnapshot = nil
        if let token = gateToken {
            LiveUIGate.shared.removeObserver(token)
            gateToken = nil
        }
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Derived Lists for the Popover

    /// IDs of apps actively moving bytes right now (≥ the isActive threshold),
    /// minus anything the user has ignored. Drives the green "live" dot in the
    /// list and the active-count badge in the header.
    var activeAppIDs: Set<String> {
        let ignored = IgnoreListManager.shared.ignoredIds
        return Set(
            appUsages
                .filter { $0.isActive && !ignored.contains($0.id) }
                .map { $0.id }
        )
    }

    /// Count of apps currently using the network (for the header badge).
    var activeAppCount: Int { activeAppIDs.count }
}
