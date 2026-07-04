import Foundation

struct FormatUtility {
    /// Format a speed in bytes/second. Compact: drops trailing decimals at the B/s scale,
    /// shows one decimal at KB/s+, two only at MB/s+. The old fixed-2 format made tiny
    /// speeds look fake (`0.12 B/s`).
    static func formatSpeed(_ speed: Double) -> String {
        // NaN/±inf can reach here from an upstream rate division on a degenerate
        // dt (clock step, divide-by-near-zero). Guard so we never render
        // "nan B/s" / "inf GB/s"; treat a non-finite speed as no measurement.
        guard speed.isFinite else { return "0 B/s" }
        if speed <= 0 { return "0 B/s" }

        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = speed
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let format: String
        switch unitIndex {
        case 0: format = "%.0f %@/s"
        case 1: format = "%.1f %@/s"
        default: format = "%.2f %@/s"
        }
        return String(format: format, value, units[unitIndex])
    }

    /// Format a cumulative byte count (no "/s"). Used for "data transferred" labels.
    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }

        // Through EB so a UInt64 total (max ~16 EB) never saturates the top
        // tier into an ever-growing "131072.0 TB" string over long uptimes.
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let format: String
        switch unitIndex {
        case 0: format = "%.0f %@"
        case 1: format = "%.0f %@"
        default: format = "%.1f %@"
        }
        return String(format: format, value, units[unitIndex])
    }
}
