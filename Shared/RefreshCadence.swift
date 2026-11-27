// How often the iPhone radar refetches, so it stays live on adsb.fi (no daily cap) but spreads out
// adsb.lol's 500-a-day allowance when adsb.fi is down, and rests when every feed is paused.
// Pure Foundation so it can be unit tested.

import Foundation

enum RefreshCadence {
    /// Normal cadence, matching the Mac radar (adsb.fi or your own receiver).
    static let live: TimeInterval = 12
    /// While adsb.lol (daily allowance) is serving the radar.
    static let rationed: TimeInterval = 45
    /// Close to adsb.lol's allowance, or every feed paused: check again every couple of minutes.
    static let resting: TimeInterval = 120
    /// Below this many adsb.lol requests left today (after its reserve), poll at `resting`.
    static let lowRemaining = 100

    /// Seconds until the next fetch.
    /// - Parameters:
    ///   - source: what served the latest list (nil before the first fetch).
    ///   - counts: today's requests per service (`ApiBudget.counts`).
    ///   - paused: services resting after a rate limit (`ApiBudget.pausedUntil`).
    ///   - lowPower: Low Power Mode is on, which doubles every interval.
    static func interval(source: DataSource?, counts: [ApiService: Int], paused: Set<ApiService>,
                         lowPower: Bool = false) -> TimeInterval {
        var t: TimeInterval
        switch source {
        case .receiver?:
            t = live
        case .feed(.adsbLol)?:
            t = remaining(.adsbLol, counts: counts) < lowRemaining ? resting : rationed
        case .feed(.adsbFi)?, nil:
            t = live
        }
        // Every internet feed is resting: polling faster would only hit the same limits.
        if source != .receiver, paused.contains(.adsbFi), paused.contains(.adsbLol) { t = max(t, resting) }
        return lowPower ? t * 2 : t
    }

    /// Requests left today before FlightDesk stops using `service` (its allowance minus its reserve).
    static func remaining(_ service: ApiService, counts: [ApiService: Int]) -> Int {
        guard let limit = service.dailyLimit else { return .max }
        return max(0, limit - service.reserve - (counts[service] ?? 0))
    }
}
