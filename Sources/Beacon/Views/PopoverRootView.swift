import SwiftUI
import AppKit
import Combine

/// Root content of the menu-bar popover. A single unified list of all-time apps
/// (sorted by total bytes desc) with a live green dot before any app currently
/// using the network. Header shows the active count as a clickable badge that
/// filters the list to active-only when toggled. Clicking a row opens the
/// floating chart / port-breakdown panel beside the popover.
///
/// Two list overlays:
///   • **Search** — magnifying-glass icon in the header reveals a query field
///     and replaces the scrolling list with sections matching the query
///     across app names, PIDs, ports, and services.
///   • **Multi-select** — right-click → "Select Multiple to Hide…" enters a
///     selection mode where each click toggles a row; the action bar at the
///     top of the list bulk-applies the ignore.
struct PopoverRootView: View {
    @ObservedObject var viewModel: NetworkViewModel
    @ObservedObject private var ignored = IgnoreListManager.shared
    @ObservedObject private var lifetime = LifetimeUsageStore.shared
    var onQuit: () -> Void = {}
    /// Called when the user picks "Reset All-Time Data" from the gear menu.
    /// AppDelegate routes this to the same NSAlert-backed reset path used by
    /// the status-bar right-click menu, so confirmation behavior matches.
    var onResetAllTime: () -> Void = {}

