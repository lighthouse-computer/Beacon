import SwiftUI
import AppKit
import Charts
import Combine

// MARK: - Time Range

enum GraphTimeRange: String, CaseIterable, Identifiable {
    case live = "Live (1 min)"
    case fiveMin = "Last 5 min"
    case fifteenMin = "Last 15 min"
    case oneHour = "Last 1 hour"
    case oneDay = "Last 24 hours"
    case sevenDays = "Last 7 days"
    case thirtyDays = "Last 30 days"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .live:       return 60
        case .fiveMin:    return 300
        case .fifteenMin: return 900
        case .oneHour:    return 3600
        case .oneDay:     return 86_400
        case .sevenDays:  return 604_800
        case .thirtyDays: return 2_592_000
        }
    }

    /// Finest stored tier that still covers this range cheaply.
    var resolution: SpeedHistoryStore.Resolution {
        switch self {
        case .live, .fiveMin, .fifteenMin, .oneHour: return .raw
        case .oneDay:                                return .minute
        case .sevenDays, .thirtyDays:               return .hour
        }
    }

    /// True for day-scale ranges where the x-axis should show calendar dates
    /// rather than clock times.
    var isLongRange: Bool {
        switch self {
        case .oneDay, .sevenDays, .thirtyDays: return true
        default: return false
        }
    }
}

// MARK: - Live Clock

/// Single 1 Hz broadcaster all open chart panels subscribe to. With N pinned
/// panels each owning their own `Timer.publish` we'd be firing N redundant
/// timers per second; with this everyone shares one. Auto-starts on first
/// subscriber, idles when no panel is open.
final class LiveClock: ObservableObject {
    static let shared = LiveClock()

    @Published private(set) var now: Date = Date()
    private var timer: Timer?
    private var refCount: Int = 0

    private init() {}

