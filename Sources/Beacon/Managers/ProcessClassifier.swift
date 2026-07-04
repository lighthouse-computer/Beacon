import Foundation
import Security

/// Whether a process is part of macOS itself or a user-installed app.
enum ProcessOrigin: String, Equatable {
    /// System process: in /System, /usr, com.apple.* bundle id, or a low-PID daemon.
    case system
    /// User-installed app: anywhere under /Applications or the user's home.
    case user
    /// Couldn't classify (no bundle path, no useful PID signal).
    case unknown

    var label: String {
        switch self {
        case .system: return "System"
        case .user:   return "User"
        case .unknown: return "Other"
        }
    }
}

/// Code-signing trust verdict. Cached per bundle path.
enum ProcessTrust: String, Equatable {
    /// Has a valid code signature (Apple, Developer ID, or notarized).
    case trusted
    /// Ad-hoc, unsigned, or signature failed validity check.
    case untrusted
    /// No bundle path to verify (helper binaries, kernel-side daemons, etc.).
    case unknown

    var sfSymbol: String {
        switch self {
        case .trusted:   return "checkmark.seal.fill"
        case .untrusted: return "exclamationmark.shield.fill"
        case .unknown:   return "questionmark.circle"
        }
    }

    var tooltip: String {
        switch self {
        case .trusted:   return "Valid code signature"
        case .untrusted: return "No valid code signature"
        case .unknown:   return "Trust unknown"
        }
    }
}

/// Decides whether a running process is system-vs-user and trusted-vs-untrusted.
/// Both calls are cached because (a) signature validation reads and hashes the
/// binary, and (b) classification doesn't change for the lifetime of a PID.
enum ProcessClassifier {
    private static let originCache = Cache<String, ProcessOrigin>()
    private static let trustCache  = Cache<String, ProcessTrust>()
    /// Off-main worker for the disk-touching signature check. `cachedTrust` (the
    /// per-tick UI path) dispatches `computeTrust` here so `SecStaticCodeCheckValidity`
    /// never runs on the main thread — a burst of never-before-seen paths (e.g. a
    /// post-wake flurry of relaunched/translocated apps) was able to stack dozens of
    /// synchronous signature reads onto one main-thread tick and stall the run loop.
    private static let trustQueue = DispatchQueue(label: "computer.lighthouse.beacon.classifier-trust", qos: .utility)

    /// Live cache sizes, for the resource-usage diagnostic log. Read-only.
    static var cacheStats: (origin: Int, trust: Int) { (originCache.count, trustCache.count) }

    static func origin(bundlePath: String?, bundleIdentifier: String?, pid: Int32) -> ProcessOrigin {
        // Apple bundle ids are unambiguous.
        if let bid = bundleIdentifier, bid.hasPrefix("com.apple.") {
            return .system
        }
        // Path-based classification.
        if let path = bundlePath {
            if let cached = originCache.get(path) { return cached }
            let result: ProcessOrigin
            if path.hasPrefix("/System/")
                || path.hasPrefix("/usr/")
                || path.hasPrefix("/Library/Apple/")
                || path.hasPrefix("/private/var/db/") {
                result = .system
            } else if path.hasPrefix("/Applications/")
                || path.contains("/Users/") {
                result = .user
            } else if path.hasPrefix("/Library/") {
                // /Library/* (not /Library/Apple) is generally system-wide
                // third-party installs — treat as user-installed.
                result = .user
            } else {
                result = .unknown
            }
            originCache.set(path, result)
            return result
        }
        // No bundle path and no Apple bundle id: we cannot attribute this process
        // to anything. Do NOT claim it's `.system` — that path also drives the
        // trust verdict, so it would stamp a green "valid code signature" seal on
        // a binary we never verified (e.g. a renamed/path-less user daemon
        // masquerading as system). Report it honestly as `.unknown`; trust() then
        // returns `.unknown` rather than a false `.trusted`. Core boot daemons
        // (very low PIDs) are kept unkillable by ProcessControl.isKillable's PID
        // floor, so honesty here doesn't expose a footgun on launchd et al.
        return .unknown
    }

    static func trust(bundlePath: String?, origin: ProcessOrigin) -> ProcessTrust {
        // System processes are trusted by definition — the OS owns them, and
        // running `SecStaticCodeCheckValidity` on every /System binary is both
        // slow (cold-cache CPU spike at startup) and noisy.
        if origin == .system { return .trusted }
        guard let path = bundlePath else { return .unknown }
        if let cached = trustCache.get(path) { return cached }

        let result = computeTrust(bundlePath: path)
        trustCache.set(path, result)
        return result
    }

    /// Non-blocking trust lookup for the **per-tick UI path** (`aggregateByBundle`,
    /// which runs on the main thread once per second). Returns positive evidence
    /// (system origin) and cache hits synchronously; on a miss it returns
    /// `.unknown` immediately and resolves the disk-touching signature check on a
    /// background queue, so the main thread never runs `SecStaticCodeCheckValidity`.
    /// The next tick reads the now-cached verdict and the seal settles. Use the
    /// synchronous `trust(...)` when a definitive verdict is required *now* (kill
    /// gate, tests); this variant trades one tick of `.unknown` for a run loop that
    /// can't be stalled by a signature-read storm.
    static func cachedTrust(bundlePath: String?, origin: ProcessOrigin) -> ProcessTrust {
        if origin == .system { return .trusted }
        guard let path = bundlePath else { return .unknown }
        if let cached = trustCache.get(path) { return cached }
        // Miss: compute off-main; show .unknown until it lands.
        trustQueue.async {
            guard trustCache.get(path) == nil else { return }   // a prior tick already resolved it
            trustCache.set(path, computeTrust(bundlePath: path))
        }
        return .unknown
    }

    private static func computeTrust(bundlePath: String) -> ProcessTrust {
        let url = URL(fileURLWithPath: bundlePath) as CFURL
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .untrusted
        }
        // Default flags: checks signature + designated requirement.
        let validity = SecStaticCodeCheckValidity(code, [], nil)
        if validity == errSecSuccess {
            return .trusted
        }
        // errSecCSUnsigned (-67062) and most other failures mean "no usable signature."
        return .untrusted
    }
}

/// Tiny synchronized, bounded cache.
///
/// Bounded because the keys are *file paths*, and the path space is NOT stationary
/// over a multi-day session: macOS App Translocation runs quarantined apps from a
/// fresh `/private/var/folders/.../AppTranslocation/<UUID>/…` path on each launch,
/// and short-lived binaries execute from per-invocation `/var/folders` paths — so
/// an uncapped cache grows without bound. Eviction is insertion-order (FIFO): for
/// classification verdicts recency carries no signal, so a simple bound is enough
/// and keeps `get` lock-light (reads don't take the write barrier).
final class Cache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private let maxEntries: Int
    private let queue = DispatchQueue(label: "computer.lighthouse.beacon.cache", attributes: .concurrent)

    init(maxEntries: Int = 1024) {
        self.maxEntries = maxEntries
    }

    var count: Int { queue.sync { storage.count } }

    func get(_ key: Key) -> Value? {
        queue.sync { storage[key] }
    }

    func set(_ key: Key, _ value: Value) {
        queue.async(flags: .barrier) {
            if self.storage[key] == nil { self.order.append(key) }
            self.storage[key] = value
            while self.order.count > self.maxEntries {
                let evict = self.order.removeFirst()
                self.storage.removeValue(forKey: evict)
            }
        }
    }
}