    /// Header active-count badge toggles this — when true, only currently
    /// active apps are listed.
    @State private var filterActiveOnly: Bool = false
    /// True while the user is selecting multiple rows to bulk-ignore. While
    /// active, plain row click toggles selection instead of opening the chart.
    @State private var multiSelectMode: Bool = false
    /// IDs currently selected for bulk ignore. Cleared when multi-select mode
    /// exits.
    @State private var selectedIds: Set<String> = []
    /// True when the search field is open. Toggled by the magnifying-glass
    /// icon in the header.
    @State private var searchQuery: String = ""
    /// Sections the user has collapsed in the search results. All start
    /// expanded; the user can collapse the ones they don't care about.
    @State private var collapsedSearchSections: Set<SearchSection> = []
    @FocusState private var searchFocused: Bool
    /// AppKit local-monitor token for auto-search keystroke capture. Installed
    /// once on first appear, lives for the popover content view's lifetime
    /// (the NSHostingController persists across NSPopover close/open).
    @State private var keyMonitor: KeyMonitorHolder = KeyMonitorHolder()
    /// Search query the user has stopped typing on for at least 300ms. The
    /// "Nothing found" empty state only shows when this catches up to the
    /// live query — during active typing, the normal list stays put so the
    /// UI doesn't flash a no-match panel on the way to the eventual match.
    @State private var settledQuery: String = ""
    /// Cancellable debounce for settledQuery.
    @State private var settleDebouncer = DebounceHolder()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Search field is always visible — auto-search means the user
            // just starts typing, no toggle. Showing the field permanently
            // also makes it discoverable (no hidden icon).
            searchBar
            Divider()
            if multiSelectMode {
                multiSelectBar
                Divider()
            }
            listOrSearchResults
        }
        .frame(width: 380)
        // Top-anchor the content so an empty search result doesn't visually
        // re-center the header — when the inner VStack is shorter than the
        // min height, the unused space sits at the bottom, not above the
        // header.
        .frame(minHeight: 220, maxHeight: 560, alignment: .top)
        .onAppear { installAutoSearchMonitor() }
        .onChange(of: searchQuery) { _ in scheduleSettleDebounce() }
        // The global ⌥B shortcut posts this when it opens the popover, so the
        // search field takes focus and the user can type without a click first.
        .onReceive(NotificationCenter.default.publisher(for: .beaconFocusPopoverSearch)) { _ in
            searchFocused = true
        }
    }

    /// Switches between the normal list and search results, with a 300ms
    /// debounce window before showing "Nothing found": while the user is
    /// still typing, keep the normal list visible so a few characters
    /// don't briefly replace the whole UI with an empty-state card.
    @ViewBuilder
    private var listOrSearchResults: some View {
        let q = trimmedQuery
        if q.isEmpty {
            scrollList
        } else {
            let active = viewModel.activeAppIDs
            let liveById = LatestSnapshotStore.shared.allUsagesById()
            let model = computeSearchResults(liveById: liveById)
            if model.total > 0 {
                searchResultsScrollView(model: model, active: active, liveById: liveById)
            } else if settledQuery == q {
                // Settled (no keystroke for 300ms) AND no matches → show
                // the empty state.
                emptyRow("Nothing found for \"\(q)\"")
                    .padding(.top, 4)
            } else {
                // Still typing (or typed within the last 300ms) — keep the
                // normal list visible while the user finishes the word.
                scrollList
            }
        }
    }

    private func scheduleSettleDebounce() {
        settleDebouncer.workItem?.cancel()
        let snapshot = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.isEmpty {
            // Cleared — collapse the empty-state gate immediately.
            settledQuery = ""
            return
        }
        let item = DispatchWorkItem {
            // Re-check that the query hasn't moved since this work was
            // scheduled — if it has, a newer DispatchWorkItem will handle it.
            let now = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if now == snapshot {
                settledQuery = snapshot
            }
        }
        settleDebouncer.workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 14) {
                Label {
                    Text(FormatUtility.formatSpeed(viewModel.currentSpeed.downloadSpeed))
                        .font(.system(size: 13, weight: .medium))
                } icon: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.primary)
                }
                Label {
                    Text(FormatUtility.formatSpeed(viewModel.currentSpeed.uploadSpeed))
                        .font(.system(size: 13, weight: .medium))
                } icon: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.primary)
                }
            }
            Spacer()
            activeCountBadge
            HeaderMenuButton(onQuit: onQuit, onResetAllTime: onResetAllTime)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Green dot + count of apps currently using the network. Clickable —
    /// toggles `filterActiveOnly`. Borderless to match the gear and the
    /// search icon family; the filter-active state shows via the count
    /// using the accent colour instead of a chip background.
    private var activeCountBadge: some View {
        Button {
            filterActiveOnly.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("\(viewModel.activeAppCount)")
                    .font(.system(size: 13, weight: filterActiveOnly ? .semibold : .medium))
                    .foregroundColor(filterActiveOnly ? .accentColor : .primary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(filterActiveOnly
            ? "Showing only active apps — click to show all"
            : "\(viewModel.activeAppCount) app\(viewModel.activeAppCount == 1 ? "" : "s") active — click to filter")
    }

    // MARK: - Search bar

    /// Always-visible search field. Empty query = normal list. Non-empty
    /// query = grouped search results. Auto-search captures the first
    /// keystroke before the field is focused and seeds it; subsequent
    /// keystrokes go directly to the field.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            TextField("Search apps · PIDs · ports · services", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 12))
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    collapsedSearchSections.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Multi-select bar

    /// Action bar shown above the list while the user is selecting multiple
    /// rows to bulk-ignore. Plain click on a row toggles selection — no
    /// checkboxes, no separate gesture; the row background tints to show
    /// what's selected.
    private var multiSelectBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("\(selectedIds.count) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
            Text("Click rows to toggle. Right-click for actions.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Hide Selected") {
                hideSelected()
            }
            .controlSize(.small)
            .disabled(selectedIds.isEmpty)
            Button("Cancel") {
                exitMultiSelect()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Normal list

    private var scrollList: some View {
        // Hoist active-id set + live-snapshot dict here once per body so
        // LifetimeRowView's body doesn't recompute them per row. Without
        // this, every row paid a `queue.sync` per render.
        let active = viewModel.activeAppIDs
        let liveById = LatestSnapshotStore.shared.allUsagesById()
        let rows = computeDisplayRows(active: active)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    emptyRow(filterActiveOnly
                        ? "No apps are actively using the network"
                        : "No network activity recorded yet")
                } else {
                    ForEach(rows) { entry in
                        rowView(for: entry, active: active, liveById: liveById, matchChip: nil)
                    }
                }
            }
        }
    }

    /// Common row-builder so the search-results path uses the same row
    /// layout as the main list (with an optional match-type chip overlay).
    @ViewBuilder
    private func rowView(for entry: LifetimeUsage,
                          active: Set<String>,
                          liveById: [String: AppNetworkUsage],
                          matchChip: MatchChip?) -> some View {
        LifetimeRowView(
            entry: entry,
            isActive: active.contains(entry.id),
            live: liveById[entry.id],
            isIgnored: ignored.isIgnored(entry.id),
            isSelected: selectedIds.contains(entry.id),
            multiSelectMode: multiSelectMode,
            matchChip: matchChip,
            onToggleIgnore: {
                if ignored.isIgnored(entry.id) {
                    ignored.unignore(entry.id)
                } else {
                    ignored.ignore(entry.id, displayName: entry.displayName)
                }
            },
            onResetAll: { lifetime.resetAll() },
            onPrimaryTap: { handlePrimaryTap(entry) },
            onEnterMultiSelect: { enterMultiSelect(seed: entry) },
            onHideSelected: { hideSelected() },
            onKill: { confirmKill(entry, live: liveById[entry.id]) }
        )
    }

    /// Confirm and execute a "Kill" for a row. Lives here (not in the row) so the
    /// NSAlert and the result reporting share the popover's AppKit context. The
    /// `isKillable` gate is re-checked so a stale menu can't kill a system row.
    private func confirmKill(_ entry: LifetimeUsage, live: AppNetworkUsage?) {
        guard let live, ProcessControl.isKillable(origin: live.origin, livePids: live.pids) else { return }
        let count = live.pids.count
        let pidList = live.pids.map(String.init).joined(separator: ", ")

        let alert = NSAlert()
        alert.messageText = count == 1
            ? "Kill \(entry.displayName)?"
            : "Kill \(entry.displayName) (\(count) processes)?"
        alert.informativeText = "This ends the running process\(count == 1 ? "" : "es") now (PID \(pidList)). Unsaved work may be lost; the app can be relaunched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch ProcessControl.terminate(pids: live.pids) {
        case .terminated, .nothingToKill:
            break
        case .needsAdmin(let pids):
            presentKillFailure(name: entry.displayName,
                               text: "PID \(pids.map(String.init).joined(separator: ", ")) belong to another user or a privileged process and can’t be ended without administrator rights.")
        case .failed(let pids):
            presentKillFailure(name: entry.displayName,
                               text: "Couldn’t end PID \(pids.map(String.init).joined(separator: ", ")).")
        }
    }

    private func presentKillFailure(name: String, text: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t end \(name)"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// One-pass build: filter ignored, drop zero-byte rows, optional
    /// active-only filter, sort by bytes desc. Zero-byte filter hides apps
    /// that haven't transmitted any data yet — they're noise in the list.
    private func computeDisplayRows(active: Set<String>) -> [LifetimeUsage] {
        let ignoredIds = IgnoreListManager.shared.ignoredIds
        let filtered = lifetime.entries.values.filter { entry in
            if entry.totalBytes == 0 { return false }
            if ignoredIds.contains(entry.id) { return false }
            if filterActiveOnly && !active.contains(entry.id) { return false }
            return true
        }
        // `id` tiebreaker so equal-byte rows keep a deterministic order. The
        // input is a Dictionary's `.values` (unordered, and the order can shift
        // between ticks), so without a total order two apps with identical totals
        // would swap positions tick-to-tick — rows jittering under the cursor.
        return filtered.sorted {
            $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.id < $1.id
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    // MARK: - Search results

    /// Sections shown in the search-results view. Each is independently
    /// collapsible; an entry can appear in more than one (e.g. an app whose
    /// name AND PID both match).
    enum SearchSection: String, CaseIterable, Hashable {
        case apps = "Apps"
        case pids = "PIDs"
        case ports = "Ports"
        case services = "Services"

        var systemImage: String {
            switch self {
            case .apps:     return "app.fill"
            case .pids:     return "number.square.fill"
            case .ports:    return "antenna.radiowaves.left.and.right"
            case .services: return "bolt.horizontal.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .apps:     return .accentColor
            case .pids:     return .orange
            case .ports:    return .blue
            case .services: return .green
            }
        }
    }

    struct MatchChip: Equatable {
        let section: SearchSection
        let label: String
    }

    private struct SearchResultsModel {
        var apps: [LifetimeUsage] = []
        /// Each: app + matched PID strings (joined "1234, 5678" if multiple).
        var pids: [(LifetimeUsage, String)] = []
        /// Each: app + matched port label (e.g. "tcp · 443").
        var ports: [(LifetimeUsage, String)] = []
        /// Each: app + matched service label (e.g. "https").
        var services: [(LifetimeUsage, String)] = []

        var total: Int { apps.count + pids.count + ports.count + services.count }
    }

    @ViewBuilder
    private func searchResultsScrollView(model: SearchResultsModel,
                                         active: Set<String>,
                                         liveById: [String: AppNetworkUsage]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                searchSectionView(.apps,
                                  count: model.apps.count,
                                  content: {
                                      ForEach(model.apps) { entry in
                                          rowView(for: entry, active: active, liveById: liveById,
                                                  matchChip: MatchChip(section: .apps, label: "name"))
                                      }
                                  })
                searchSectionView(.pids,
                                  count: model.pids.count,
                                  content: {
                                      ForEach(model.pids, id: \.0.id) { pair in
                                          rowView(for: pair.0, active: active, liveById: liveById,
                                                  matchChip: MatchChip(section: .pids, label: "PID \(pair.1)"))
                                      }
                                  })
                searchSectionView(.ports,
                                  count: model.ports.count,
                                  content: {
                                      ForEach(model.ports, id: \.0.id) { pair in
                                          rowView(for: pair.0, active: active, liveById: liveById,
                                                  matchChip: MatchChip(section: .ports, label: pair.1))
                                      }
                                  })
                searchSectionView(.services,
                                  count: model.services.count,
                                  content: {
                                      ForEach(model.services, id: \.0.id) { pair in
                                          rowView(for: pair.0, active: active, liveById: liveById,
                                                  matchChip: MatchChip(section: .services, label: pair.1))
                                      }
                                  })
            }
        }
    }

    @ViewBuilder
    private func searchSectionView<Content: View>(_ section: SearchSection,
                                                  count: Int,
                                                  @ViewBuilder content: () -> Content) -> some View {
        if count > 0 {
            let isCollapsed = collapsedSearchSections.contains(section)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if isCollapsed { collapsedSearchSections.remove(section) }
                    else { collapsedSearchSections.insert(section) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 10)
                        Image(systemName: section.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(section.color)
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("(\(count))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.06))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !isCollapsed {
                    content()
                }
            }
        }
    }

    private func computeSearchResults(liveById: [String: AppNetworkUsage]) -> SearchResultsModel {
        var model = SearchResultsModel()
        let q = trimmedQuery
        guard !q.isEmpty else { return model }
        let lower = q.lowercased()
        let numericPort = UInt16(q)
        let numericPid = Int32(q)
        // Iterate over the full lifetime set (the same dataset the normal
        // list draws from), but DO NOT apply the active-only filter — the
        // user is searching across history, not the currently-active view.
        let ignoredIds = IgnoreListManager.shared.ignoredIds
        let sortedEntries = lifetime.entries.values
            .filter { $0.totalBytes > 0 && !ignoredIds.contains($0.id) }
            .sorted {
                $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.id < $1.id
            }

        for entry in sortedEntries {
            let live = liveById[entry.id]

            // Apps: name substring (case-insensitive).
            if entry.displayName.lowercased().contains(lower) {
                model.apps.append(entry)
            }

            if let live = live {
                // PIDs: only attempt if the query parses as a number AND the
                // app's live PID list contains it. Substring on stringified
                // pids would match every PID containing the digits "1" etc.
                if let pid = numericPid, live.pids.contains(pid) {
                    let label = live.pids
                        .filter { $0 == pid }
                        .map(String.init)
                        .joined(separator: ", ")
                    model.pids.append((entry, label))
                }

                // Ports: numeric exact match on connection ports.
                if let port = numericPort {
                    let hits = live.connections.filter { $0.port == port }
                    if let first = hits.first {
                        model.ports.append((entry, "\(first.proto) · \(first.port)"))
                    }
                }

                // Services: substring on the service name (lowercased).
                let serviceHits = live.connections
                    .compactMap { $0.service }
                    .filter { $0.lowercased().contains(lower) }
                if let svc = serviceHits.first {
                    model.services.append((entry, svc))
                }
            }
        }

        return model
    }

    // MARK: - Multi-select logic

    private func handlePrimaryTap(_ entry: LifetimeUsage) {
        if multiSelectMode {
            toggleSelection(entry.id)
        }
        // Outside multi-select mode, LifetimeRowView opens the chart itself
        // (it owns the on-screen frame needed for flank-positioning).
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }

    private func enterMultiSelect(seed: LifetimeUsage) {
        multiSelectMode = true
        selectedIds = [seed.id]
    }

    private func exitMultiSelect() {
        multiSelectMode = false
        selectedIds.removeAll()
    }

    private func hideSelected() {
        guard !selectedIds.isEmpty else { return }
        let snapshot = lifetime.entries
        for id in selectedIds {
            let name = snapshot[id]?.displayName ?? id
            ignored.ignore(id, displayName: name)
        }
        exitMultiSelect()
    }

    // MARK: - Auto-search keystroke capture

    /// Install a process-wide `keyDown` monitor that flips the popover into
    /// search mode the moment the user types a printable character — provided
    /// our popover is the key window and no text field is already focused.
    /// Returning nil from the handler swallows the key, so the first keystroke
    /// gets seeded into the query rather than dropped.
    private func installAutoSearchMonitor() {
        guard keyMonitor.token == nil else { return }
        keyMonitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 1. Only intercept while OUR popover is the key window.
            guard let keyWin = NSApp.keyWindow,
                  keyWin.className.contains("Popover") else { return event }

            // 2. Skip if the user is already typing in a text field — they
            //    might be in the search bar, a multi-select sheet, anywhere.
            if let responder = keyWin.firstResponder,
               responder is NSText || responder is NSTextView {
                return event
            }

            // 3. Bail on modifier-only or modifier-combo keystrokes —
            //    Cmd-Q, Opt-Tab, etc. must keep working.
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if !mods.isEmpty { return event }

            // 4. Only proceed for printable single characters.
            guard let chars = event.charactersIgnoringModifiers,
                  let scalar = chars.unicodeScalars.first,
                  isPrintableSearchSeed(scalar) else { return event }

            DispatchQueue.main.async {
                // Field is always rendered now — just seed/append and focus.
                if searchQuery.isEmpty {
                    searchQuery = String(scalar)
                } else {
                    searchQuery.append(String(scalar))
                }
                searchFocused = true
            }
            return nil
        }
    }

    private func isPrintableSearchSeed(_ scalar: Unicode.Scalar) -> Bool {
        // Allow ASCII letters, digits, common punctuation; reject control
        // characters (return, tab, escape) and arrow keys (encoded as
        // private-use scalars by AppKit).
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        if scalar.value >= 0xF700 { return false }   // function/arrow keys
        return true
    }
}

