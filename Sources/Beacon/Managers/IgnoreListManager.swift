import Foundation
import Combine

/// Identifier + last-known display name of an ignored app. Storing the name
/// alongside the id means the "Ignored Apps" menu can be rendered from
/// IgnoreListManager state alone — no lookup into the live viewModel. Without
/// that decoupling, every 1Hz snapshot republished `viewModel.appUsages`,
/// SwiftUI rebuilt the parent view that owned the Menu, and any open submenu
/// closed mid-hover.
struct IgnoredApp: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
}

/// User-managed set of app identifiers to hide from the "Currently Using"
/// section. Persists across launches via UserDefaults. Apps are not removed
/// from "Top by Data" — only suppressed from the live-traffic list — so the
/// user can still see their session totals.
final class IgnoreListManager: ObservableObject {
    static let shared = IgnoreListManager()

    private let key = "computer.lighthouse.beacon.ignoredAppEntries"
    private let legacyKey = "computer.lighthouse.beacon.ignoredAppIds"
    @Published private(set) var entries: [IgnoredApp] = []

    /// Quick lookup; updated whenever entries change.
    private(set) var ignoredIds: Set<String> = []

    private init() {
        load()
    }

    func isIgnored(_ appId: String) -> Bool {
        ignoredIds.contains(appId)
    }

    func ignore(_ appId: String, displayName: String) {
        guard !ignoredIds.contains(appId) else { return }
        entries.append(IgnoredApp(id: appId, displayName: displayName))
        entries.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        ignoredIds.insert(appId)
        persist()
    }

    func unignore(_ appId: String) {
        guard ignoredIds.contains(appId) else { return }
        entries.removeAll { $0.id == appId }
        ignoredIds.remove(appId)
        persist()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        ignoredIds.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([IgnoredApp].self, from: data) {
            entries = decoded
            ignoredIds = Set(decoded.map { $0.id })
            return
        }
        // Migrate from the older Set<String> persistence.
        if let legacy = defaults.array(forKey: legacyKey) as? [String] {
            entries = legacy.map { IgnoredApp(id: $0, displayName: $0) }
            ignoredIds = Set(legacy)
            persist()
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
