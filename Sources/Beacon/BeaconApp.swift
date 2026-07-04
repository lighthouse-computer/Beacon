import SwiftUI
import AppKit
import os.log
import Darwin
import Carbon.HIToolbox

/// Pure AppKit entry point — NO SwiftUI `App`/`Scene`.
///
/// We deliberately avoid the `@main struct: App { Settings { EmptyView() } }`
/// pattern: under `.accessory` activation, that empty Settings scene can
/// surface a stray blank "Beacon" preferences window when macOS
/// activates the app (notably right after the user grants permission in System
/// Settings). With no scene at all there is nothing for AppKit to show. All UI
/// is the status item + popover + graph panel, built by the AppDelegate.
@main
enum BeaconMain {
    /// Held for the process lifetime so the delegate isn't deallocated.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // Accessory before run() so the app never bounces in the Dock or shows
        // a default window during launch.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var viewModel: NetworkViewModel?

    /// The popover that slides down from the status item on left-click.
    /// Uses `.applicationDefined` behavior — we manage outside-click dismissal
    /// ourselves (see installOutsideClickMonitor) because the built-in
    /// `.transient` behavior misfires under `.accessory` activation.
    private var popover: NSPopover?

    /// Right-click menu (Quit). Kept separate from the popover so the existing
    /// behavior stays available via right-click / control-click.
    private var rightClickMenu: NSMenu?

    /// Global mouse-down monitor installed while the popover is open. NSPopover's
    /// `.transient` behavior depends on the app being active, but we run with
    /// `.accessory` activation policy and never become key — so AppKit's
    /// auto-dismiss never fires. The monitor catches clicks outside the popover
    /// window and closes it manually.
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    /// The popover's hosting window, captured immediately after `popover.show(...)`
    /// so the local click monitor can compare against it on the very first
    /// interior click. Without this cache, `popover.contentViewController?.view.window`
    /// can read nil on first click (the window is created lazily during the
    /// open transaction) and the local monitor closes the popover before
    /// SwiftUI delivers the click to its gesture recognizers — the "first click
    /// does nothing, second click works" bug.
    private weak var popoverContentWindow: NSWindow?

    /// Invisible 1×1 window/view we anchor the popover to. The status item
    /// button is `.variableLength` and its frame shifts every tick as the
    /// title digits resize — anchoring the popover to that frame drags the
    /// popover left and right. Anchoring to a static view in a window we
    /// position once on show keeps the popover put.
    private var popoverAnchorWindow: NSWindow?
    private var popoverAnchorView: NSView?

    /// True while the popover currently holds a LiveUIGate retain. Guarantees the
    /// gate is retained exactly once per open and released exactly once, no
    /// matter how the close is triggered (toggle, outside-click, system dismiss).
    private var popoverGateHeld = false
    /// True only during showPopover's body. The retry path closes-then-reopens
    /// the popover; the intermediate close fires popoverDidClose, which must NOT
    /// drop the gate hold mid-open. This flag tells the delegate to skip release.
    private var isShowingPopover = false

    /// Global ⌥B shortcut: toggles the popover from anywhere, always-wins,
    /// via a Carbon hot key (no Accessibility permission). See GlobalHotkey.
    private let globalHotkey = GlobalHotkey()

    /// Observer that closes the popover when the active Space changes (desktop
    /// switch or a full-screen app coming forward). A shown popover does not
    /// follow the user to the new Space, so without this it would linger on the
    /// old one. This covers standard desktop switches; the toggle's
    /// `popoverIsOnActiveSpace` check backstops full-screen transitions, which
    /// `activeSpaceDidChangeNotification` reports unreliably.
    private var spaceChangeObserver: NSObjectProtocol?

    /// Recovery for the long-uptime failure where the menu-bar item stops
    /// responding to clicks (only an app restart fixes it) and the launch-time
    /// placement race where the item realizes off-screen. The status item is
    /// created once and AppKit/WindowServer can desync or mis-place it across
    /// sleep/wake or display reconfiguration without telling us; we re-validate
    /// (and re-place / rebuild if needed) on wake, on screen-parameter changes,
    /// and on a slow timer, so a transient teardown self-heals instead of wedging.
    private var wakeObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    private var statusHealthTimer: Timer?
    /// Periodic resource-usage log. The multi-day click-death could not be pinned
    /// to a specific leak by static analysis, so we emit fd / resident-memory /
    /// cache-size counts on a slow cadence: if it recurs, the trend in Console
    /// names the culprit (rising fds → descriptor leak, rising RSS → memory leak)
    /// instead of another round of guessing.
    private var resourceLogTimer: Timer?
    private let logger = OSLog(
        subsystem: "computer.lighthouse.beacon.macos",
        category: "AppDelegate"
    )

