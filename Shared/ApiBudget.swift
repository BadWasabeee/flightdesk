import Foundation

/// The web services FlightDesk talks to, for counting requests and respecting rate limits.
enum ApiService: String, CaseIterable, Codable, Sendable {
    case adsbFi, adsbLol, openSky, adsbdb, planespotters, logos, other

    init(host: String) {
        switch host {
        case let h where h.hasSuffix("adsb.fi"): self = .adsbFi
        case let h where h.hasSuffix("adsb.lol"): self = .adsbLol
        case let h where h.hasSuffix("opensky-network.org"): self = .openSky
        case let h where h.hasSuffix("adsbdb.com"): self = .adsbdb
        case let h where h.hasSuffix("planespotters.net") || h.hasSuffix("plnspttrs.net"): self = .planespotters
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
        case .logos: "Airline logos"
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
enum ApiBudget {
    private struct State: Codable {
        var day: String
        var counts: [ApiService: Int] = [:]
        /// Service → when it may be used again.
        var pausedUntil: [ApiService: Date] = [:]
    }

    private static let key = "api.budget.v1"
    private static let lock = NSLock()

    private static var today: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func load() -> State {
        let day = today
        guard let data = Shared.defaults.data(forKey: key),
              var s = try? JSONDecoder().decode(State.self, from: data) else { return State(day: day) }
        if s.day != day { s.day = day; s.counts = [:] }
        s.pausedUntil = s.pausedUntil.filter { $0.value > Date() }
        return s
    }

    private static func save(_ s: State) {
        if let data = try? JSONEncoder().encode(s) { Shared.defaults.set(data, forKey: key) }
    }

    private static func update(_ change: (inout State) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        change(&s)
        save(s)
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

    /// Counts a finished request and reads the service's rate-limit headers.
    static func record(_ response: HTTPURLResponse) {
        guard let host = response.url?.host else { return }
        let service = ApiService(host: host)
        let pause = pauseInterval(service: service, status: response.statusCode, headers: response.allHeaderFields)
        update { s in
            s.counts[service, default: 0] += 1
            if let pause { s.pausedUntil[service] = Date().addingTimeInterval(pause) }
        }
    }

    /// How long to pause a service after a response, from its status and rate-limit headers.
    /// adsb.lol sends `x-ratelimit-remaining` / `x-ratelimit-reset` (seconds); OpenSky sends
    /// `X-Rate-Limit-Remaining` and, when limited, `X-Rate-Limit-Retry-After-Seconds`.
    static func pauseInterval(service: ApiService, status: Int, headers: [AnyHashable: Any]) -> TimeInterval? {
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }.map { "\($0.value)" }
        }
        // "500, 500;w=86400"-style values: take the leading number.
        func number(_ name: String) -> Double? {
            header(name).flatMap { Double($0.split(whereSeparator: { !"0123456789.".contains($0) }).first ?? "") }
        }
        let retryAfter = number("x-rate-limit-retry-after-seconds") ?? number("retry-after") ?? number("x-ratelimit-reset")
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
