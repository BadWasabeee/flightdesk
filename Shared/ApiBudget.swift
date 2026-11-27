import Foundation

/// The web services FlightDesk talks to, for counting requests and respecting rate limits.
enum ApiService: String, CaseIterable, Codable, Sendable {
    case adsbFi, adsbLol, openSky, adsbdb, planespotters, airframes, aviationWeather, logos
    /// The user's own FlightDesk server (see `FlightDeskServer`): counted for the usage list only,
    /// never against an allowance, and never matched by host (it's whatever the user configured).
    case flightdeskServer
    case other

    init(host: String) {
        switch host {
        case let h where h.hasSuffix("adsb.fi"): self = .adsbFi
        case let h where h.hasSuffix("adsb.lol"): self = .adsbLol
        case let h where h.hasSuffix("opensky-network.org"): self = .openSky
        case let h where h.hasSuffix("adsbdb.com"): self = .adsbdb
        case let h where h.hasSuffix("planespotters.net") || h.hasSuffix("plnspttrs.net"): self = .planespotters
        case let h where h.hasSuffix("airframes.io"): self = .airframes
        case let h where h.hasSuffix("aviationweather.gov"): self = .aviationWeather
        case let h where h.hasSuffix("jsdelivr.net") || h.hasSuffix("githubusercontent.com") || h.hasSuffix("kiwi.com"): self = .logos
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .adsbFi: "adsb.fi"
        case .adsbLol: "adsb.lol"
        case .openSky: "OpenSky Network"
        case .adsbdb: "adsbdb"
        case .planespotters: "Planespotters.net"
        case .airframes: "Airframes.io"
        case .aviationWeather: "aviationweather.gov"
        case .logos: "Airline logos"
        case .flightdeskServer: "FlightDesk server"
        case .other: "Other"
        }
    }

    /// Published daily allowance for anonymous use, where there is one.
    var dailyLimit: Int? {
        switch self {
        case .adsbLol: 500
        case .openSky: 400
        default: nil
        }
    }

    /// FlightDesk's own cap on requests per minute (per process) for services that publish a
    /// per-minute guideline. aviationweather.gov asks for no more than 100 a minute; airport
    /// weather is batched and cached, so a handful an hour is typical.
    var minuteLimit: Int? {
        switch self {
        case .aviationWeather: 20
        default: nil
        }
    }

    /// Requests kept in reserve: below this many remaining, FlightDesk stops using the service
    /// until its allowance resets, so it never runs dry.
    var reserve: Int {
        switch self {
        case .adsbLol: 60
        case .openSky: 40
        default: 0
        }
    }
}

/// Today's request counts per service, and pauses for services that are close to (or over) their
/// rate limit. Shared between the app and the widget through the app group.
///
/// Each process writes only its own defaults key (`api.budget.v2.app` / `.widget`), and readers
/// merge them: counts add up, the longest pause wins. With a single writer per key, the app and
/// widget can never lose each other's increments.
enum ApiBudget {
    struct State: Codable, Equatable {
        var day: String
        var counts: [ApiService: Int] = [:]
        /// Service → when it may be used again.
        var pausedUntil: [ApiService: Date] = [:]
    }

    private static let keyPrefix = "api.budget.v2."
    /// Every process that records requests.
    private static let processTags = ["app", "widget"]
    private static let processTag = Bundle.main.bundleURL.pathExtension == "appex" ? "widget" : "app"
    private static var ownKey: String { keyPrefix + processTag }
    private static let lock = NSLock()

    static var today: String { day(of: Date()) }

