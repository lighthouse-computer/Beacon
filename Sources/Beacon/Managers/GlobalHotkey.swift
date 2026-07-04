import AppKit
import Carbon.HIToolbox

/// A single system-wide keyboard shortcut, registered through Carbon's
/// `RegisterEventHotKey`.
///
/// Why Carbon and not an `NSEvent` global monitor: a Carbon hot key is claimed
/// *process-wide by the WindowServer* and preempts the focused app, so it fires
/// no matter which app is frontmost — and, crucially, it needs **no
/// Accessibility or Input-Monitoring permission**. An `NSEvent` global monitor
/// is passive and would require the user to grant Accessibility, which is
/// exactly the kind of extra entitlement/permission Beacon avoids. This keeps
/// the shortcut "always-wins" while staying within the app's minimal,
/// unsandboxed footprint.
///
/// One instance owns one combo. The handler is invoked on the main queue.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?

    /// Register `keyCode` (a `kVK_*` virtual key) + `modifiers` (Carbon masks
    /// such as `optionKey`). Any previously registered combo on this instance is
    /// torn down first. Returns `false` if the OS refused the registration —
    /// e.g. another process already holds this exact Carbon hot key — so the
    /// caller can decide whether to surface it. We never crash on failure: the
    /// app simply keeps working without the shortcut.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        // The Carbon handler is a bare C function pointer (no captures allowed),
        // so route back to this instance via the userData pointer.
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData = userData, let event = event else { return noErr }
                let instance = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                var firedID = EventHotKeyID()
                GetEventParameter(event,
                                  EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil,
                                  MemoryLayout<EventHotKeyID>.size,
                                  nil,
                                  &firedID)
                if firedID.signature == GlobalHotkey.signature,
                   firedID.id == GlobalHotkey.hotKeyID {
                    DispatchQueue.main.async { instance.handler?() }
                }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler)
        guard installStatus == noErr else {
            self.handler = nil
            return false
        }

        let id = EventHotKeyID(signature: GlobalHotkey.signature, id: GlobalHotkey.hotKeyID)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, id,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            // Roll the event handler back so a failed registration leaves no
            // dangling installed handler.
            if let eventHandler = eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            self.handler = nil
            return false
        }
        return true
    }

    /// Tear down the hot key and its event handler. Idempotent.
    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        handler = nil
    }

    deinit { unregister() }

    /// Four-char signature `'BCON'` scoping our hot-key id namespace, plus the
    /// single id we use (one combo per instance).
    private static let signature: OSType = 0x42434F4E  // 'BCON'
    private static let hotKeyID: UInt32 = 1
}

extension Notification.Name {
    /// Posted when the popover is opened via the global hotkey, asking the
    /// SwiftUI content to move keyboard focus into the search field so the user
    /// can start typing immediately.
    static let beaconFocusPopoverSearch = Notification.Name("computer.lighthouse.beacon.focusPopoverSearch")
}