    /// Each panel calls this in `.onAppear` and `release()` in `.onDisappear`.
    /// The timer is created on the first acquire and torn down on the last
    /// release — no work happens when no panel is open.
    func acquire() {
        assert(Thread.isMainThread, "LiveClock must be used on the main thread")
        refCount += 1
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.now = Date()
            }
            // Run on common modes so the timer keeps firing while menus / drags
            // run a different runloop mode.
            if let t = timer { RunLoop.main.add(t, forMode: .common) }
        }
    }

    func release() {
        assert(Thread.isMainThread, "LiveClock must be used on the main thread")
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Panel Instance

/// One open chart window. Owned by `GraphPanelController`; observed by the
/// SwiftUI `ExpandedGraphView` so pin state flips re-render the header.
final class GraphPanelInstance: ObservableObject, Identifiable {
    let id = UUID()
    let appId: String
    let displayName: String
    let panel: NSPanel
    @Published var pinned: Bool = false

    init(appId: String, displayName: String, panel: NSPanel) {
        self.appId = appId
        self.displayName = displayName
        self.panel = panel
    }
}

// MARK: - Graph View

/// Floating chart panel: 3-line per-app header, dual-series chart with a
/// hover crosshair drawn as a Path overlay (cheap), resizable graph/port
/// split. Header mirrors the popover row layout so the two windows feel
/// like one product.
struct ExpandedGraphView: View {
    @ObservedObject var instance: GraphPanelInstance
    /// Pin requests bubble up to the controller (which may refuse if at cap).
    let onTogglePin: () -> Void
    /// Close button on pinned panels routes through the controller so it
    /// can drop the instance from its bookkeeping.
    let onClose: () -> Void

    @State private var range: GraphTimeRange
    /// Hoisted out of body so a drag-induced re-render never re-fetches.
    /// Refreshed only when the tick / range / appId changes.
    @State private var cachedSamples: [SpeedHistoryStore.Sample] = []
    @State private var cachedConnections: [AppConnection] = []
    @State private var cachedLive: AppNetworkUsage?
    /// Which port rows the user has expanded to see remote-IP details. Keyed
    /// by `AppConnection.id` (e.g. `"tcp:443"`).
    @State private var expandedPorts: Set<String> = []

    init(instance: GraphPanelInstance, initialRange: GraphTimeRange, onTogglePin: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.instance = instance
        self.onTogglePin = onTogglePin
        self.onClose = onClose
        self._range = State(initialValue: initialRange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            VerticalSplitView(
                topMin: 100,
                bottomMin: 100,
                defaultTopFraction: 0.42  // port-service section ≈ 1.5× the prior default
            ) {
                chartSection
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            } bottom: {
                connectionSection
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 340, minHeight: 320)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            ResizeGripView()
                .frame(width: 14, height: 14)
                .padding(2)
                .allowsHitTesting(false)
        }
        .onAppear {
            LiveClock.shared.acquire()
            refreshCaches()
        }
        .onDisappear { LiveClock.shared.release() }
        // Refresh sample cache on each tick AND on range changes. The drag
        // gesture in the split divider doesn't touch this — only the
        // .frame(height:) modifiers downstream — so the chart isn't rebuilt
        // while resizing.
        .onReceive(LiveClock.shared.$now) { _ in refreshCaches() }
        .onChange(of: range) { _ in refreshCaches() }
    }

    private func refreshCaches() {
        let newSamples = SpeedHistoryStore.shared.series(forId: instance.appId, range: range)
        if newSamples != cachedSamples { cachedSamples = newSamples }
        let live = LatestSnapshotStore.shared.usage(forId: instance.appId)
        if live != cachedLive { cachedLive = live }
        let conns = live?.connections ?? []
        if conns != cachedConnections { cachedConnections = conns }
    }

    // MARK: - Header (3 lines, mirrors the popover row layout)

    private var header: some View {
        let live = cachedLive
        let active = live?.isActive ?? false
        return VStack(alignment: .leading, spacing: 4) {
            // Row 1: activity dot · name · trust · timeframe · pin · close
            HStack(spacing: 8) {
                ActivityDot(isActive: active)
                Text(instance.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let live = live {
                    trustIcon(live.trust)
                }
                Spacer(minLength: 6)
                Picker("", selection: $range) {
                    ForEach(GraphTimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
                pinButton
                if instance.pinned { closeButton }
            }

            // Row 2: PID(s) + status (Active now / Last active …)
            HStack(spacing: 6) {
                if let live = live {
                    originTag(live.origin)
                }
                Text(pidLine(live: live))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(active ? "Active now" : "Idle")
                    .font(.system(size: 10))
                    .foregroundColor(active ? .accentColor : .secondary)
            }

            // Row 3: live ↓/↑ totals.
            HStack(spacing: 12) {
                Label {
                    Text(FormatUtility.formatSpeed(live?.downloadSpeed ?? 0))
                        .font(.system(size: 11, weight: .medium))
                } icon: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.blue)
                }
                Label {
                    Text(FormatUtility.formatSpeed(live?.uploadSpeed ?? 0))
                        .font(.system(size: 11, weight: .medium))
                } icon: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                }
            }
        }
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(instance.pinned ? .accentColor : .secondary)
                .rotationEffect(.degrees(instance.pinned ? 0 : 45))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(instance.pinned ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(instance.pinned ? "Unpin (closes this chart)" : "Pin window (keeps it open; opens new charts in their own windows)")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help("Close")
    }

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

    private func originTag(_ origin: ProcessOrigin) -> some View {
        Text(origin.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18)))
    }

    private func pidLine(live: AppNetworkUsage?) -> String {
        guard let live = live, !live.pids.isEmpty else { return "PID —" }
        return "PID \(live.pids.map(String.init).joined(separator: ", "))"
    }

    // MARK: - Chart section

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if cachedSamples.isEmpty {
                Text("No history yet for this range — wait a moment.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                // ChartCanvas owns its own hover state internally — keeping it
                // out of this parent avoids re-rendering the entire panel on
                // every mouse-moved tick. `.equatable()` makes SwiftUI skip
                // this subtree's body on parent re-renders triggered by the
                // divider drag (data unchanged → skip).
                ChartCanvas(samples: cachedSamples, range: range)
                    .equatable()
                HStack(spacing: 14) {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    Label("Upload", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Spacer()
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Connection section

    @ViewBuilder
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("PORT · SERVICE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                Spacer()
                Text("↓ / ↑")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
            }
            .padding(.horizontal, 2)
            if cachedConnections.isEmpty {
                Text("No active connections")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(cachedConnections) { conn in
                            ConnectionRowView(
                                conn: conn,
                                isExpanded: expandedPorts.contains(conn.id),
                                onToggle: { toggle(conn.id) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expandedPorts.contains(id) { expandedPorts.remove(id) }
        else { expandedPorts.insert(id) }
    }
}

// MARK: - Chart Canvas

/// The Chart + its hover crosshair, packaged together so hover state lives
/// here (not on the parent panel). Hover updates only redraw this subtree.
///
/// Conforms to `Equatable` + is invoked via `.equatable()` so SwiftUI skips
/// re-instantiating the body when the parent re-renders for an unrelated
/// reason (most importantly: the divider drag, which updates the panes'
/// `.frame(height:)` modifiers but not the chart's data). Without this, every
/// divider tick re-ran the Chart layout and the panel felt rubber-bandy.
///
/// The hover @State changes still trigger this view's body (state is owned
/// here, not compared by `==`), so the crosshair stays responsive.
private struct ChartCanvas: View, Equatable {
    let samples: [SpeedHistoryStore.Sample]
    let range: GraphTimeRange

    /// Snapped sample under the cursor. Local to this view. Updates dedup
    /// against the previous value so identical positions don't trigger
    /// re-renders.
    @State private var hoverSample: SpeedHistoryStore.Sample?

    static func == (lhs: ChartCanvas, rhs: ChartCanvas) -> Bool {
        // Array equality on a few hundred samples would be O(N) on every
        // parent diff. Cheap surrogate: same length + same head/tail
        // timestamp + same tail *magnitude*. The magnitude check matters for
        // the minute/hour tiers: there the last bucket's `start` timestamp
        // stays fixed for 60s/3600s while its running average changes every
        // tick — comparing only timestamps would skip the redraw and freeze
        // the live point until the bucket rolled over. A divider drag changes
        // neither timestamp nor magnitude, so it still skips correctly.
        lhs.range == rhs.range
            && lhs.samples.count == rhs.samples.count
            && lhs.samples.last?.t == rhs.samples.last?.t
            && lhs.samples.first?.t == rhs.samples.first?.t
            && lhs.samples.last?.down == rhs.samples.last?.down
            && lhs.samples.last?.up == rhs.samples.last?.up
    }

    /// Upper bound for the zero-based y-domain. Floored at 1 so an all-zero
    /// series never produces a degenerate `0...0` domain.
    private var yMax: Double {
        // Skip any non-finite sample: a single NaN/inf would poison the reduce and
        // hand Swift Charts a `0...NaN` domain that blanks the chart. The upstream
        // speed paths now guard against this, so this is defense-in-depth.
        let peak = samples.reduce(0.0) { acc, s in
            let d = s.down.isFinite ? s.down : 0
            let u = s.up.isFinite ? s.up : 0
            return max(acc, max(d, u))
        }
        return max(1, peak)
    }

    var body: some View {
        Chart {
            ForEach(samples, id: \.t) { s in
                LineMark(
                    x: .value("t", s.t),
                    y: .value("speed", s.down),
                    series: .value("dir", "Download")
                )
                .foregroundStyle(.blue)
                LineMark(
                    x: .value("t", s.t),
                    y: .value("speed", s.up),
                    series: .value("dir", "Upload")
                )
                .foregroundStyle(.green)
            }
        }
        .chartOverlay { proxy in
            CrosshairOverlay(samples: samples, hoverSample: $hoverSample, proxy: proxy, range: range)
        }
        // Pin the y-axis to a zero baseline. Two reasons: (1) an all-zero / flat
        // series (a freshly-tracked idle app) would otherwise hand Swift Charts a
        // zero-height domain and render a degenerate, squished axis; (2) a speed
        // chart that auto-zooms to its data range exaggerates tiny fluctuations
        // into apparent spikes — anchoring at 0 keeps magnitudes honest.
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(FormatUtility.formatSpeed(v))
                            .font(.system(size: 9))
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                if range.isLongRange {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9))
                } else {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 9))
                }
                AxisGridLine()
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Crosshair Overlay

/// Vertical + two horizontal dashed guides plus a floating value box.
/// Rendered as Rectangles (not Paths) so they're guaranteed to draw at the
/// exact pixel rows we ask for — Path stroke can antialias the line into
/// invisibility at thin widths.
private struct CrosshairOverlay: View {
    let samples: [SpeedHistoryStore.Sample]
    @Binding var hoverSample: SpeedHistoryStore.Sample?
    let proxy: ChartProxy
    /// Drives the hover label's timestamp format: day-scale ranges show a
    /// calendar date (seconds are meaningless on an hourly-bucketed chart).
    let range: GraphTimeRange

    var body: some View {
        GeometryReader { geo in
            let plot = geo[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                MouseTrackingView(
                    onMove: { localPoint in
                        let xInPlot = localPoint.x - plot.origin.x
                        guard plot.contains(localPoint),
                              let date = proxy.value(atX: xInPlot, as: Date.self),
                              let snapped = Self.nearestSample(to: date, in: samples) else {
                            if hoverSample != nil { hoverSample = nil }
                            return
                        }
                        if snapped != hoverSample { hoverSample = snapped }
                    },
                    onExit: { if hoverSample != nil { hoverSample = nil } }
                )

                if let s = hoverSample,
                   let xPos = proxy.position(forX: s.t) {
                    let xScreen = xPos + plot.origin.x

                    // Vertical dashed guide spanning the full plot height.
                    DashedLineV(color: .secondary)
                        .frame(width: 1, height: plot.height)
                        .position(x: xScreen, y: plot.midY)
                        .allowsHitTesting(false)

                    // Horizontal dashed guides at the two series values.
                    if let yDown = proxy.position(forY: s.down) {
                        let yScreen = yDown + plot.origin.y
                        DashedLineH(color: .blue)
                            .frame(width: plot.width, height: 1)
                            .position(x: plot.midX, y: yScreen)
                            .allowsHitTesting(false)
                        // Small filled dot at the data point itself.
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 5, height: 5)
                            .position(x: xScreen, y: yScreen)
                            .allowsHitTesting(false)
                    }
                    if let yUp = proxy.position(forY: s.up) {
                        let yScreen = yUp + plot.origin.y
                        DashedLineH(color: .green)
                            .frame(width: plot.width, height: 1)
                            .position(x: plot.midX, y: yScreen)
                            .allowsHitTesting(false)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                            .position(x: xScreen, y: yScreen)
                            .allowsHitTesting(false)
                    }

                    // Floating value box near the top of the plot, clamped
                    // horizontally so it never runs off either edge.
                    let labelW: CGFloat = 88
                    let labelHalfW = labelW / 2
                    let labelX = min(max(plot.minX + labelHalfW, xScreen), plot.maxX - labelHalfW)
                    let labelY = plot.minY + 20
                    crosshairLabel(sample: s)
                        .frame(width: labelW)
                        .position(x: labelX, y: labelY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func crosshairLabel(sample s: SpeedHistoryStore.Sample) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if range.isLongRange {
                    // 7d / 30d / 24h read from hourly/minute buckets — show the
                    // calendar date + time, not a spurious :SS that's always :00.
                    Text(s.t, format: .dateTime.month(.abbreviated).day().hour().minute())
                } else {
                    Text(s.t, format: .dateTime.hour().minute().second())
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.primary)
            .monospacedDigit()
            Text("↓ " + FormatUtility.formatSpeed(s.down))
                .font(.system(size: 9))
                .foregroundColor(.blue)
            Text("↑ " + FormatUtility.formatSpeed(s.up))
                .font(.system(size: 9))
                .foregroundColor(.green)
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    /// Linear scan — samples are pre-sorted and capped at a few hundred
    /// points; binary search would be overkill.
    static func nearestSample(to date: Date, in samples: [SpeedHistoryStore.Sample]) -> SpeedHistoryStore.Sample? {
        guard !samples.isEmpty else { return nil }
        let targetT = date.timeIntervalSince1970
        var best = samples[0]
        var bestDelta = abs(best.t.timeIntervalSince1970 - targetT)
        for s in samples.dropFirst() {
            let d = abs(s.t.timeIntervalSince1970 - targetT)
            if d < bestDelta { best = s; bestDelta = d }
        }
        return best
    }
}

/// 1-pixel-wide dashed vertical line built from explicit segments.
/// Path-stroked dashes sometimes antialias into invisibility at 1px width;
/// stacking discrete Rectangles guarantees pixel-accurate rendering.
private struct DashedLineV: View {
    let color: Color
    private let dash: CGFloat = 4
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let step = dash + gap
            // Guard `Int(ceil(...))`: a non-finite or non-positive `total` during a
            // transient layout/resize pass would make `Int(NaN)` trap and a negative
            // `count` crash the `ForEach(0..<count)` range. Draw nothing until the
            // geometry settles to a finite, positive size.
            let count = (total.isFinite && total > 0) ? Int(ceil(total / step)) : 0
            ZStack(alignment: .top) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .frame(width: 1, height: dash)
                        .offset(y: CGFloat(i) * step)
                }
            }
        }
    }
}

/// Horizontal version.
private struct DashedLineH: View {
    let color: Color
    private let dash: CGFloat = 4
    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let step = dash + gap
            // Guard `Int(ceil(...))`: a non-finite or non-positive `total` during a
            // transient layout/resize pass would make `Int(NaN)` trap and a negative
            // `count` crash the `ForEach(0..<count)` range. Draw nothing until the
            // geometry settles to a finite, positive size.
            let count = (total.isFinite && total > 0) ? Int(ceil(total / step)) : 0
            ZStack(alignment: .leading) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(color.opacity(0.7))
                        .frame(width: dash, height: 1)
                        .offset(x: CGFloat(i) * step)
                }
            }
        }
    }
}

// MARK: - Activity Dot

/// Steady green when the app is moving bytes; subtle outline when idle. The
/// pulse animation uses a TimelineView so we don't need to toggle a state
/// var on a timer (which was firing once and stopping).
private struct ActivityDot: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.green : Color.clear)
                .overlay(
                    Circle().stroke(Color.secondary.opacity(isActive ? 0 : 0.4), lineWidth: 1)
                )
            if isActive {
                TimelineView(.animation(minimumInterval: 1/30, paused: !isActive)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                    Circle()
                        .stroke(Color.green.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                        .scaleEffect(1.0 + 0.9 * phase)
                }
            }
        }
        .frame(width: 9, height: 9)
        .help(isActive ? "Currently using the network" : "Idle")
    }
}

