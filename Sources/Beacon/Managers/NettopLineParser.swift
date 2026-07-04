import Foundation

/// One process-summary row out of nettop. (nettop column 0 is the snapshot
/// timestamp and column 3 is connection state — neither is consumed downstream,
/// so they're not carried here.)
struct ParsedNettopRow: Equatable {
    let pid: Int32
    let processName: String
    /// Cumulative bytes_in reported for this PID in this snapshot.
    let bytesIn: UInt64
    /// Cumulative bytes_out reported for this PID in this snapshot.
    let bytesOut: UInt64
}

/// One per-connection sub-row. Without `-P`, nettop interleaves these under each
/// process row; the parser is stateless (PID context lives in the caller, which
/// inherits it from the most recent process row).
struct ParsedConnectionRow: Equatable {
    /// `tcp4`, `tcp6`, `udp4`, `udp6`.
    let proto: String
    /// Local IP. `"*"` for wildcard listen sockets.
    let localIP: String
    /// Local port. `0` for wildcard.
    let localPort: UInt16
    /// Remote IP. `"*"` for wildcard.
    let remoteIP: String
    /// Remote port. `0` for wildcard.
    let remotePort: UInt16
    /// Cumulative bytes_in (since socket open).
    let bytesIn: UInt64
    /// Cumulative bytes_out.
    let bytesOut: UInt64
}

/// Result of parsing one nettop line. Header rows, blanks, and any unparseable
/// rubbish return `nil` — callers should silently drop them.
enum NettopRow: Equatable {
    case process(ParsedNettopRow)
    case connection(ParsedConnectionRow)
}

enum NettopLineParser {
    // MARK: - Public entry point

    /// Parse one line of nettop output (no `-P`). Returns:
    ///   • `.process(...)` for `<name>.<pid>` process-summary rows
    ///   • `.connection(...)` for `tcp4|tcp6|udp4|udp6 <local><->|<remote>` sub-rows
    ///   • `nil` for headers, sub-rows with no byte counts (pure listens), and garbage
    static func parseRow(line rawLine: String) -> NettopRow? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }

        let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 6 else { return nil }
        if cols[0].lowercased().hasPrefix("time") { return nil }

        let field = cols[1]
        if field.hasPrefix("tcp4 ") || field.hasPrefix("tcp6 ")
        || field.hasPrefix("udp4 ") || field.hasPrefix("udp6 ") {
            return parseConnection(cols: cols).map(NettopRow.connection)
        }
        return parseProcess(cols: cols).map(NettopRow.process)
    }

    /// Back-compat shim — old call sites used `parse(line:)` for process rows.
    /// Returns nil for connection rows so existing code is unaffected.
    static func parse(line rawLine: String) -> ParsedNettopRow? {
        if case .process(let row) = parseRow(line: rawLine) { return row }
        return nil
    }

    // MARK: - Process rows

    private static func parseProcess(cols: [String]) -> ParsedNettopRow? {
        let procField = cols[1]
        guard !procField.isEmpty else { return nil }   // empty col[1] = connection sub-row left over from `-P`
        guard let lastDot = procField.lastIndex(of: ".") else { return nil }
        let pidPart = procField[procField.index(after: lastDot)...]
        guard let pid = Int32(pidPart) else { return nil }
        let name = String(procField[..<lastDot])

        guard let bytesIn = UInt64(cols[4].trimmingCharacters(in: .whitespaces)),
              let bytesOut = UInt64(cols[5].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return ParsedNettopRow(
            pid: pid,
            processName: name,
            bytesIn: bytesIn,
            bytesOut: bytesOut
        )
    }

    // MARK: - Connection rows

    private static func parseConnection(cols: [String]) -> ParsedConnectionRow? {
        // col[1] = "tcp4 1.2.3.4:5678<->5.6.7.8:443" (or similar IPv6 forms)
        let descriptor = cols[1]
        let firstSpace = descriptor.firstIndex(of: " ") ?? descriptor.endIndex
        let proto = String(descriptor[..<firstSpace])
        guard proto == "tcp4" || proto == "tcp6" || proto == "udp4" || proto == "udp6" else {
            return nil
        }
        let body = descriptor[descriptor.index(firstSpace, offsetBy: 1)...]
        // local<->remote
        guard let arrow = body.range(of: "<->") else { return nil }
        let local = String(body[..<arrow.lowerBound])
        let remote = String(body[arrow.upperBound...])

        let isV6 = (proto == "tcp6" || proto == "udp6")
        let (localIP, localPort) = splitAddrPort(local, isV6: isV6)
        let (remoteIP, remotePort) = splitAddrPort(remote, isV6: isV6)

        // Sub-rows without byte counts are pure listen sockets / wildcards —
        // we don't care about those (no traffic to attribute).
        let bytesInStr = cols[4].trimmingCharacters(in: .whitespaces)
        let bytesOutStr = cols[5].trimmingCharacters(in: .whitespaces)
        guard let bytesIn = UInt64(bytesInStr),
              let bytesOut = UInt64(bytesOutStr) else { return nil }

        return ParsedConnectionRow(
            proto: proto,
            localIP: localIP,
            localPort: localPort,
            remoteIP: remoteIP,
            remotePort: remotePort,
            bytesIn: bytesIn,
            bytesOut: bytesOut
        )
    }

    /// Split `"1.2.3.4:5678"` or `"2606:4700:4700::1111.443"` into (ip, port).
    /// IPv4 uses the last `:`; IPv6 uses the last `.` (because the address
    /// itself is `:`-colon-rich). Wildcards (`*`, `*:*`, `*.*`) come back as
    /// `("*", 0)`.
    private static func splitAddrPort(_ s: String, isV6: Bool) -> (String, UInt16) {
        if s == "*" || s == "*:*" || s == "*.*" { return ("*", 0) }
        let sep: Character = isV6 ? "." : ":"
        guard let idx = s.lastIndex(of: sep) else { return (s, 0) }
        let ip = String(s[..<idx])
        let portStr = s[s.index(after: idx)...]
        let port = (portStr == "*") ? 0 : (UInt16(portStr) ?? 0)
        return (ip.isEmpty ? "*" : ip, port)
    }
}