    static func day(of date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func decode(_ key: String) -> State? {
        Shared.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    /// One process's state, reset for a new day and without expired pauses.
    private static func normalized(_ s: State?, day: String, now: Date) -> State {
        guard var s else { return State(day: day) }
        if s.day != day { s.day = day; s.counts = [:] }
        s.pausedUntil = s.pausedUntil.filter { $0.value > now }
        return s
    }

    /// Combines per-process states: counts for `day` are summed, and each service's latest pause wins.
    static func merge(_ states: [State], day: String, now: Date = Date()) -> State {
        var out = State(day: day)
        for s in states.map({ normalized($0, day: day, now: now) }) {
            out.counts.merge(s.counts, uniquingKeysWith: +)
            out.pausedUntil.merge(s.pausedUntil, uniquingKeysWith: max)
        }
        return out
    }

    /// Everyone's state, merged.
    private static func load() -> State {
        merge(processTags.compactMap { decode(keyPrefix + $0) }, day: today)
    }

    /// The single shared key used before per-process counting.
    private static let removeLegacyKey: Void = Shared.defaults.removeObject(forKey: "api.budget.v1")

    private static func update(_ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        _ = removeLegacyKey
        var s = normalized(decode(ownKey), day: today, now: Date())
        change(&s)
        if let data = try? JSONEncoder().encode(s) { Shared.defaults.set(data, forKey: ownKey) }
    }

    /// Requests made today, per service.
    static var counts: [ApiService: Int] {
        lock.lock(); defer { lock.unlock() }
        return load().counts
    }

    /// When a paused service may be used again, or nil if it's available.
    static func pausedUntil(_ service: ApiService) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return load().pausedUntil[service]
    }

    static func isAvailable(_ service: ApiService) -> Bool { pausedUntil(service) == nil }

    /// Counts a finished request to `service` without reading rate-limit headers (the FlightDesk
    /// server, whose back-off `FlightDeskServer` handles itself).
    static func count(_ service: ApiService) {
        update { $0.counts[service, default: 0] += 1 }
    }

    /// Counts a finished request and reads the service's rate-limit headers.
    static func record(_ response: HTTPURLResponse) {
        guard let url = response.url, let host = url.host else { return }
        // The plane-alert-db list also comes from GitHub, but isn't a logo.
        let service = url.pathExtension == "csv" ? .other : ApiService(host: host)
        let pause = pauseInterval(service: service, status: response.statusCode, headers: response.allHeaderFields)
        update { s in
            s.counts[service, default: 0] += 1
            if let pause { s.pausedUntil[service] = Date().addingTimeInterval(pause) }
        }
    }

    /// How long to pause a service after a response, from its status and rate-limit headers.
    /// adsb.lol sends `x-ratelimit-remaining` / `x-ratelimit-reset` (seconds); Airframes.io sends
    /// the same names with the reset as a Unix time; OpenSky sends `X-Rate-Limit-Remaining` and,
    /// when limited, `X-Rate-Limit-Retry-After-Seconds`.
    static func pauseInterval(service: ApiService, status: Int, headers: [AnyHashable: Any], now: Date = Date()) -> TimeInterval? {
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }.map { "\($0.value)" }
        }
        // "500, 500;w=86400"-style values: take the leading number.
        func number(_ name: String) -> Double? {
            header(name).flatMap { Double($0.split(whereSeparator: { !"0123456789.".contains($0) }).first ?? "") }
        }
        // A reset this large is a Unix time, not a number of seconds.
        let reset = number("x-ratelimit-reset").map { $0 > 1_000_000_000 ? max(0, $0 - now.timeIntervalSince1970) : $0 }
        let retryAfter = number("x-rate-limit-retry-after-seconds") ?? number("retry-after") ?? reset
        if status == 429 { return retryAfter ?? 1_800 }
        if let remaining = number("x-ratelimit-remaining") ?? number("x-rate-limit-remaining"),
           Int(remaining) <= service.reserve, service.reserve > 0 {
            return retryAfter ?? 3_600
        }
        return nil
    }
}

/// Counts every request made through `FlightService.session` (including the widget's).
final class UsageMeter: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        if let response = task.response as? HTTPURLResponse { ApiBudget.record(response) }
    }
}