    /// Retry cadence for the placement workaround (see `ensureStatusItemPlaced`).
    private static let statusItemPlacementInterval: TimeInterval = 0.6
    private static let statusItemMaxPlacementAttempts = 10
    /// Set once the item has been confirmed in the menu bar at least once. Lets the
    /// retry tell first-launch realization (nil window → "still realizing, wait")
    /// apart from a later desync (nil window → "lost, rebuild").
    private var statusItemHasBeenPlaced = false
    /// Guards against overlapping retry loops when several recovery triggers
    /// (wake + screen-change + health-timer) fire close together.
    private var statusItemPlacementInProgress = false
    /// When the last placement loop gave up without placing. A legitimately
    /// unplaceable item (menu bar packed full) parks off-screen exactly like the
    /// race, so without this the 30s health tick would re-run a 10-rebuild loop
    /// forever. After an exhausted loop, auto-triggered re-placement waits out a
    /// cooldown.
    private var statusItemPlacementExhaustedAt: Date?
    private static let statusItemPlacementCooldown: TimeInterval = 600

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        viewModel = NetworkViewModel()

        // Always-on menu-bar feed. This fires every tick regardless of whether
        // any window is visible, and updates the status-item title directly (an
        // AppKit label write — NOT SwiftUI), so the popover is never re-rendered
        // by the menu bar's ticking. The popover's own currentSpeed/appUsages
        // are gated separately on LiveUIGate. onSnapshot is delivered on main,
        // so this closure runs on main.
        viewModel?.onSpeedUpdate = { [weak self] speed in
            self?.updateMenuBarTitle(with: speed)
        }
        viewModel?.startMonitoring()

        setupMenuBar()
        setupPopover()

        // Migrates away from any legacy LaunchAgent plist installed by earlier builds.
        // We do NOT auto-register at login — that's now opt-in via the popover menu.
        _ = LaunchAtLoginManager.shared

