import Foundation

/// Static IANA-style port → service-name map. Local lookup only; the app makes
/// zero network calls. Returns `nil` for ports we don't recognize — callers
/// fall back to displaying the port number.
enum ServiceDirectory {
    static func name(forPort port: UInt16, proto: String) -> String? {
        let normalized = proto.hasPrefix("tcp") ? "tcp" : (proto.hasPrefix("udp") ? "udp" : proto)
        if let s = mapping["\(normalized):\(port)"] { return s }
        // Some entries are protocol-agnostic.
        return mapping["any:\(port)"]
    }

    /// Compact set covering the well-known + common-app ports a typical Mac
    /// will actually hit. Keep small and curated — a 1,000-entry table would
    /// be noisy without helping users.
    private static let mapping: [String: String] = [
        "tcp:20": "ftp-data", "tcp:21": "ftp",
        "tcp:22": "ssh", "tcp:23": "telnet",
        "tcp:25": "smtp", "tcp:587": "smtp", "tcp:465": "smtps",
        "udp:53": "dns", "tcp:53": "dns",
        "udp:67": "dhcp", "udp:68": "dhcp",
        "tcp:80": "http",
        "tcp:110": "pop3", "tcp:995": "pop3s",
        "udp:123": "ntp",
        "tcp:143": "imap", "tcp:993": "imaps",
        "udp:161": "snmp", "udp:162": "snmp-trap",
        "tcp:389": "ldap", "tcp:636": "ldaps",
        "tcp:443": "https", "udp:443": "https/quic",
        "udp:500": "ipsec", "udp:4500": "ipsec-nat",
        "udp:514": "syslog",
        "tcp:631": "ipp",
        "tcp:873": "rsync",
        "tcp:1080": "socks",
        "tcp:1194": "openvpn", "udp:1194": "openvpn",
        "tcp:1433": "mssql",
        "tcp:1521": "oracle",
        "tcp:2049": "nfs",
        "tcp:3306": "mysql",
        "tcp:3389": "rdp",
        "udp:3478": "stun", "tcp:3478": "stun",
        "tcp:5060": "sip", "udp:5060": "sip", "tcp:5061": "sips",
        "tcp:5222": "xmpp", "tcp:5223": "apns",        // Apple Push Notification Service
        "udp:5353": "mdns",
        "tcp:5432": "postgres",
        "tcp:5672": "amqp",
        "tcp:5900": "vnc",
        "tcp:5985": "winrm", "tcp:5986": "winrm-ssl",
        "tcp:6379": "redis",
        "tcp:6443": "kubernetes",
        "tcp:6667": "irc", "tcp:6697": "ircs",
        "tcp:8080": "http-alt", "tcp:8443": "https-alt",
        "tcp:9100": "printer",
        "tcp:9418": "git",
        "tcp:11211": "memcached",
        "tcp:27017": "mongodb", "tcp:27018": "mongodb",
        "udp:51820": "wireguard",
    ]
}