/// Box for the NSEvent monitor token so the @State can hold a reference type
/// without the SwiftUI struct needing a custom `==` (NSEvent monitors aren't
/// Equatable). The token is removed on app teardown via process exit —
/// re-installing on the second .onAppear would leak, hence the guard above.
final class KeyMonitorHolder {
    var token: Any?
    deinit {
        if let t = token { NSEvent.removeMonitor(t) }
    }
}

/// Reference box for an in-flight cancellable debounce. Same rationale as
/// KeyMonitorHolder — @State needs a stable reference for non-Equatable
/// payloads. The work item is cancelled on assignment of a new one.
final class DebounceHolder {
    var workItem: DispatchWorkItem?
    deinit { workItem?.cancel() }
}

// MARK: - Lifetime Row

/// Single row in the unified list. 3-line left + 3-line right layout, sized
/// for ~36pt icons and 10pt active dot. Owns its on-screen frame so the chart
/// panel can flank-position itself when this row is clicked.
struct LifetimeRowView: View {
    let entry: LifetimeUsage
    let isActive: Bool
    /// Live snapshot looked up ONCE in the parent and passed down. Lets the
    /// parent batch all rows' lookups into a single queue.sync.
    let live: AppNetworkUsage?
    let isIgnored: Bool
    let isSelected: Bool
    let multiSelectMode: Bool
    /// Optional match-type chip shown next to the app name in search results.
    let matchChip: PopoverRootView.MatchChip?
    let onToggleIgnore: () -> Void
    let onResetAll: () -> Void
    let onPrimaryTap: () -> Void
    let onEnterMultiSelect: () -> Void
    let onHideSelected: () -> Void
    let onKill: () -> Void

