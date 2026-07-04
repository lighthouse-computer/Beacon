import Foundation

/// Latest-tick `AppNetworkUsage` per app id, keyed for O(1) lookup. The graph
/// panel queries this on every re-render to refresh its connection list —
/// keeping the panel decoupled from any specific view-model reference.
///
/// Not `ObservableObject` on purpose: the graph panel already re-evaluates its
/// body every second via its own ticker, so a publisher here would just be
/// noise. Reads are concurrent, writes go through a barrier.
final class LatestSnapshotStore {
    static let shared = LatestSnapshotStore()
    private init() {}

    private let queue = DispatchQueue(label: "computer.lighthouse.beacon.latestsnapshot", attributes: .concurrent)
    private var _byId: [String: AppNetworkUsage] = [:]

    func update(_ usages: [AppNetworkUsage]) {
        // Take ownership of the array snapshot, then publish atomically.
        // Last-writer-wins on the off chance two rows ever share an id. Ids are
        // unique by construction today (ProcessTracker.aggregateByBundle keys by
        // bundle id / name), but `Dictionary(uniqueKeysWithValues:)` would TRAP
        // the whole app on any future dup id — collapse defensively instead.
        let dict = Dictionary(usages.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        queue.async(flags: .barrier) {
            self._byId = dict
        }
    }

    func usage(forId id: String) -> AppNetworkUsage? {
        queue.sync { _byId[id] }
    }

    /// Snapshot of every live entry, returned in one queue hop. Used by the
    /// popover so it can look up all 60+ rows' live state without paying the
    /// queue.sync cost per row (the old per-row pattern serialized the whole
    /// render through this lock).
    func allUsagesById() -> [String: AppNetworkUsage] {
        queue.sync { _byId }
    }
}
