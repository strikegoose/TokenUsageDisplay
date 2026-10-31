import Foundation

/// One parsed "weekly included usage" quota card from Cursor's new-pricing
/// dashboard endpoint (`GET /api/dashboard/v2/usage-status?scope=user`).
public struct CursorWeeklyUsageCard: Equatable, Sendable {
    public let percentUsed: Double  // clamped 0...100
    public let windowStart: Date
    public let resetTime: Date
}

/// Parses the JSON returned by Cursor's usage-status endpoint. Returns nil for
/// anything that is not a metered personal weekly quota (old plans, teams,
/// missing blocks, invalid numbers/dates) so callers can fall back to the
/// legacy `/api/usage-summary` flow.
public enum CursorWeeklyUsageParser {
    private struct Payload: Decodable {
        let availability: String?
        let weeklyIncludedStatus: Status?
        let weeklyIncludedUsage: Usage?

        struct Status: Decodable {
            let status: String?
        }

        struct Usage: Decodable {
            let usedCents: Double?
            let budgetCents: Double?
            let periodStart: String?
            let resetsAt: String?
        }
    }

    public static func parse(_ data: Data) -> CursorWeeklyUsageCard? {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            return nil
        }

        guard payload.availability == "available",
              payload.weeklyIncludedStatus?.status == "metered",
              let usage = payload.weeklyIncludedUsage,
              let used = usage.usedCents, used.isFinite, used >= 0,
              let budget = usage.budgetCents, budget.isFinite, budget > 0,
              let start = parseDate(usage.periodStart),
              let reset = parseDate(usage.resetsAt),
              reset > start
        else { return nil }

        let percent = max(0, min(100, used / budget * 100))
        return CursorWeeklyUsageCard(percentUsed: percent, windowStart: start, resetTime: reset)
    }

    /// Parses "2026-11-06T23:33:34.774Z" (with or without fractional seconds).
    private static func parseDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