    @State private var rowFrame: CGRect = .zero

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.clear)
                .frame(width: 10, height: 10)
                .help(isActive ? "Currently using the network" : "")

            lifetimeIcon(forBundlePath: entry.bundlePath)

            // 3-line LEFT block.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let live = live {
                        trustIcon(live.trust)
                    }
                    if live?.launchedFromTerminal == true {
                        terminalChip
                    }
                    if let chip = matchChip {
                        matchChipView(chip)
                    }
                }
                HStack(spacing: 5) {
                    if let live = live {
                        originTag(live.origin)
                    }
                    Text(pidLine(live: live))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(lastActiveText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            // 3-line RIGHT block.
            VStack(alignment: .trailing, spacing: 2) {
                Text(FormatUtility.formatBytes(entry.totalBytes))
                    .font(.system(size: 12, weight: .semibold))

                Text("↓\(FormatUtility.formatBytes(entry.totalBytesIn))   ↑\(FormatUtility.formatBytes(entry.totalBytesOut))")
                    .font(.system(size: 10))
                    .foregroundColor(.primary)

                currentSpeedLine(live: live)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .background(ViewScreenFrameReader { rowFrame = $0 })
        .onTapGesture {
            if multiSelectMode {
                onPrimaryTap()
            } else {
                openGraph()
            }
        }
        .contextMenu {
            contextMenuContent
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if multiSelectMode {
            Button("Hide Selected", action: onHideSelected)
        } else {
            // Kill is only offered for non-system rows with live PIDs (see
            // ProcessControl.isKillable). Destructive role renders it red.
            if let live, ProcessControl.isKillable(origin: live.origin, livePids: live.pids) {
                Button(killLabel(for: live), role: .destructive, action: onKill)
                Divider()
            }
            Button(isIgnored ? "Show in List" : "Hide from List", action: onToggleIgnore)
            Button("Select Multiple to Hide…", action: onEnterMultiSelect)
            Divider()
            Button("Reset All-Time Data", action: onResetAll)
        }
    }

    private func killLabel(for live: AppNetworkUsage) -> String {
        live.pids.count == 1 ? "Kill Process" : "Kill \(live.pids.count) Processes"
    }

    /// Background tint: subtle accent fill while selected; transparent otherwise.
    private var rowBackground: some View {
        Rectangle()
            .fill(isSelected && multiSelectMode
                  ? Color.accentColor.opacity(0.18)
                  : Color.clear)
    }

    private func openGraph() {
        let initial: GraphTimeRange = (live?.isActive ?? false) ? .live : .oneDay
        GraphPanelController.shared.show(
            appId: entry.id,
            displayName: entry.displayName,
            nearRowFrame: rowFrame,
            initialRange: initial
        )
    }

    /// Small colored chip shown in search results to indicate which
    /// dimension matched (Apps / PIDs / Ports / Services).
    private func matchChipView(_ chip: PopoverRootView.MatchChip) -> some View {
        HStack(spacing: 3) {
            Image(systemName: chip.section.systemImage)
                .font(.system(size: 8, weight: .bold))
            Text(chip.label)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(chip.section.color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(chip.section.color.opacity(0.15)))
    }

    /// "Terminal" chip shown when the process was launched from a shell /
    /// terminal emulator (see ProcessTracker.launchedFromTerminal).
    private var terminalChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "terminal")
                .font(.system(size: 8, weight: .bold))
            Text("Terminal")
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
        .help("Launched from a terminal / shell")
    }

    /// `System` / `User` / `Other` chip.
    private func originTag(_ origin: ProcessOrigin) -> some View {
        Text(origin.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)))
    }

    /// Code-signature trust icon.
    private func trustIcon(_ trust: ProcessTrust) -> some View {
        let color: Color = {
            switch trust {
            case .trusted:   return .green
            case .untrusted: return .orange
            case .unknown:   return .secondary
            }
        }()
        return Image(systemName: trust.sfSymbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .help(trust.tooltip)
    }

    private func pidLine(live: AppNetworkUsage?) -> String {
        guard let live = live, !live.pids.isEmpty else { return "PID —" }
        return "PID \(live.pids.map(String.init).joined(separator: ", "))"
    }

    /// "Active now" when isActive; otherwise relative time since lastSeen.
    private var lastActiveText: String {
        if isActive { return "Active now" }
        return "Last active \(Self.relativeFormatter.localizedString(for: entry.lastSeen, relativeTo: Date()))"
    }

    @ViewBuilder
    private func currentSpeedLine(live: AppNetworkUsage?) -> some View {
        if let live = live, (live.downloadSpeed + live.uploadSpeed) > 0 {
            Text("↓\(FormatUtility.formatSpeed(live.downloadSpeed))  ↑\(FormatUtility.formatSpeed(live.uploadSpeed))")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.accentColor)
        } else {
            Text(" ")
                .font(.system(size: 10))
        }
    }

    @ViewBuilder
    private func lifetimeIcon(forBundlePath path: String?) -> some View {
        if let p = path, let icon = IconCache.shared.icon(forBundlePath: p) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.18))
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .frame(width: 32, height: 32)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Header Menu Button

