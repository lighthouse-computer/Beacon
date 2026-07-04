import Foundation

/// Process-wide switch that says whether any *live-updating* UI surface is
/// currently on screen (the popover, or any open chart panel).
///
/// ## Why this exists
///
/// The data pipeline runs at ~1 Hz forever — it has to, because the menu-bar
/// title and the historical stores must keep updating whether or not any window
/// is open. The presentation layer (the SwiftUI popover, the chart panels) only
/// needs fresh data while it is actually visible.
///
/// Before this gate those two cadences were fused: SwiftUI views observed the
/// 1 Hz `@Published` mirrors directly, which forced a lose-lose choice —
///   * keep the views alive while hidden → they re-render 1×/s for nothing, and
///     over a long session that wasted main-thread work was implicated in the
///     menu bar becoming unresponsive; or
///   * destroy the views on close → no hidden work, but every open rebuilds the
///     whole SwiftUI tree from scratch, which is the visible open-delay.
///
/// The gate breaks the tie. The data layer keeps ingesting and accumulating
/// every tick (history and totals stay correct), but it only pushes updates to
/// the SwiftUI mirrors **while a surface is visible**. So the views can stay
/// alive across open/close — instant open — yet do zero work while hidden.
///
/// ## Contract
///
/// * `isVisible` is the source of truth. UI controllers set it via
///   `retain()` / `release()` when their surface appears / disappears.
/// * Refcounted, so independent surfaces (popover + N chart panels) compose:
///   the gate is open while *any* of them is up, closed when the last one goes.
/// * Main-thread only. Every caller (NSPopover delegate, window lifecycle,
///   SwiftUI `onAppear`/`onDisappear`) already runs on main; keeping it
///   main-confined means no locking and no torn reads.
/// * `onChange` fires when the gate flips. The view-model subscribes so it can
///   immediately flush the latest snapshot the moment a surface opens (so the
///   first frame is current, not one tick stale).
///
/// ## v2
///
/// Every new live surface (rules inspector, per-app detail window, etc.) calls
/// `retain()` on appear and `release()` on disappear — and automatically gets
/// correct "update only while visible" behaviour with no changes to the data
/// layer. This is the seam that keeps the pipeline and the UI independently
/// evolvable.
final class LiveUIGate {
    static let shared = LiveUIGate()

    private init() {}

    /// Number of currently-visible live surfaces. Gate is open while > 0.
    private var refCount = 0

    /// Fired (on main) whenever the gate transitions open↔closed. The boolean
    /// is the new `isVisible` value. Multiple observers allowed.
    private var observers: [UUID: (Bool) -> Void] = [:]

    /// True while at least one live UI surface is on screen.
    private(set) var isVisible = false

    /// Mark a live surface as visible. Balance with `release()`.
    func retain() {
        assertMain()
        refCount += 1
        if refCount == 1 { setVisible(true) }
    }

    /// Mark a previously-retained surface as gone. Safe to over-release (clamped
    /// at zero) so a double `onDisappear` can't drive the count negative.
    func release() {
        assertMain()
        guard refCount > 0 else { return }
        refCount -= 1
        if refCount == 0 { setVisible(false) }
    }

    /// Subscribe to gate transitions. Returns a token; pass it to
    /// `removeObserver` to stop. The closure runs on the main thread.
    @discardableResult
    func addObserver(_ handler: @escaping (Bool) -> Void) -> UUID {
        assertMain()
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        assertMain()
        observers.removeValue(forKey: token)
    }

    private func setVisible(_ value: Bool) {
        guard value != isVisible else { return }
        isVisible = value
        for handler in observers.values { handler(value) }
    }

    private func assertMain() {
        // Cheap invariant check; the gate is intentionally lock-free and
        // main-confined. A violation is a programming error, not a runtime
        // condition to recover from, so assert (stripped in release builds).
        assert(Thread.isMainThread, "LiveUIGate must be used on the main thread")
    }
}
