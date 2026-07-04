import Foundation
import AppKit
import Darwin

/// Process termination behind the "Kill" row action (1.5.0).
///
/// Scope is deliberately narrow and safe:
/// - **Same-user only.** Other-user / root processes return `EPERM`; we surface
///   that as "needs admin" rather than pretending to succeed. Full privileged
///   kill would need the same root path the firewall (2.0) gets from its NE
///   extension — out of scope for a 1.x point release.
/// - **System processes are refused** (`isKillable`). Ending launchd /
///   mDNSResponder children can wedge the OS, so the UI never offers it.
/// - **History-only rows can't be killed** — there must be live PIDs.
///
/// The kill itself prefers a graceful quit for GUI apps (so they can run their
/// own termination / save flow) and a SIGTERM→SIGKILL escalation for non-GUI
/// processes.
enum ProcessControl {

    enum Outcome: Equatable {
        /// All targets were asked to quit / signalled (or were already gone).
        case terminated
        /// No eligible PIDs (empty, or only our own process).
        case nothingToKill
        /// These PIDs need administrator rights (other-user / privileged).
        case needsAdmin([Int32])
        /// Unexpected failures on these PIDs.
        case failed([Int32])
    }

    /// PIDs at or below this are core boot daemons (kernel_task is 0, launchd is
    /// 1, the early system daemons sit in the low double/triple digits). A normal
    /// user process is never assigned a PID this low, so refusing them costs
    /// nothing and keeps "Kill" off launchd & friends — which matters now that a
    /// path-less process classifies as `.unknown` (killable) instead of `.system`.
    static let coreDaemonPidCeiling: Int32 = 100

    /// Whether the "Kill" action should be offered for a row. Pure + testable —
    /// the security-relevant gate lives here, not in the view.
    static func isKillable(origin: ProcessOrigin, livePids: [Int32]) -> Bool {
        guard !livePids.isEmpty else { return false }   // history-only row
        guard origin != .system else { return false }   // never offer for system procs
        // Never offer to kill a row that includes a core boot daemon, even when it
        // classifies as `.unknown` for lack of a resolvable bundle path. No lower
        // bound on purpose: PID 0 is kernel_task (and `kill(0, ...)` would signal
        // our own process group), and a negative PID can't be a legitimate row.
        guard !livePids.contains(where: { $0 <= coreDaemonPidCeiling }) else { return false }
        return true
    }

    /// Terminate `pids` (same user). GUI apps get a graceful quit; non-GUI
    /// processes get SIGTERM, escalating to SIGKILL after a short grace if still
    /// alive. Our own process is never targeted.
    @discardableResult
    static func terminate(pids: [Int32]) -> Outcome {
        let me = getpid()
        // `$0 > 0` is load-bearing, not just hygiene: kill(0, sig) signals the
        // caller's WHOLE process group and kill(-N, sig) signals group N — either
        // would let a malformed row nuke innocent processes (or ourselves).
        let targets = Array(Set(pids)).filter { $0 != me && $0 > 0 }
        guard !targets.isEmpty else { return .nothingToKill }

        var eperm: [Int32] = []
        var failed: [Int32] = []
        // SIGTERM'd non-GUI pids, each tagged with the process-start identity we
        // observed at signal time so the delayed SIGKILL can confirm it's still
        // the SAME process instance before force-killing.
        var signalled: [(pid: Int32, startToken: UInt64?)] = []

        for pid in targets {
            if let app = NSRunningApplication(processIdentifier: pid) {
                // GUI app: ask it to quit gracefully so it can run its own
                // save/termination flow. We intentionally do NOT force-kill a GUI
                // app — a frozen one that ignores the request stays alive and the
                // user can fall back to the OS Force Quit. (Non-GUI processes below
                // DO escalate SIGTERM → SIGKILL.)
                //
                // `terminate()` returns false when the quit request couldn't even be
                // delivered — the app is owned by another user/session, or AppKit
                // refused to send the Apple event. Report that as a failure rather
                // than silently claiming success, so the UI doesn't tell the user a
                // still-running process was terminated. (A *delivered* request that
                // the app then ignores still returns true — that's the deliberate
                // graceful-quit contract; the user falls back to OS Force Quit.)
                if !app.terminate() { failed.append(pid) }
            } else if kill(pid, SIGTERM) == 0 {
                signalled.append((pid, startToken(of: pid)))
            } else {
                switch errno {
                case EPERM: eperm.append(pid)
                case ESRCH: break              // already gone → treat as success
                default:    failed.append(pid)
                }
            }
        }

        // Escalate stubborn non-GUI processes to SIGKILL after a grace — but only
        // if the PID still refers to the same process we SIGTERM'd. When the
        // original process exits in response to SIGTERM, the kernel can recycle
        // its PID to an unrelated same-user process within this 2s window; a blind
        // SIGKILL would then hard-kill an innocent process. We re-read the start
        // time and require an exact match. If we couldn't capture it at SIGTERM
        // (token nil), we deliberately do NOT escalate — a SIGTERM was already
        // delivered, and skipping the force-kill is safer than risking the wrong
        // target.
        if !signalled.isEmpty {
            let stubborn = signalled
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                for entry in stubborn {
                    guard let token = entry.startToken else { continue }   // unverifiable → don't force-kill
                    guard kill(entry.pid, 0) == 0 else { continue }        // already gone
                    guard startToken(of: entry.pid) == token else { continue } // PID reused → skip
                    _ = kill(entry.pid, SIGKILL)
                }
            }
        }

        if !eperm.isEmpty { return .needsAdmin(eperm) }
        if !failed.isEmpty { return .failed(failed) }
        return .terminated
    }

    /// A stable identity token for the process currently holding `pid`: its start
    /// time (seconds·10⁶ + microseconds since the epoch) from the kernel's BSD
    /// task info. The kernel recycles PIDs, but the pair (pid, start-time)
    /// uniquely identifies a process *instance* — so comparing this before a
    /// delayed SIGKILL guards against signalling a process that merely inherited a
    /// recycled PID. Returns nil if the process is gone or its info can't be read.
    static func startToken(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }
        return UInt64(info.pbi_start_tvsec) &* 1_000_000 &+ UInt64(info.pbi_start_tvusec)
    }
}