// MARK: - Mouse Tracking

/// Bridges raw AppKit mouse-moved/exited events into SwiftUI state.
///
/// Why not `.onContinuousHover`: SwiftUI installs a tracking area whose
/// default activation mode is `.activeInKeyWindow`. The graph panel is a
/// `.nonactivatingPanel`, so hover events would never fire there.
/// NSTrackingArea with `.activeAlways` fires regardless of key state.
///
/// `hitTest(_:)` returns nil so clicks/scrolls flow through to underlying
/// content; tracking-area events fire from geometry, not hit-testing.
struct MouseTrackingView: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let v = TrackingNSView()
        v.onMove = onMove
        v.onExit = onExit
        return v
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onMove = onMove
        nsView.onExit = onExit
    }

    final class TrackingNSView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        private var trackingArea: NSTrackingArea?
        private var lastReportedPoint: CGPoint = .zero
        /// Skip forwarding moves smaller than this — mouseMoved fires at
        /// display refresh rate, and sub-pixel jitter is enough to make
        /// SwiftUI thrash on repeated identical-snap updates.
        private let minMove: CGFloat = 0.75

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let ta = trackingArea { removeTrackingArea(ta) }
            let ta = NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited, .mouseMoved,
                    .activeAlways, .inVisibleRect, .cursorUpdate
                ],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(ta)
            trackingArea = ta
        }

        override func mouseMoved(with event: NSEvent) {
            forwardMove(event)
        }

        override func mouseEntered(with event: NSEvent) {
            forwardMove(event)
        }

        override func mouseDragged(with event: NSEvent) {
            forwardMove(event)
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.crosshair.set()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        private func forwardMove(_ event: NSEvent) {
            let pInWindow = event.locationInWindow
            let pInView = convert(pInWindow, from: nil)
            // SwiftUI uses top-left origin; AppKit uses bottom-left. Flip y.
            let flipped = CGPoint(x: pInView.x, y: bounds.height - pInView.y)
            if abs(flipped.x - lastReportedPoint.x) < minMove,
               abs(flipped.y - lastReportedPoint.y) < minMove {
                return
            }
            lastReportedPoint = flipped
            onMove?(flipped)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Vertical Split View

/// Two-pane vertical layout with a draggable divider.
///
/// Drag tracking is implemented in **AppKit** (`DragHandleNSView` below), not
/// SwiftUI. SwiftUI's `DragGesture` is dispatched through the SwiftUI
/// gesture system, which queues events behind the runloop and races with
/// body re-evaluation — that's why the previous build had the cursor
/// running ahead of the divider. AppKit's `mouseDragged(with:)` fires
/// synchronously per OS-level event, so the divider commits each tick the
/// moment AppKit delivers it.
struct VerticalSplitView<Top: View, Bottom: View>: View {
    let topMin: CGFloat
    let bottomMin: CGFloat
    let defaultTopFraction: CGFloat
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    /// Absolute height of the top pane in points. Initialised lazily on the
    /// first GeometryReader pass since we need the container's height to
    /// convert the requested fraction into points.
    @State private var topHeight: CGFloat?
    /// Captured top-pane height at the start of a drag.
    @State private var dragStartHeight: CGFloat?

    init(
        topMin: CGFloat,
        bottomMin: CGFloat,
        defaultTopFraction: CGFloat,
        @ViewBuilder top: @escaping () -> Top,
        @ViewBuilder bottom: @escaping () -> Bottom
    ) {
        self.topMin = topMin
        self.bottomMin = bottomMin
        self.defaultTopFraction = defaultTopFraction
        self.top = top
        self.bottom = bottom
    }

    var body: some View {
        GeometryReader { geo in
            let dividerThickness: CGFloat = 8
            let total = geo.size.height
            let available = max(0, total - dividerThickness)
            let maxTop = max(topMin, available - bottomMin)

            let desired = topHeight ?? (available * defaultTopFraction)
            let topH = max(topMin, min(maxTop, desired))
            let bottomH = available - topH

            VStack(spacing: 0) {
                top()
                    .frame(height: topH, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                SplitDivider(
                    thickness: dividerThickness,
                    onDragStart: { dragStartHeight = topH },
                    onDrag: { deltaY in
                        let start = dragStartHeight ?? topH
                        let newH = start + deltaY
                        topHeight = max(topMin, min(maxTop, newH))
                    },
                    onDragEnd: { dragStartHeight = nil }
                )
                bottom()
                    .frame(height: bottomH, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
            }
            // Pull the cached height back into range when the surrounding
            // window resize shrinks the container below what we asked for.
            .onChange(of: available) { newAvail in
                if let h = topHeight {
                    let newMax = max(topMin, newAvail - bottomMin)
                    if h > newMax { topHeight = newMax }
                    if h < topMin { topHeight = topMin }
                }
            }
        }
    }
}

/// Divider rendered + handled entirely in AppKit. SwiftUI just wraps it so
/// the layout system gives it a height. The single NSView paints the line,
/// tracks hover (for the accent-colored highlight), owns the resize cursor,
/// and processes the drag — all in one place.
private struct SplitDivider: View {
    let thickness: CGFloat
    let onDragStart: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void

    var body: some View {
        DragHandleNSView(onDragStart: onDragStart, onDrag: onDrag, onDragEnd: onDragEnd)
            .frame(height: thickness)
    }
}

/// AppKit drag handle.
///
/// Critical override: `mouseDownCanMoveWindow = false`. The graph panel has
/// `isMovableByWindowBackground = true` (so the user can drag the window
/// from any non-interactive area). NSView defaults to `true` for this
/// property, which makes AppKit hijack mouseDown for window-drag before
/// `mouseDown(with:)` fires here — that was the "separator doesn't drag"
/// bug. Returning `false` tells AppKit this view is interactive.
private struct DragHandleNSView: NSViewRepresentable {
    let onDragStart: () -> Void
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onDragStart = onDragStart
        v.onDrag = onDrag
        v.onDragEnd = onDragEnd
        return v
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onDragStart = onDragStart
        nsView.onDrag = onDrag
        nsView.onDragEnd = onDragEnd
    }

    final class HandleView: NSView {
        var onDragStart: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onDragEnd: (() -> Void)?

        private var dragOriginY: CGFloat?
        private var hovering = false
        private var trackingArea: NSTrackingArea?

        // See class doc — this is THE fix that lets the divider receive
        // mouse-down when the parent panel is movableByWindowBackground.
        override var mouseDownCanMoveWindow: Bool { false }
        override var isOpaque: Bool { false }
        override var wantsDefaultClipping: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let ta = trackingArea { removeTrackingArea(ta) }
            let ta = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                owner: self, userInfo: nil
            )
            addTrackingArea(ta)
            trackingArea = ta
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeUpDown.set()
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            dragOriginY = event.locationInWindow.y
            needsDisplay = true
            onDragStart?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragOriginY else { return }
            // AppKit y is bottom-up; flip for SwiftUI top-down so the top
            // pane grows when the cursor moves down.
            let deltaY = start - event.locationInWindow.y
            onDrag?(deltaY)
        }

        override func mouseUp(with event: NSEvent) {
            dragOriginY = nil
            needsDisplay = true
            onDragEnd?()
        }

        override func draw(_ dirtyRect: NSRect) {
            let isActive = hovering || dragOriginY != nil
            // Background tint over the full 8pt hit zone while hovering or
            // dragging — communicates "this strip is interactive". Without
            // it the user couldn't tell the divider was a drag handle.
            if isActive {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                bounds.fill()
            }
            // 1pt center line, always drawn. Brighter while active.
            let lineColor = isActive
                ? NSColor.controlAccentColor
                : NSColor.separatorColor
            lineColor.setFill()
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        }

        // Make sure the divider takes mouse events on the first click even
        // when the containing panel is non-key (.nonactivatingPanel).
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - Resize Grip

private struct ResizeGripView: View {
    var body: some View {
        Canvas { ctx, size in
            let stroke = GraphicsContext.Shading.color(Color.secondary.opacity(0.5))
            for i in 0..<3 {
                let offset = CGFloat(i) * 4 + 2
                var path = Path()
                path.move(to: CGPoint(x: size.width - offset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - offset))
                ctx.stroke(path, with: stroke, lineWidth: 1)
            }
        }
    }
}

// MARK: - Connection Row

private struct ConnectionRowView: View {
    let conn: AppConnection
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 10)
                    Text(portLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let service = conn.service {
                        Text(service)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text("↓\(FormatUtility.formatBytes(conn.bytesIn))  ↑\(FormatUtility.formatBytes(conn.bytesOut))")
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                remotesList
            }
        }
    }

    private var portLabel: String {
        "\(conn.proto) · \(conn.port)"
    }

    @ViewBuilder
    private var remotesList: some View {
        if conn.remotes.isEmpty {
            Text("No remote endpoints seen yet")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.leading, 22)
                .padding(.bottom, 4)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(conn.remotes) { r in
                    HStack(spacing: 6) {
                        Image(systemName: r.isWildcard ? "antenna.radiowaves.left.and.right"
                                                       : "arrow.up.arrow.down")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .frame(width: 10)
                        Text(remoteLabel(r))
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(remoteLabel(r))
                        Spacer(minLength: 6)
                        Text("↓\(FormatUtility.formatBytes(r.bytesIn))  ↑\(FormatUtility.formatBytes(r.bytesOut))")
                            .font(.system(size: 9))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 1)
                    .padding(.leading, 22)
                    .padding(.trailing, 2)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func remoteLabel(_ r: RemoteEndpoint) -> String {
        if r.isWildcard {
            return "any peer"
        }
        return r.port == 0 ? r.ip : "\(r.ip):\(r.port)"
    }
}

// MARK: - Panel Controller

/// Owns the set of open chart panels.
///
/// Two kinds of panels coexist:
///   • One **transient** slot (auto-closes on outside-click / Space switch /
///     same-row re-click). Replaced when the user opens a chart for a
///     different app.
///   • Up to `maxPinned` **pinned** panels (default 10), each persisting
///     independently. Pinning a transient promotes it to pinned and empties
///     the transient slot.
///
/// One global outside-click monitor + one Space-change observer cover every
/// instance — we don't install N monitors for N panels. The per-second tick
/// is shared too via `LiveClock` so panel count doesn't multiply timer
/// firings.
final class GraphPanelController: ObservableObject {
    static let shared = GraphPanelController()

    /// Hard cap on simultaneously pinned panels. Above this, pin requests
    /// are ignored (with a beep). Picked to keep the chart panels useful
    /// rather than overwhelming — three pinned + one transient covers the
    /// common "compare a couple of apps live" case without turning the
    /// screen into a soup of windows.
    let maxPinned: Int = 3

    /// Number of pinned panels open right now. @Published so the gear menu
    /// in the popover can conditionally show "Close All Charts" only when
    /// the count is high enough to justify a bulk action (≥ 2).
    @Published private(set) var pinnedCount: Int = 0

    private(set) var instances: [GraphPanelInstance] = []
    /// Index into `instances` of the current transient panel, if any.
    private var transientID: UUID?

    private var clickMonitor: Any?
    /// Local monitor for clicks INSIDE our own app — specifically clicks on
    /// the main popover, which dismiss the transient chart. Pinned panels
    /// survive (the user explicitly pinned them).
    private var popoverClickMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    /// Per-instance window observers (close button, frame moves we don't
    /// care about yet). Currently only used so we drop dead instances when
    /// macOS closes their window out from under us.
    private var willCloseObservers: [UUID: NSObjectProtocol] = [:]
    /// Last transient close-by-monitor (appId + timestamp). Used by
    /// `show(appId:)` to suppress the close-then-reopen flicker that would
    /// otherwise happen when the popover-click monitor closes a transient
    /// just before its row's tap-gesture fires `show()` for the same app.
    private var lastMonitorClosedTransient: (appId: String, at: Date)?
    /// Whether this controller currently holds a LiveUIGate retain. A chart
    /// panel is a live UI surface too: while one is open the data pipeline must
    /// keep feeding the SwiftUI mirrors even if the popover is closed. We hold
    /// the gate while ≥ 1 panel is open and release when the last closes.
    private var gateHeld = false

    /// Keep the LiveUIGate hold in sync with whether any panel is open. Call
    /// after every change to `instances`. Refcounted + flag-guarded so it
    /// composes correctly with the popover's independent hold.
    private func syncGate() {
        let shouldHold = !instances.isEmpty
        if shouldHold && !gateHeld {
            gateHeld = true
            LiveUIGate.shared.retain()
        } else if !shouldHold && gateHeld {
            gateHeld = false
            LiveUIGate.shared.release()
        }
    }

    private init() {}

    /// True if `point` (AppKit screen coords) is inside ANY open panel.
    /// AppDelegate's outside-click monitors call this to avoid closing the
    /// main popover when the user clicks inside a chart.
    func isPoint(inPanel point: NSPoint) -> Bool {
        instances.contains { inst in
            inst.panel.isVisible && inst.panel.frame.insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    /// Open or focus a chart for `appId`.
    /// Behavior:
    ///   1. If a PINNED panel already exists for this app → just bring it forward.
    ///   2. If the transient slot holds this app → toggle it closed.
    ///   3. Otherwise → replace any existing transient with a new one for this app.
    func show(appId: String,
              displayName: String,
              nearRowFrame: CGRect,
              initialRange: GraphTimeRange = .live) {
        // Same-row toggle dedup. If the popover-click monitor closed a
        // transient for THIS app within the last 100ms, the user almost
        // certainly just clicked the same row that triggered the monitor
        // close — treat this as toggle-off (don't reopen) so the chart
        // doesn't flicker close+reopen.
        if let last = lastMonitorClosedTransient,
           last.appId == appId,
           Date().timeIntervalSince(last.at) < 0.1 {
            lastMonitorClosedTransient = nil
            return
        }
        lastMonitorClosedTransient = nil

        if let pinned = instances.first(where: { $0.pinned && $0.appId == appId }) {
            pinned.panel.orderFrontRegardless()
            return
        }
        if let transient = currentTransient(), transient.appId == appId {
            close(transient)
            return
        }
        // Replace existing transient (if any) and create a new one.
        if let transient = currentTransient() {
            close(transient)
        }
        let instance = makeInstance(appId: appId, displayName: displayName, initialRange: initialRange)
        positionPanel(instance.panel, near: nearRowFrame)
        instance.panel.orderFront(nil)
        instances.append(instance)
        transientID = instance.id
        syncGate()
        installCloseTriggersIfNeeded()
    }

    /// User clicked the pin button on `instance`. Pin → promote to pinned
    /// and free the transient slot. Unpin → close the panel.
    func togglePin(_ instance: GraphPanelInstance) {
        if instance.pinned {
            // Unpin = close, consistent with the help text.
            close(instance)
        } else {
            let currentPinned = instances.filter { $0.pinned }.count
            guard currentPinned < maxPinned else {
                NSSound.beep()
                return
            }
            instance.pinned = true
            if transientID == instance.id { transientID = nil }
            refreshPinnedCount()
        }
    }

    /// Close one panel. Safe to call multiple times for the same instance.
    /// Public entry point used by the close-X button on pinned panels.
    func close(_ instance: GraphPanelInstance) {
        close(instance, fromMonitor: false)
    }

    /// Internal close path. `fromMonitor: true` records the closed transient's
    /// appId so `show(appId:)` can suppress the close-then-reopen flicker if
    /// the same row's tap-gesture fires right after.
    private func close(_ instance: GraphPanelInstance, fromMonitor: Bool) {
        if fromMonitor, transientID == instance.id {
            lastMonitorClosedTransient = (instance.appId, Date())
        }
        if let obs = willCloseObservers.removeValue(forKey: instance.id) {
            NotificationCenter.default.removeObserver(obs)
        }
        // Tear down the hosting controller before hiding. The panel retains its
        // contentViewController, which retains the SwiftUI ExpandedGraphView,
        // which holds the instance, which holds the panel — a retain cycle.
        // With isReleasedWhenClosed = false and orderOut (not close), nothing
        // ever breaks it, so each transient chart leaks its whole view tree and
        // keeps observing LiveClock. Niling the contentViewController cuts the
        // cycle so the panel and its SwiftUI host deallocate on close.
        instance.panel.contentViewController = nil
        instance.panel.orderOut(nil)
        if transientID == instance.id { transientID = nil }
        instances.removeAll { $0.id == instance.id }
        if instances.isEmpty { tearDownCloseTriggers() }
        syncGate()
        refreshPinnedCount()
    }

    /// Close every open panel. Wired into the gear-menu "Close All Charts"
    /// item — only useful (and surfaced) when ≥ 2 panels are pinned.
    func closeAll() {
        for inst in instances {
            if let obs = willCloseObservers.removeValue(forKey: inst.id) {
                NotificationCenter.default.removeObserver(obs)
            }
            // Break the panel→host→view→instance→panel retain cycle (see
            // close(_:fromMonitor:)) so the closed panels actually deallocate.
            inst.panel.contentViewController = nil
            inst.panel.orderOut(nil)
        }
        instances.removeAll()
        transientID = nil
        tearDownCloseTriggers()
        syncGate()
        refreshPinnedCount()
    }

    private func refreshPinnedCount() {
        let n = instances.filter { $0.pinned }.count
        if n != pinnedCount { pinnedCount = n }
    }

    // MARK: - Internals

    private func currentTransient() -> GraphPanelInstance? {
        guard let id = transientID else { return nil }
        return instances.first { $0.id == id }
    }

    private func makeInstance(appId: String, displayName: String, initialRange: GraphTimeRange) -> GraphPanelInstance {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 540),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let instance = GraphPanelInstance(appId: appId, displayName: displayName, panel: panel)

        let view = ExpandedGraphView(
            instance: instance,
            initialRange: initialRange,
            onTogglePin: { [weak self, weak instance] in
                guard let self = self, let instance = instance else { return }
                self.togglePin(instance)
            },
            onClose: { [weak self, weak instance] in
                guard let self = self, let instance = instance else { return }
                self.close(instance)
            }
        )
        let host = NSHostingController(rootView: view)

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        // Window must be draggable from its body — the title bar is hidden
        // so there's no other handle. The divider's own NSView captures
        // mouse-down before this fires, so divider drags still work.
        panel.isMovableByWindowBackground = true
        // Tight floor so the user can park a panel in a small corner; loose
        // ceiling because tall charts on a Pro Display XDR are legitimate.
        panel.minSize = NSSize(width: 340, height: 320)
        panel.maxSize = NSSize(width: 1200, height: 1400)

        panel.contentView?.wantsLayer = true
        if let contentLayer = panel.contentView?.layer {
            contentLayer.cornerRadius = 13
            contentLayer.masksToBounds = true
            contentLayer.cornerCurve = .continuous
        }

        // If the OS or some other path closes the panel out from under us
        // (Mission Control, debugger, etc.), drop our reference so we don't
        // ship a zombie instance to the next click.
        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel, queue: .main
        ) { [weak self, weak instance] _ in
            guard let self = self, let instance = instance else { return }
            self.close(instance)
        }
        willCloseObservers[instance.id] = obs

        return instance
    }

    // MARK: - Positioning

    /// Flank the main popover by placing the panel to its right (or left when
    /// the right side has no room), vertically centred on the clicked row.
    /// When pinned panels are already on screen, offset slightly so the new
    /// panel doesn't perfectly stack on top of them.
    private func positionPanel(_ panel: NSPanel, near rowFrame: CGRect) {
        let size = panel.frame.size
        let gap: CGFloat = 6
        let centerY = rowFrame.isEmpty ? (NSScreen.main?.visibleFrame.midY ?? 0) : rowFrame.midY

        let screen = NSScreen.screens.first { $0.frame.intersects(rowFrame) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero

        var originX = rowFrame.maxX + gap
        if !visible.isEmpty, originX + size.width > visible.maxX - 4 {
            originX = rowFrame.minX - size.width - gap
        }
        // Cascade pinned-panel placement so each new panel is visually distinct.
        let cascadeStep: CGFloat = 22
        let pinnedCount = CGFloat(instances.filter { $0.pinned }.count)
        var origin = NSPoint(
            x: originX + cascadeStep * pinnedCount,
            y: centerY - size.height / 2 + cascadeStep * pinnedCount
        )
        if !visible.isEmpty {
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - size.height - 4))
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Close triggers

    private func installCloseTriggersIfNeeded() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                guard let self = self else { return }
                // Only the transient panel auto-closes on outside-click.
                // Pinned panels survive.
                guard let transient = self.currentTransient() else { return }
                if self.isPoint(inPanel: NSEvent.mouseLocation) { return }
                self.close(transient, fromMonitor: false)
            }
        }

        if popoverClickMonitor == nil {
            // Local monitor: clicks INSIDE our own app. Specifically, any
            // click on the main popover (className "Popover…") dismisses
            // the transient chart — the user has shifted focus back to the
            // list. Clicks inside a chart panel are excluded (they're
            // direct interaction with the chart).
            //
            // Returning `event` unchanged lets the click continue to its
            // target. The same-row close-then-show race is handled by the
            // dedup guard in `show(appId:)`.
            popoverClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self = self,
                      let transient = self.currentTransient() else { return event }
                if self.isPoint(inPanel: NSEvent.mouseLocation) { return event }
                if let win = event.window, win.className.contains("Popover") {
                    self.close(transient, fromMonitor: true)
                }
                return event
            }
        }

        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self = self, let transient = self.currentTransient() else { return }
                self.close(transient, fromMonitor: false)
            }
        }
    }

    private func tearDownCloseTriggers() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = popoverClickMonitor { NSEvent.removeMonitor(m); popoverClickMonitor = nil }
        if let obs = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceObserver = nil
        }
    }
}

// MARK: - Frame Reporter (still used by PopoverRootView's row click handler)

/// Reports the host view's frame in AppKit *screen* coordinates whenever
/// layout changes. PopoverRootView uses this to know each row's on-screen
/// rect so the click handler can pass it to the panel controller for
/// flank positioning.
struct ViewScreenFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void
    func makeNSView(context: Context) -> NSView { FrameReportingView(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FrameReportingView)?.scheduleReport()
    }
}

final class FrameReportingView: NSView {
    private let onChange: (CGRect) -> Void
    init(onChange: @escaping (CGRect) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReport()
    }

    func scheduleReport() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            let inWindow = self.convert(self.bounds, to: nil)
            self.onChange(window.convertToScreen(inWindow))
        }
    }
}
