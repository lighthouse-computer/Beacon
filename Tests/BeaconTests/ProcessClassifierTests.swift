import XCTest
@testable import Beacon

/// ProcessClassifier's origin + trust verdicts. The security-relevant property:
/// a process we can't attribute (no bundle path, no Apple bundle id) must NOT be
/// reported as a trusted system process — that would stamp a false "valid code
/// signature" seal on an unverified binary. These are pure string/heuristic
/// checks (no filesystem / SecCode access) for the paths exercised here.
final class ProcessClassifierTests: XCTestCase {

    // MARK: - origin

    func test_origin_appleBundleId_isSystem() {
        XCTAssertEqual(
            ProcessClassifier.origin(bundlePath: nil, bundleIdentifier: "com.apple.Safari", pid: 500),
            .system)
    }

    func test_origin_systemPaths_areSystem() {
        XCTAssertEqual(
            ProcessClassifier.origin(bundlePath: "/usr/sbin/mDNSResponder", bundleIdentifier: nil, pid: 200),
            .system)
        XCTAssertEqual(
            ProcessClassifier.origin(bundlePath: "/System/Library/CoreServices/Foo", bundleIdentifier: nil, pid: 200),
            .system)
    }

    func test_origin_userPaths_areUser() {
        XCTAssertEqual(
            ProcessClassifier.origin(bundlePath: "/Applications/Firefox.app", bundleIdentifier: nil, pid: 600),
            .user)
    }

    func test_origin_pathlessNonApple_isUnknownNotSystem() {
        // The honesty fix: no bundle path + non-Apple id → .unknown, NOT .system.
        // Previously this fell through to .system (and thus .trusted).
        XCTAssertEqual(
            ProcessClassifier.origin(bundlePath: nil, bundleIdentifier: nil, pid: 4321),
            .unknown)
        XCTAssertEqual(
            ProcessClassifier.origin(bundlePath: nil, bundleIdentifier: "com.example.helper", pid: 4321),
            .unknown)
    }

    // MARK: - trust

    func test_trust_pathlessUnknown_isUnknownNotTrusted() {
        // A path-less .unknown process gets an honest "trust unknown", never a
        // false .trusted seal.
        XCTAssertEqual(ProcessClassifier.trust(bundlePath: nil, origin: .unknown), .unknown)
    }

    func test_trust_system_isTrusted() {
        // Genuine system processes (Apple bundle id / system path) stay trusted
        // without an expensive per-binary signature check.
        XCTAssertEqual(ProcessClassifier.trust(bundlePath: nil, origin: .system), .trusted)
    }

    // MARK: - cachedTrust (non-blocking per-tick path)

    func test_cachedTrust_positiveEvidence_resolvesSynchronously() {
        // System origin never touches disk, so the non-blocking variant must still
        // answer it immediately (no `.unknown` tick). A path-less non-system
        // process stays `.unknown`.
        XCTAssertEqual(
            ProcessClassifier.cachedTrust(bundlePath: nil, origin: .system),
            .trusted)
        XCTAssertEqual(
            ProcessClassifier.cachedTrust(bundlePath: nil, origin: .unknown),
            .unknown)
    }

    func test_cachedTrust_unverifiablePath_isUnknownThenResolvesUntrusted() {
        // A never-seen path can't have a verdict yet → `.unknown` on the first
        // (main-thread) call, with the signature check offloaded. After the
        // background resolution lands, a later call reads the cached `.untrusted`.
        // This is the whole point: the disk-touching check never runs on the
        // caller's thread.
        let bogus = "/tmp/beacon-test-\(UUID().uuidString)"
        XCTAssertEqual(
            ProcessClassifier.cachedTrust(bundlePath: bogus, origin: .user),
            .unknown)

        var resolved: ProcessTrust = .unknown
        for _ in 0..<200 {   // up to ~4s
            resolved = ProcessClassifier.cachedTrust(bundlePath: bogus, origin: .user)
            if resolved != .unknown { break }
            usleep(20_000)
        }
        XCTAssertEqual(resolved, .untrusted)
    }

    // MARK: - Cache bound

    func test_cache_evictsOldestBeyondCap() {
        let cache = Cache<Int, Int>(maxEntries: 2)
        cache.set(1, 10)
        cache.set(2, 20)
        cache.set(3, 30)   // evicts key 1 (FIFO)
        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.get(2), 20)
        XCTAssertEqual(cache.get(3), 30)
        XCTAssertEqual(cache.count, 2)
    }
}