/// Gear button in the header. Only observes IgnoreListManager so the
/// per-tick re-render of the popover doesn't close an open submenu.
struct HeaderMenuButton: View {
    @ObservedObject private var ignored = IgnoreListManager.shared
    @ObservedObject private var graphPanels = GraphPanelController.shared
    let onQuit: () -> Void
    let onResetAllTime: () -> Void

    var body: some View {
        Menu {
            if !ignored.entries.isEmpty {
                Menu("Ignored Apps (\(ignored.entries.count))") {
                    ForEach(ignored.entries) { entry in
                        Button("Restore \(entry.displayName)") {
                            ignored.unignore(entry.id)
                        }
                    }
                    Divider()
                    Button("Restore All") { ignored.clear() }
                }
                Divider()
            }
            // "Close All Charts" only makes sense once there are multiple
            // pinned panels — with 0 or 1, the per-panel X button covers it.
            if graphPanels.pinnedCount >= 2 {
                Button("Close All Charts (\(graphPanels.pinnedCount))") {
                    GraphPanelController.shared.closeAll()
                }
                Divider()
            }
            Button("Reset All-Time Data…", action: onResetAllTime)
            Divider()
            Button("Quit Beacon", action: onQuit)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
    }
}

// MARK: - Visual-Effect Background

/// Translucent backdrop so the popover and chart panel share the same
/// material chrome.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
