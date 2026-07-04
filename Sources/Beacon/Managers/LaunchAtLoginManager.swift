import Foundation
import ServiceManagement
import os.log

/// Opt-in "launch at login" management via SMAppService (macOS 13+).
///
/// Replaces the previous design which silently wrote a LaunchAgent .plist into
/// ~/Library/LaunchAgents on first run — a consent violation that would get the
/// app yelled at on any forum. This wrapper exposes a binary toggle, persists
/// the user's choice in UserDefaults, and migrates away from the old plist.
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let logger = OSLog(
        subsystem: "computer.lighthouse.beacon.macos",
        category: "LaunchAtLogin"
    )
    private let userDefaultsKey = "computer.lighthouse.beacon.launchAtLogin"
    private let legacyPlistRelativePath = "Library/LaunchAgents/computer.lighthouse.beacon.autostart.plist"

    private init() {
        // Off the main thread: the migration may spawn `/bin/launchctl` and block
        // on `waitUntilExit()`, and `init()` runs synchronously during
        // `applicationDidFinishLaunching`. Only legacy upgraders reach the spawn
        // (guarded by a `fileExists` check), but blocking app launch on an external
        // process is never worth it. The cleanup has no ordering dependency.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.migrateAwayFromLegacyLaunchAgent()
        }
    }

    /// Whether the app is currently registered to launch at login.
    /// Reads SMAppService's live status, not just our persisted preference.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The persisted user choice. Distinct from `isEnabled` because system may
    /// have downgraded our registration (e.g., user disabled in Settings).
    var userPreference: Bool {
        get { UserDefaults.standard.bool(forKey: userDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: userDefaultsKey) }
    }

    /// Whether the registration is pending the user's approval in System Settings
    /// → Login Items. In this state `isEnabled` is still false (the system hasn't
    /// activated us yet), so the UI should show "pending", not a plain "off",
    /// after the user just toggled it on.
    var isPendingApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Set the desired state. Returns true on success, false on failure (logged).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                // macOS may park the registration in `.requiresApproval` (the
                // user must flip it on in Login Items). `register()` doesn't throw
                // in that case, so without this the toggle looks like it silently
                // did nothing. Point the user at the right Settings pane.
                if SMAppService.mainApp.status == .requiresApproval {
                    os_log("Launch at login needs approval in System Settings → Login Items",
                           log: logger, type: .info)
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            userPreference = enabled
            return true
        } catch {
            os_log(
                "SMAppService %{public}@ failed: %{public}@",
                log: logger, type: .error,
                enabled ? "register" : "unregister",
                error.localizedDescription
            )
            return false
        }
    }

    /// One-time cleanup: remove the silently-installed LaunchAgent plist that
    /// the old code wrote. Any user who installed a previous build still has
    /// that file sitting in ~/Library/LaunchAgents.
    private func migrateAwayFromLegacyLaunchAgent() {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(legacyPlistRelativePath)
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }

        // Best-effort unload + delete. Failures are non-fatal.
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", plistURL.path]
        unload.standardOutput = FileHandle.nullDevice
        unload.standardError = FileHandle.nullDevice
        try? unload.run()
        unload.waitUntilExit()

        do {
            try FileManager.default.removeItem(at: plistURL)
            os_log("Removed legacy LaunchAgent plist", log: logger, type: .info)
        } catch {
            // ignore
        }
    }
}
