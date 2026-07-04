import XCTest
@testable import Beacon

/// The Kill action's safety gate. The actual termination calls into the OS, so
/// we don't kill real processes in a unit test — we pin the *policy* (what's
/// killable) and the safe no-op paths (empty list, our own PID), which are the
/// parts that protect the user from a footgun.
final class ProcessControlTests: XCTestCase {

    func test_isKillable_refusesSystemOrigin() {
        // Ending launchd / mDNSResponder children can wedge the OS — never offer.
        XCTAssertFalse(ProcessControl.isKillable(origin: .system, livePids: [123]))
    }

    func test_isKillable_requiresLivePids() {
        XCTAssertFalse(ProcessControl.isKillable(origin: .user, livePids: []),
                       "history-only rows (no live PIDs) can't be killed")
        XCTAssertFalse(ProcessControl.isKillable(origin: .unknown, livePids: []))
    }

    func test_isKillable_allowsUserAndUnknownWithLivePids() {
        XCTAssertTrue(ProcessControl.isKillable(origin: .user, livePids: [123]))
        XCTAssertTrue(ProcessControl.isKillable(origin: .unknown, livePids: [123, 456]))
    }

    func test_isKillable_refusesCoreDaemonPids() {
        // launchd (1) and other low-PID boot daemons must never get a Kill
        // button, even when they classify as `.unknown` (no resolvable bundle
        // path). A row that includes ANY core-daemon PID is refused.
        XCTAssertFalse(ProcessControl.isKillable(origin: .unknown, livePids: [1]))
        XCTAssertFalse(ProcessControl.isKillable(origin: .user, livePids: [42]))
        XCTAssertFalse(ProcessControl.isKillable(origin: .unknown, livePids: [50, 1234]))
    }

    func test_isKillable_refusesPidZeroAndNegative() {
        // PID 0 is kernel_task — and kill(0, sig) signals our own process group,
        // so the gate must catch it despite it classifying as `.unknown`
        // (proc_pidpath fails for it). Negative PIDs are group ids, never rows.
        XCTAssertFalse(ProcessControl.isKillable(origin: .unknown, livePids: [0]))
        XCTAssertFalse(ProcessControl.isKillable(origin: .user, livePids: [-5]))
    }

    func test_terminate_dropsNonPositivePids() {
        // kill(0, ...) / kill(-N, ...) have process-group semantics; terminate()
        // must filter them even if a caller bypasses isKillable.
        XCTAssertEqual(ProcessControl.terminate(pids: [0]), .nothingToKill)
        XCTAssertEqual(ProcessControl.terminate(pids: [-1, 0, getpid()]), .nothingToKill)
    }

    func test_isKillable_allowsPidsAboveCoreFloor() {
        XCTAssertTrue(ProcessControl.isKillable(
            origin: .unknown, livePids: [ProcessControl.coreDaemonPidCeiling + 1]))
    }

    func test_startToken_isStableForLiveProcess() {
        // PID-reuse safety hinges on (pid, start-time) being a stable instance
        // identity. Our own process is alive with a fixed start time → the token
        // reads back identically across calls.
        let first = ProcessControl.startToken(of: getpid())
        let second = ProcessControl.startToken(of: getpid())
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func test_startToken_nilForNonexistentPid() {
        // No process holds this PID (well above macOS's PID ceiling) → nil, the
        // "can't verify identity" path that suppresses SIGKILL escalation.
        XCTAssertNil(ProcessControl.startToken(of: 99_999_999))
    }

    func test_terminate_emptyList_isNoop() {
        XCTAssertEqual(ProcessControl.terminate(pids: []), .nothingToKill)
    }

    func test_terminate_neverTargetsOwnProcess() {
        // Asking to kill only ourselves filters down to nothing — the app must
        // not be able to terminate itself via a row action.
        XCTAssertEqual(ProcessControl.terminate(pids: [getpid()]), .nothingToKill)
    }
}