        // Dismiss the popover on Space / full-screen switches.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.closePopover()
        }

        // Global ⌥B: open/close the popover from anywhere, regardless of the
        // frontmost app. Registration can fail only if another process already
        // holds ⌥B as a Carbon hot key — in which case we just run without it,
        // but log so that's diagnosable rather than a silent "shortcut does
        // nothing" mystery.
        let hotkeyRegistered = globalHotkey.register(
            keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(optionKey)
        ) { [weak self] in
            self?.togglePopoverViaHotkey()
        }
        if !hotkeyRegistered {
            os_log("Global ⌥B hot key registration failed — another app may already hold it.",
                   log: logger, type: .info)
        }

        // Place the status item (working around a launch-time placement race),
        // then install the wake/screen/health self-healing only AFTER it settles —
        // installing the observers up front adds to the very contention that
        // triggers the race. See ensureStatusItemPlaced().
        ensureStatusItemPlaced { [weak self] in self?.installStatusItemRecovery() }

        startResourceLogging()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        // Idempotent: callable again as a recovery rebuild. Remove any existing
        // (possibly wedged) item first so a rebuild can't leave a dead duplicate
        // sitting in the menu bar.
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Stable persistence key (so the item keeps its slot/position across runs
        // instead of a generic `Item-N` index that varies launch-to-launch) and an
        // explicit visible flag. Note: these do NOT fix the "invisible on launch"
        // bug — that is a status-item *placement* race handled by
        // ensureStatusItemPlaced(); see that method.
        statusItem?.autosaveName = "computer.lighthouse.beacon.macos.statusitem"
        statusItem?.isVisible = true

        // Right-click menu. NOT assigned to statusItem.menu, because that would
        // hijack left-clicks too. Instead we show it manually when the button gets a
        // right-mouse event (see statusItemClicked).
        let menu = NSMenu()
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = (LaunchAtLoginManager.shared.isEnabled
                            || LaunchAtLoginManager.shared.isPendingApproval) ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(NSMenuItem.separator())
        let resetItem = NSMenuItem(
            title: "Reset All-Time Data…",
            action: #selector(resetAllTimeData),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        rightClickMenu = menu

        // Configure the button to receive both mouse button events directly.
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateMenuBarTitle()
    }

    // MARK: - Status-Item Self-Healing

    /// True when the status item's backing window is sitting in the menu bar (top
    /// of its screen) rather than parked off-screen.
    private func statusItemIsPlaced() -> Bool {
        guard let window = statusItem?.button?.window else { return false }
        let screen = window.screen ?? NSScreen.main
        guard let screenFrame = screen?.frame else { return false }
        // A placed item's window top aligns with the menu bar (≈ screen top). When
        // macOS fails to give it a slot it parks the window near the bottom
        // (origin.y ≈ 0 or negative), so its maxY sits far below the screen top.
        // `height > 0` excludes the not-yet-realized window during early launch.
        return window.frame.height > 0 && window.frame.maxY >= screenFrame.maxY - 40
    }

    /// Work around a macOS status-item placement race.
    ///
    /// Under the main-thread load of launch — and occasionally on wake / display
    /// change — `NSStatusBar` fails to realize the item into the menu bar and parks
    /// its backing window off-screen. `isVisible` stays true and the watchdog sees
    /// a live button with a window, so nothing else catches it. The failure is
    /// probabilistic and a single rebuild can also lose the race, so we re-create
    /// the item until its window is confirmed placed. `onPlaced` runs once the loop
    /// settles (placed or exhausted); launch uses it to install the recovery
    /// observers only AFTER placement, since installing them up front adds to the
    /// very contention that triggers the race (measured: synchronous install parked
    /// the item every launch; deferred, it places).
    private func ensureStatusItemPlaced(attempt: Int = 0, onPlaced: (() -> Void)? = nil) {
        if attempt == 0 {
            guard !statusItemPlacementInProgress else { return }
            statusItemPlacementInProgress = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusItemPlacementInterval) { [weak self] in
            guard let self else { return }
            if self.statusItemIsPlaced() {
                os_log("Status item placed (attempt %ld)", log: self.logger, type: .info, attempt)
                self.statusItemHasBeenPlaced = true
                self.statusItemPlacementInProgress = false
                self.statusItemPlacementExhaustedAt = nil
                onPlaced?()
                return
            }
            if attempt >= Self.statusItemMaxPlacementAttempts {
                os_log("Status item not placed after %ld attempts", log: self.logger, type: .error, attempt)
                self.statusItemPlacementInProgress = false
                self.statusItemPlacementExhaustedAt = Date()
                onPlaced?()
                return
            }
            // Rebuild when the window is realized-but-parked, when the item is gone,
            // or when it was placed before and has now lost its window (a desync).
            // The one case we must NOT churn is first-launch realization still in
            // flight (button present, window nil, never placed) — a premature
            // rebuild there re-enters the race; wait one cycle instead.
            if self.statusItem?.button?.window != nil
                || self.statusItem?.button == nil
                || self.statusItemHasBeenPlaced {
                self.rebuildStatusItem()
            }
            self.ensureStatusItemPlaced(attempt: attempt + 1, onPlaced: onPlaced)
        }
    }

    /// Tear down and recreate the status item from scratch. `setupMenuBar()` is
    /// idempotent (removes the old item first), so this restores a fully wired,
    /// clickable item and repaints the current title.
    private func rebuildStatusItem() {
        setupMenuBar()
        // setupMenuBar paints a zero baseline; the always-on onSpeedUpdate feed
        // repaints the live title on the next tick (≤1s).
    }

    /// Install the wake / screen-change observers and the slow health-check timer
    /// that keep the menu-bar item clickable and placed across a multi-day session.
    private func installStatusItemRecovery() {
        // Sleep/wake is the most common trigger for the status item desyncing from
        // the WindowServer; re-validate as soon as the machine wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.revalidateStatusItem(trigger: "wake")
            // A popover left open across sleep can wake with a zombie window
            // `.moveToActiveSpace` can't relocate — discard it so the next open
            // rebuilds cleanly on the active Space.
            self?.resetPopoverAfterSystemEvent()
        }
        // Plugging/unplugging a display or changing arrangement can strand the
        // item's backing window on a gone screen.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.revalidateStatusItem(trigger: "screen-change")
        }
        // Backstop for a desync that fires no notification. 30s is far below human
        // patience for a dead menu bar, and the check is a couple of pointer
        // comparisons in the healthy case. Runs in `.common` so menu/modal
        // tracking can't starve it.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.revalidateStatusItem(trigger: "health-timer")
        }
        RunLoop.main.add(timer, forMode: .common)
        statusHealthTimer = timer
    }

    /// Confirm the status item is still present, placed, and armed; recover if not.
    /// Cheap and idempotent. A healthy item never flickers; a merely-disarmed
    /// button is re-wired in place.
    private func revalidateStatusItem(trigger: String) {
        // `button.window != nil` is NOT sufficient: a *parked* item (the launch
        // placement race recurring on wake / display change) has a live button and
        // window too, just off-screen. Require it to be actually placed; if missing
        // OR parked, re-run the bounded placement retry, since a lone rebuild can
        // also lose the race. The retry is re-entrancy-guarded, so overlapping
        // triggers collapse into one loop.
        guard let button = statusItem?.button, button.window != nil, statusItemIsPlaced() else {
            // Cooldown after an exhausted loop: if the item just proved
            // unplaceable across a full retry loop (most likely a genuinely full
            // menu bar, not the transient race), don't let every health tick spin
            // another 10 destroy/recreate cycles — wait out the cooldown, then
            // try again (the bar may have gained room).
            if let exhausted = statusItemPlacementExhaustedAt,
               Date().timeIntervalSince(exhausted) < Self.statusItemPlacementCooldown {
                return
            }
            os_log("Status item not placed (%{public}@) — re-placing", log: logger, type: .error, trigger)
            ensureStatusItemPlaced()
            return
        }
        // Present and placed but possibly disarmed (target/action lost): re-assert
        // wiring. No-op when already correct, so this never causes a visible change.
        if button.target !== self || button.action != #selector(statusItemClicked(_:)) {
            os_log("Status item disarmed (%{public}@) — re-wiring", log: logger, type: .error, trigger)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // MARK: - Resource Diagnostics

    /// Emit a resource-usage line every 5 minutes so a recurrence of the
    /// click-death is diagnosable from Console (a rising fd count points at a
    /// descriptor leak; rising resident memory at a heap leak; rising classifier
    /// cache at unbounded path growth). Cheap and always-on.
    private func startResourceLogging() {
        logResourceUsage()   // one line at launch for a baseline
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.logResourceUsage()
        }
        RunLoop.main.add(timer, forMode: .common)
        resourceLogTimer = timer
    }

    private func logResourceUsage() {
        let fds = Self.openFileDescriptorCount()
        let rssMB = Double(Self.residentMemoryBytes()) / (1024 * 1024)
        let caches = ProcessClassifier.cacheStats
        // `.default` (not `.info`): this bug takes days to surface, and `.info`
        // records age out of the in-memory buffer; `.default` is persisted to the
        // on-disk store so the trend from days ago is still there to read.
        os_log(
            "resource-usage fds=%ld rssMB=%.1f originCache=%ld trustCache=%ld",
            log: logger, type: .default,
            fds, rssMB, caches.origin, caches.trust
        )
    }

    /// Open file descriptors for this process (entries in /dev/fd). -1 if unreadable.
    private static func openFileDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// Resident memory in bytes via mach `task_info`. 0 if the query fails.
    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    private func setupPopover() {
        let popover = NSPopover()
        // `.applicationDefined`, NOT `.transient`. Under `.accessory` activation
        // the transient behavior installs its OWN outside-click monitor that
        // races our manual one: a click on the status button could trip the
        // transient close (flipping `isShown` to false) just before our toggle
        // runs, so the toggle would re-open instead of close — the "click does
        // nothing / flickers" bug. We own dismissal entirely via
        // installOutsideClickMonitor(), so AppKit must not also try.
        popover.behavior = .applicationDefined
        popover.animates = true
        // We are the popover's delegate so popoverDidClose can release the
        // LiveUIGate when the popover is hidden — see makePopoverContentController().
        popover.delegate = self
        self.popover = popover
    }

    /// Build the popover's SwiftUI content controller.
    ///
    /// The controller is created once and kept ALIVE across open/close, which is
    /// what makes reopen instant — no SwiftUI tree rebuild per open. Keeping it
    /// alive is safe because PopoverRootView observes view-model / store mirrors
    /// that are gated on LiveUIGate: while the popover is closed the gate is
    /// released, so those mirrors stop publishing and the hidden view does zero
    /// per-tick work. (An earlier approach destroyed this controller on close to
    /// stop the 1 Hz re-render; that removed the hidden work but made every open
    /// pay a full rebuild — the visible open delay. The gate gives us both:
    /// instant open AND no hidden work.)
    private func makePopoverContentController() -> NSViewController? {
        guard let viewModel = viewModel else { return nil }
        return NSHostingController(
            rootView: PopoverRootView(
                viewModel: viewModel,
                onQuit: { [weak self] in
                    self?.closePopover()
                    self?.quitApp()
                },
                onResetAllTime: { [weak self] in
                    self?.closePopover()
                    self?.resetAllTimeData()
                }
            )
        )
    }

    /// Update the status-item title from an explicit speed. Driven by the
    /// view-model's always-on `onSpeedUpdate` feed so the menu bar keeps ticking
    /// independently of UI visibility.
    ///
    /// Compact one-line format (`↓ N ↑ N`, no `B/s` suffix) so the item stays
    /// narrow and survives even a packed menu bar. A single space separates the
    /// download and upload readings — the ↓/↑ glyphs already delimit them, so a
    /// gap reads cleaner than a punctuation separator.
    private func updateMenuBarTitle(with speed: NetworkSpeed) {
        guard let button = statusItem?.button else { return }
        let down = Self.compactSpeed(speed.downloadSpeed)
        let up = Self.compactSpeed(speed.uploadSpeed)
        button.title = "↓ \(down) ↑ \(up)"
    }

    /// Menu-bar-only speed formatter. Drops the `B/s` suffix (implied by context)
    /// and short-circuits to a single character for the unit (K/M/G). One decimal
    /// only when the value is small enough to fit. Tuned for visual brevity, not
    /// general-purpose use — see `FormatUtility.formatSpeed` for the verbose form
    /// used inside the popover.
    private static func compactSpeed(_ speed: Double) -> String {
        // Same non-finite guard as FormatUtility.formatSpeed: NaN fails `<= 0`
        // and would render literally as "↓nan" in the menu bar.
        guard speed.isFinite, speed > 0 else { return "0" }
        let units = ["B", "K", "M", "G"]
        var value = speed
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return String(format: "%.0f%@", value, units[unitIndex])
        }
        return value < 10
            ? String(format: "%.1f%@", value, units[unitIndex])
            : String(format: "%.0f%@", value, units[unitIndex])
    }

    /// Initial title before the first snapshot arrives.
    private func updateMenuBarTitle() {
        updateMenuBarTitle(with: NetworkSpeed(timestamp: Date(), downloadSpeed: 0, uploadSpeed: 0))
    }

    // MARK: - Click Handling

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // `NSApp.currentEvent` is occasionally nil when this action fires for a
        // status item (more so under `.accessory` activation). The old
        // `guard let event = NSApp.currentEvent else { return }` then silently
        // dropped the click — that's the "left-click does nothing" bug. Default
        // to the common case (toggle the popover) whenever we can't read the
        // event, and only branch to the menu when we positively detect a
        // right-click or control-click.
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if wantsMenu {
            showRightClickMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showRightClickMenu() {
        guard let button = statusItem?.button, let menu = rightClickMenu else { return }
        // Right-click while the popover is open: dismiss the popover first so
        // we don't have two competing UIs on screen. Without this the popover
        // sits behind the right-click menu (and the chart panel, if any).
        if popover?.isShown == true { closePopover() }
        // Refresh checkmark before showing so it reflects current SMAppService status.
        if let item = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) }) {
            item.state = (LaunchAtLoginManager.shared.isEnabled
                          || LaunchAtLoginManager.shared.isPendingApproval) ? .on : .off
        }
        // Pop up directly without binding the menu to the status item — keeps
        // left-clicks routing to togglePopover instead of falling through to
        // the menu.
        let point = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    @objc private func toggleLaunchAtLogin() {
        // Toggle off the *effective* state the checkmark shows, which includes
        // .requiresApproval. Deriving it from isEnabled alone made the item
        // un-uncheckable while approval was pending: isEnabled is still false
        // there, so a click meant "turn ON" → register() again → System Settings
        // yanked open again, forever. Now that click unregisters.
        let nowEnabled = !(LaunchAtLoginManager.shared.isEnabled
                           || LaunchAtLoginManager.shared.isPendingApproval)
        guard !LaunchAtLoginManager.shared.setEnabled(nowEnabled) else { return }
        // setEnabled returned false → the registration change threw (app running
        // from a temporary/quarantined location, or MDM/profile blocks it).
        // Without surfacing it, the menu checkmark silently reverts on next open
        // and the user has no idea why. (`.requiresApproval` is handled inside
        // setEnabled, which opens Login Items — that path is not a failure.)
        let alert = NSAlert()
        alert.messageText = nowEnabled
            ? "Couldn’t turn on Launch at Login"
            : "Couldn’t turn off Launch at Login"
        alert.informativeText = "macOS rejected the change. If the app is running from a temporary or quarantined location, move it to your Applications folder and try again — or set it in System Settings → General → Login Items."
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// ⌥B handler. Toggles the popover exactly like a status-item left-click,
    /// anchored to the status button — but when this gesture *opens* the popover
    /// it also asks the SwiftUI content to focus the search field so the user
    /// can type immediately. On close it does nothing extra.
    private func togglePopoverViaHotkey() {
        guard let button = statusItem?.button else { return }
        // "Already frontmost" = visible AND on the Space the user is looking at.
        // A stranded popover (visible but on another desktop) counts as NOT
        // frontmost, so ⌥B brings it to the current Space and still focuses
        // search — matching togglePopover's own active-Space decision.
        let wasFrontmost = isPopoverActuallyVisible && popoverIsOnActiveSpace
        togglePopover(button)
        guard !wasFrontmost, popover?.isShown == true else { return }
        // Defer one runloop turn so the popover's window is key and its SwiftUI
        // field is mounted before we ask it to take first-responder focus —
        // mirrors the auto-search monitor's own deferred focus.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .beaconFocusPopoverSearch, object: nil)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        // Decide from the popover's REAL on-screen window, NOT NSPopover.isShown.
        //
        // This is the fix for "the menu-bar icon stops opening the window after
        // a day of uptime." Over long sessions (display sleep/wake, Space
        // changes, memory pressure) macOS can tear the popover's window down
        // without flipping `isShown` back to false. Code that trusts `isShown`
        // then wedges permanently: every click sees `isShown == true`, takes the
        // close branch on an already-invisible popover, and never reopens — only
        // an app restart clears it. Deriving "is it really visible" from the
        // window makes the toggle self-correcting on the very next click.
        //
        // Close ONLY when the popover is genuinely visible AND on the Space the
        // user is looking at right now. If it's shown but stranded on another
        // desktop or behind a full-screen app (`!popoverIsOnActiveSpace`), fall
        // through to the open path so the click BRINGS it to the current Space
        // rather than closing an already-offscreen copy — the "icon does nothing
        // on another desktop, yet the window is still open back on desktop 1"
        // bug, which the auto-close observer alone can't catch across
        // full-screen transitions.
        if isPopoverActuallyVisible, popoverIsOnActiveSpace {
            closePopover()
        } else {
            // Clear any wedged state (isShown stuck true, orphaned monitors,
            // stale cached window) so the open always starts from a clean slate.
            // Close WITHOUT animation so popoverDidClose fires synchronously now
            // rather than ~0.2s later, mid-reopen — an animated close would nil
            // the contentViewController of the popover we're about to show. See
            // closeWithoutAnimation.
            if let popover = popover, popover.isShown {
                closeWithoutAnimation(popover)
            }
            removeOutsideClickMonitor()
            popoverContentWindow = nil
            showPopover(from: sender)
        }
    }

    /// Whether the popover is genuinely on screen. `NSPopover.isShown` alone is
    /// unreliable across day-long uptimes (see `togglePopover`), so we confirm
    /// the content actually has a visible window before believing it.
    private var isPopoverActuallyVisible: Bool {
        guard let popover = popover, popover.isShown,
              let window = popover.contentViewController?.view.window
        else { return false }
        return window.isVisible
    }

    /// Whether the popover's window is on the Space the user is looking at right
    /// now. The toggle uses this to tell a genuinely-frontmost popover (→ close)
    /// apart from one stranded on another desktop / behind a full-screen app
    /// (→ re-show on the active Space). `activeSpaceDidChangeNotification` is
    /// unreliable across full-screen transitions, so this window-level check is
    /// the reliable signal.
    private var popoverIsOnActiveSpace: Bool {
        popover?.contentViewController?.view.window?.isOnActiveSpace ?? false
    }

    private func showPopover(from sender: NSStatusBarButton) {
        // Rebuild the NSPopover object itself if it's missing or was torn down —
        // cheap, and guarantees we never try to present a wedged instance.
        if popover == nil { setupPopover() }
        guard let popover = popover else { return }

        // Suppress gate-release from popoverDidClose for the duration of this
        // method: the retry path below closes-then-reopens the popover, and that
        // intermediate close must not drop the gate hold we take for this open.
        isShowingPopover = true
        defer { isShowingPopover = false }

        // Force the app active before showing so the popover's hosting window
        // becomes key on first display. Under `.accessory` policy the app stays
        // inactive by default, which would leave the popover non-key and eat the
        // first interior click. Activation is transient — closing the popover
        // returns focus to the previously-active app.
        NSApp.activate(ignoringOtherApps: true)

        // Build (or reuse) the content. The controller is kept alive across
        // close now, so this normally reuses the existing one — the instant-open
        // path. It's only rebuilt if it was never created or got torn down.
        if popover.contentViewController == nil {
            popover.contentViewController = makePopoverContentController()
        }

        // Open the live-UI gate BEFORE showing. retain() synchronously runs the
        // view-model / store gate observers, which flush the latest snapshot into
        // the @Published mirrors — so the reused view paints with current data on
        // its first frame instead of showing the last-visible-state for a tick.
        // Guarded so the retry path's close→reopen below doesn't drop the hold.
        holdPopoverGate()

        let anchor = anchorView(at: sender)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)

        // Verify the show produced a visible window. If AppKit silently failed
        // (e.g. our anchor window was left on a now-disconnected display), fall
        // back to anchoring directly on the status-item button and retry once.
        // The button is always on a live screen, so this last resort works even
        // when the anchor path is in a bad state — the click never no-ops.
        if popover.contentViewController?.view.window?.isVisible != true {
            // Non-animated close so popoverDidClose fires synchronously here,
            // before we rebuild + re-show — otherwise the deferred delegate
            // callback would nil the contentViewController of the retry popover.
            closeWithoutAnimation(popover)
            if popover.contentViewController == nil {
                popover.contentViewController = makePopoverContentController()
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        // Cache the popover's window so the local click monitor can match it on
        // the first interior click without the lazy-window race.
        popoverContentWindow = popover.contentViewController?.view.window
        // Bind the popover's OWN window to the Space the user is looking at
        // right now (a normal desktop OR a full-screen app's Space). We do NOT
        // own this window — NSPopover creates it during `show()`, and it takes
        // its Space association from the anchor. The anchor is already
        // `.moveToActiveSpace`, but AppKit can still leave the freshly-created
        // popover window on the Space it was first shown on, so on a secondary
        // desktop `show` "succeeds" (the window's `isVisible` is true) yet
        // nothing appears under the cursor — the "menu-bar icon does nothing on
        // other desktops" bug. The visibility-retry above can't catch it (the
        // window IS visible, just on the wrong Space). `.moveToActiveSpace` +
        // re-front lands it on whatever desktop / full-screen Space is active.
        //
        // `.moveToActiveSpace`, NOT `.canJoinAllSpaces`: the latter pins the
        // popover to EVERY Space (reads as always-on-top across all desktops).
        // Set here for the common same-Space case. A single after-show
        // assignment proved insufficient on secondary Spaces in practice (the
        // exact AppKit reason is unconfirmed — most likely that we don't own
        // this window and its Space is fixed at creation from the anchor), so
        // it is RE-ASSERTED on the next runloop turn (deferred block below) and
        // once more in `popoverDidShow`. That re-assertion is what made
        // active-Space placement reliable in the reference line.
        popoverContentWindow?.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        popoverContentWindow?.makeKeyAndOrderFront(nil)

        // Defer monitor install one runloop turn so the opening click doesn't
        // loop back into the monitor and immediately re-close the popover. Guard
        // on the popover still being shown: a rapid open→close→open can leave a
        // stale deferred block queued, which would otherwise install a monitor
        // after the popover is already gone.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.popover?.isShown == true else { return }
            // Re-assert the active-Space binding after the show settles, then
            // re-front so the window lands on the current Space. A single set
            // right after `show()` proved unreliable on secondary desktops (see
            // the note above); re-asserting here and in `popoverDidShow` is what
            // makes it stick. Keeps `isOnActiveSpace` truthful, which the toggle
            // relies on to detect and recover from stranding.
            self.popoverContentWindow?.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            self.popoverContentWindow?.makeKeyAndOrderFront(nil)
            self.installOutsideClickMonitor()
        }
    }

    /// Return the 1×1 anchor window's view, repositioned at the status button.
    ///
    /// We anchor the popover to this tiny helper window instead of the status
    /// button directly because the button is `.variableLength` and its frame
    /// shifts every tick as the speed digits resize — anchoring to it would drag
    /// the open popover left and right. The window is created ONCE and reused;
    /// each open repositions it onto the button's CURRENT screen rect, which
    /// also re-homes it onto whatever display the menu bar is on, so display
    /// sleep / monitor changes can't leave it stranded. (Creating a new window
    /// per open instead would leak: NSWindows with isReleasedWhenClosed = false
    /// are retained by AppKit's window list, so dropping the reference doesn't
    /// free them — thousands of opens over weeks would pile up.)
    private func anchorView(at button: NSStatusBarButton) -> NSView {
        if popoverAnchorWindow == nil {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.isReleasedWhenClosed = false
            // The anchor is repositioned and re-fronted on every open, so it
            // only needs to be on the CURRENT Space when the popover anchors to
            // it: `.moveToActiveSpace` puts it there, and the popover's own
            // window inherits that Space. `.fullScreenAuxiliary` lets it (and
            // thus the popover) appear over a full-screen app; `.ignoresCycle`
            // keeps this invisible 1×1 helper out of the ⌘` window cycle. (Was
            // `.canJoinAllSpaces` — an all-Spaces anchor left it ambiguous which
            // Space the popover's window inherited, a contributor to stranding.)
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
            popoverAnchorWindow = window
            popoverAnchorView = view
        }

        // Reposition onto the button's CURRENT screen rect each open, just below
        // the menu bar so the popover's arrow points at it.
        if let buttonWindow = button.window {
            let rectInWindow = button.convert(button.bounds, to: nil)
            let rectOnScreen = buttonWindow.convertToScreen(rectInWindow)
            popoverAnchorWindow?.setFrame(
                NSRect(x: rectOnScreen.midX - 0.5, y: rectOnScreen.minY - 0.5,
                       width: 1, height: 1),
                display: false
            )
        }
        popoverAnchorWindow?.orderFront(nil)
        // The view is always created alongside the window above, so it's non-nil
        // here; fall back to the button rather than force-unwrap so a corrupted
        // anchor can never crash (or no-op) the click path.
        return popoverAnchorView ?? button
    }

    /// Close the popover synchronously, suppressing the dismiss animation so the
    /// `popoverDidClose` delegate fires NOW rather than ~0.2s later. Essential
    /// for any close-then-immediately-reopen sequence: an animated close defers
    /// `popoverDidClose`, which nils `contentViewController` — if that lands
    /// after the reopen it blanks the freshly-shown popover. User-initiated
    /// closes (`closePopover`) keep the animation; only programmatic
    /// close-before-reopen uses this.
    private func closeWithoutAnimation(_ popover: NSPopover) {
        let wasAnimating = popover.animates
        popover.animates = false
        popover.close()
        popover.animates = wasAnimating
    }

    private func closePopover() {
        // Release the live-UI gate FIRST so the 1 Hz feed to the (still-alive)
        // view stops immediately — a hidden popover then does zero per-tick work.
        releasePopoverGate()
        // `close()` is unconditional. `performClose(nil)` walks the responder
        // chain and silently no-ops when called from a NSEvent monitor (the
        // popover isn't in the chain at that point), which is why outside
        // clicks weren't dismissing the popover.
        popover?.close()
        popoverAnchorWindow?.orderOut(nil)
        // Drop the cached window so the next open re-captures a fresh one —
        // AppKit may rebuild the popover's window between shows.
        popoverContentWindow = nil
        removeOutsideClickMonitor()
    }

    /// Discard any open popover after a system event (wake) that can leave its
    /// backing window a WindowServer zombie — one that `.moveToActiveSpace`
    /// can't relocate. Closing without animation and dropping the cached window
    /// forces the next click to rebuild a fresh popover on the active Space
    /// rather than re-showing a stranded one.
    private func resetPopoverAfterSystemEvent() {
        if let popover = popover, popover.isShown {
            closeWithoutAnimation(popover)
        }
        releasePopoverGate()
        popoverAnchorWindow?.orderOut(nil)
        popoverContentWindow = nil
        removeOutsideClickMonitor()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Keep the hosting controller ALIVE across close — this is what makes
        // reopen instant (no SwiftUI tree rebuild). It's safe to keep alive
        // because releasing the gate stops the 1 Hz data feed to the view, so a
        // hidden popover does zero per-tick work. (Nil-ing contentViewController
        // here is what caused the visible open delay; the gate replaces it.)
        //
        // Also catches a system-initiated dismiss that bypasses closePopover.
        // The guarded release is idempotent, so firing here AND from
        // closePopover never double-releases.
        //
        // Skip during showPopover's retry (close-then-reopen) — that transient
        // close must not drop the hold we're taking for the open in progress.
        if isShowingPopover { return }
        releasePopoverGate()
    }

    func popoverDidShow(_ notification: Notification) {
        // Authoritative last write of the active-Space binding, once the show
        // has fully settled. Also re-caches the window (AppKit may rebuild it
        // between shows) so the outside-click monitor matches the right one.
        guard let window = popover?.contentViewController?.view.window else { return }
        popoverContentWindow = window
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
    }

    /// Hold the live-UI gate open on behalf of the popover. Idempotent: the
    /// `popoverGateHeld` flag guarantees exactly one retain per open regardless
    /// of how many show/retry calls happen, so it always balances exactly one
    /// release — no dependency on AppKit's delegate-pairing semantics.
    private func holdPopoverGate() {
        guard !popoverGateHeld else { return }
        popoverGateHeld = true
        LiveUIGate.shared.retain()
    }

    /// Release the popover's gate hold. Idempotent — safe to call from both the
    /// explicit close path and the delegate callback.
    private func releasePopoverGate() {
        guard popoverGateHeld else { return }
        popoverGateHeld = false
        LiveUIGate.shared.release()
    }

    /// Install a global + local mouse-down monitor that closes the popover when
    /// the user clicks anywhere outside it. Needed because our app runs with
    /// `.accessory` activation policy, so `.transient` auto-dismiss doesn't fire.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            // Don't close the main popover when the user is interacting with
            // the floating chart panel (#4). The panel is a different window
            // entirely, so without this exclusion clicking inside the chart
            // would dismiss the popover.
            if GraphPanelController.shared.isPoint(inPanel: NSEvent.mouseLocation) {
                return
            }
            self?.closePopover()
        }
        // Local monitor: catches clicks INSIDE our own app's windows (other than
        // the popover content).
        //
        // Three cases pass through untouched:
        //   1. Clicks inside the popover itself — the user is interacting with
        //      our content.
        //   2. Clicks on the status item button — the button's own toggle
        //      handler will close the popover; if we close here too, the
        //      subsequent re-open path sees `isShown == false` and pops it
        //      right back open. Empirical bug, easy to miss.
        //   3. Clicks inside the floating chart panel — the panel is one of
        //      our own windows, but its purpose is to be interactable while
        //      the popover stays up (#4).
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self, let popover = self.popover, popover.isShown else { return event }
            // Match against the cached popover window AND the popover's current
            // window (in case AppKit re-hosted it). Belt-and-suspenders against
            // the first-click race where `contentViewController?.view.window`
            // momentarily reads nil.
            let liveWin = popover.contentViewController?.view.window
            if let evtWin = event.window,
               (evtWin === self.popoverContentWindow || evtWin === liveWin
                || evtWin.className.contains("Popover")) {
                return event
            }
            if let statusWindow = self.statusItem?.button?.window,
               event.window === statusWindow {
                return event
            }
            if GraphPanelController.shared.isPoint(inPanel: NSEvent.mouseLocation) {
                return event
            }
            self.closePopover()
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor  { NSEvent.removeMonitor(m); localClickMonitor  = nil }
    }

    /// Destructive — wipes the entire cross-session lifetime store after the
    /// user confirms. Wired to the status-bar right-click menu and the gear
    /// menu in the popover header (via a callback hook).
    @objc func resetAllTimeData() {
        let alert = NSAlert()
        alert.messageText = "Reset all-time data?"
        alert.informativeText = "This clears every app's cross-session total. The session totals collected since the app started keep counting; only the saved historical totals on disk are wiped. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        // We're running as `.accessory` and never become key, so a normal
        // modal sheet has nowhere to attach. Run as app-modal at status-bar
        // level so the alert actually appears above the menu bar.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            LifetimeUsageStore.shared.resetAll()
        }
        // Drop back to accessory so the dock doesn't keep us focused.
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quitApp() {
        viewModel?.stopMonitoring()
        // Flush pending persisted state. `saveBlocking` waits for the encode
        // + atomic write; the old `saveNow()` returned immediately while the
        // dispatch was still queued, so `terminate()` won the race and the
        // last few seconds of traffic + buckets were lost.
        LifetimeUsageStore.shared.saveBlocking()
        SpeedHistoryStore.shared.saveBlocking()
        NSApplication.shared.terminate(nil)
    }

    deinit {
        viewModel?.stopMonitoring()
        if let obs = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        statusHealthTimer?.invalidate()
        resourceLogTimer?.invalidate()
    }
}
