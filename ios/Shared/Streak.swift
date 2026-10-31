import Foundation

/// Mirror of the `streaks` row. The arithmetic matches `public.streak_seconds` in SQL,
/// so the client can tick a live value between server refreshes.
struct StreakState: Codable, Equatable {
    var startedAt: Date?
    var pausedSeconds: Double
    var pauseStartedAt: Date?
    var pauseUntil: Date?
    var bestSeconds: Double
    var graceUntil: Date?

    static let empty = StreakState(startedAt: nil, pausedSeconds: 0, pauseStartedAt: nil,
                                   pauseUntil: nil, bestSeconds: 0, graceUntil: nil)

    func currentSeconds(at now: Date = Date()) -> Double {
        guard let startedAt else { return 0 }
        if let graceUntil, graceUntil <= now { return 0 }
        var seconds = now.timeIntervalSince(startedAt) - pausedSeconds
        if let pauseStartedAt {
            let pauseEnd = min(now, pauseUntil ?? now)
            seconds -= pauseEnd.timeIntervalSince(pauseStartedAt)
        }
        return max(0, seconds)
    }

    var isRunning: Bool { startedAt != nil }

    var isOnGrace: Bool {
        guard let graceUntil else { return false }
        return graceUntil > Date()
    }

    func isPaused(at now: Date = Date()) -> Bool {
        guard let pauseStartedAt, pauseStartedAt <= now else { return false }
        if let pauseUntil { return pauseUntil > now }
        return true
    }

    /// Session timer: "03:00:12", or "1d 03:00" past a day.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if days > 0 { return String(format: "%dd %02d:%02d", days, hours, minutes) }
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// "3d 14h", "14h 05m", "12m"
    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        return "\(minutes)m"
    }
}

/// Postgres/PostgREST emit timestamps such as
/// `2026-10-31T12:39:03.341493+00:00` (microseconds) or `2026-10-31T12:39:03+00:00`.
/// ISO8601DateFormatter wants exactly three fractional digits, so normalise first.
enum SupabaseDates {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: " ", with: "T")
        // "…03+00" -> "…03+00:00" (only for full timestamps; a bare date would false-match).
        if s.contains("T"), let range = s.range(of: #"(?<!:)[+-]\d{2}$"#, options: .regularExpression) {
            s.replaceSubrange(range, with: s[range] + ":00")
        }
        // Trim or pad fractional seconds to exactly three digits.
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s.index(after: dot)
            let fractionEnd = s[afterDot...].firstIndex { !$0.isNumber } ?? s.endIndex
            var fraction = String(s[afterDot..<fractionEnd])
            if fraction.count > 3 { fraction = String(fraction.prefix(3)) }
            while fraction.count < 3 { fraction += "0" }
            s.replaceSubrange(afterDot..<fractionEnd, with: fraction)
            return withFraction.date(from: s) ?? withoutFraction.date(from: s)
        }
        return withoutFraction.date(from: s) ?? withFraction.date(from: s)
    }

    static func decode(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let date = parse(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable timestamp \(raw)")
        }
        return date
    }
}
