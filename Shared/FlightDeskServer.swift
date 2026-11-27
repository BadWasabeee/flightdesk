// Client for the user's own FlightDesk server (Server/README.md): a self-hosted cache and flight
// history that, when set up in Settings › Sources, is asked first for positions, tracks, routes,
// aircraft, ACARS and weather. Any failure falls back silently to the public services, and the
// server is then left alone for a while so a dead server never slows a refresh. Compiled into
// every target (the widgets use it too).

import Foundation

// MARK: - Settings

/// Where the server is. Stored in the app group so the widget sees it; the token is in the
/// Keychain (`KeychainSecretStore.serverToken`), never here.
struct ServerSettings: Codable, Equatable, Sendable {
    /// Use the server at all.
    var enabled = false
    /// What the user typed, e.g. `https://flightdesk.example.com`.
    var url = ""
    /// Add the aircraft the server's poller saw to the logbook.
    var syncLogbook = true

    static let defaultsKey = "flightdeskServer"

    /// The validated base URL, or nil when `url` isn't acceptable (see `ServerAddress`).
    var baseURL: URL? { try? ServerAddress.check(url).get() }
    /// The server should be asked (a token is also needed; see `FlightDeskServer`).
    var isActive: Bool { enabled && baseURL != nil }

    static var current: ServerSettings {
        guard let data = Shared.defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(ServerSettings.self, from: data) else { return ServerSettings() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Shared.defaults.set(data, forKey: Self.defaultsKey)
    }

    init(enabled: Bool = false, url: String = "", syncLogbook: Bool = true) {
        self.enabled = enabled
        self.url = url
        self.syncLogbook = syncLogbook
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        url = c.value(.url, "")
        syncLogbook = c.value(.syncLogbook, true)
    }
}

// MARK: - Address and token validation

/// Which server addresses are accepted: `https://` anywhere, plain `http://` only for this device
/// and the local network (localhost, `.local` names and private IP addresses), where App Transport
/// Security allows it too.
enum ServerAddress {
    enum Problem: Error, Equatable {
        case empty
        case invalid
        /// `http://` to a public address: the token would cross the internet in the clear.
        case insecure

        var message: String {
            switch self {
            case .empty: "Enter your server’s address."
            case .invalid: "Enter an address like https://flightdesk.example.com."
            case .insecure: "Use https://. Plain http:// is only allowed for localhost, .local names and private IP addresses."
            }
        }
    }

    /// The normalised base URL for what the user typed: `https://` is assumed when no scheme is
    /// given; credentials, queries and fragments are refused; trailing slashes are dropped.
    static func check(_ raw: String) -> Result<URL, Problem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if !text.contains("://") { text = "https://" + text }
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { return .failure(.invalid) }
        switch scheme {
        case "https": break
        case "http": guard isPrivate(host: host) else { return .failure(.insecure) }
        default: return .failure(.invalid)
        }
        c.scheme = scheme
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        c.percentEncodedPath = path
        guard let url = c.url else { return .failure(.invalid) }
        return .success(url)
    }

    /// True for this device and local-network hosts: `localhost`, `*.local`, and loopback,
    /// private (RFC 1918), link-local, carrier-grade NAT (Tailscale and similar) and unique-local
    /// IPv6 addresses.
    static func isPrivate(host raw: String) -> Bool {
        var h = raw.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCIIDigit) }) {
            let o = parts.compactMap { UInt8($0) }
            guard o.count == 4 else { return false }
            switch (o[0], o[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if h.contains(":") {
            if h == "::1" { return true }
            guard let first = h.split(separator: ":", omittingEmptySubsequences: false).first,
                  !first.isEmpty, let group = UInt16(first, radix: 16) else { return false }
            return group & 0xfe00 == 0xfc00 || group & 0xffc0 == 0xfe80
        }
        return false
    }

    /// `scheme://host:port` (lowercase, default port filled in), for same-origin checks.
    static func origin(of url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The bearer token the server prints at setup.
enum ServerToken {
    /// The token in `raw` without surrounding whitespace, when it is 1–512 printable ASCII
    /// characters (no spaces or line breaks, which could split the header), else nil.
    static func normalized(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...512).contains(t.utf8.count), t.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return t
    }
}

// MARK: - Wire formats

/// `GET /v1/nearby`: the server's flights already have the Swift `Flight` keys.
struct ServerNearbyResponse: Decodable {
    let source: String?
    let feed: String?
    let flights: [Flight]

    private enum CodingKeys: String, CodingKey { case source, feed, flights }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.value(.source, nil)
        feed = c.value(.feed, nil)
        // One malformed entry shouldn't hide every other aircraft.
        flights = try c.decode(AirframesAPI.Lossy<Flight>.self, forKey: .flights).elements
            .filter { AircraftID.hex($0.id) != nil && $0.lat.isFinite && $0.lon.isFinite && abs($0.lat) <= 90 && abs($0.lon) <= 180 }
    }
}

/// `GET /v1/acars/{hex}`: Airframes.io's own airframe and flight records, wrapped.
struct ServerAcarsResponse: Decodable {
    /// Nil: Airframes has never heard of this aircraft.
    let airframeId: Int?
    let airframe: AirframesAPI.Airframe?
    /// Nil: no current flight (by the server's choice; the app re-picks with `AcarsFlightMatcher`).
    let flightId: Int?
    let flight: AirframesAPI.Flight?

    private enum CodingKeys: String, CodingKey { case airframeId, airframe, flightId, flight }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        airframeId = (c.value(.airframeId, nil) as AirframesAPI.FlexibleID?)?.value
        airframe = c.value(.airframe, nil)
        flightId = (c.value(.flightId, nil) as AirframesAPI.FlexibleID?)?.value
        flight = c.value(.flight, nil)
    }
}

/// One page of `GET /v1/history/sightings`.
struct ServerSightingsPage: Decodable {
    /// Where the next page (or the next incremental sync) starts: entries strictly after
    /// (`since`, `after`) in (lastSeen, hex) order.
    struct Cursor: Codable, Equatable, Sendable {
        var since: Int64
        var after: String
    }

    let sightings: [ServerSighting]
    /// Nil on the last page.
    let next: Cursor?

    private enum CodingKeys: String, CodingKey { case sightings, next }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sightings = try c.decode(AirframesAPI.Lossy<ServerSighting>.self, forKey: .sightings).elements
        next = c.value(.next, nil)
    }
}

/// A sightings-log entry from the server (the keys of `LogEntry`, dates in Unix seconds).
struct ServerSighting: Decodable, Equatable {
    let hex: String
    var registration: String? = nil
    var typeCode: String? = nil
    var operatorName: String? = nil
    var airlineICAO: String? = nil
    let firstSeen: Int64
    let lastSeen: Int64
    var sightings: Int? = nil
    var callsigns: [String]? = nil
    var maxAltitude: Int? = nil
    var routes: [String]? = nil
}

/// The parts of `GET /v1/stats` shown in Settings.
struct ServerStats: Decodable, Equatable {
    struct DB: Decodable, Equatable { var totalBytes: Int64? }
    struct Poller: Decodable, Equatable {
        var enabled: Bool?
        var aircraft: Int?
        var lastSource: String?
    }
    var db: DB?
    var poller: Poller?
    var version: String?
}

// MARK: - Client

/// Requests to the FlightDesk server, with back-off. Every request:
/// - goes only to the configured origin, with the token in an `Authorization` header; redirects to
///   any other origin are refused (see `ServerSessionDelegate`) and a response from another origin
///   is rejected, so the token never leaves the server it was made for;
/// - times out after `requestTimeout` and is size-limited like every other response;
/// - is counted under `ApiService.flightdeskServer`, not against the public services' allowances.
///
/// When the server is unreachable, times out, rejects the token, answers 5xx (from itself or its
/// proxy) or sends something unreadable, it is skipped for `backoff` seconds (or the server's
/// `Retry-After` on 429). A JSON 502/503 means one upstream behind a working server is down, so
/// that request falls back without benching the server. The token is never logged.
actor FlightDeskServer {
    /// The app's (or widget's) server. Replaced only by tests.
    static var shared = FlightDeskServer()

    static let requestTimeout: TimeInterval = 4
    static let defaultBackoff: TimeInterval = 90
    /// How long a token read from the Keychain is reused before reading it again.
    static let tokenLifetime: TimeInterval = 30

    /// A definitive answer: 2xx, or 404 ("nothing known"; adsbdb-style lookups treat it as an answer).
    struct Response: Sendable {
        let data: Data
        let status: Int
    }

    private let session: URLSession
    private let settings: @Sendable () -> ServerSettings
    private let tokens: SecretStore
    private let backoff: TimeInterval
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date

    private var benchedUntil: Date?
    /// Why the server was last skipped, for Settings.
    private(set) var lastProblem: String?
    private var cachedToken: (value: String?, read: Date)?
    /// Watches already posted this session ("hex|callsign").
    private var watched: Set<String> = []

    init(session: URLSession = FlightDeskServer.makeSession(),
         settings: @escaping @Sendable () -> ServerSettings = { ServerSettings.current },
         tokens: SecretStore = KeychainSecretStore.serverToken,
         backoff: TimeInterval = FlightDeskServer.defaultBackoff,
         timeout: TimeInterval = FlightDeskServer.requestTimeout,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.settings = settings
        self.tokens = tokens
        self.backoff = backoff
        self.timeout = timeout
        self.now = now
    }

    /// A session for the server: FlightDesk's User-Agent, short timeouts, no caching or cookies,
    /// and the redirect policy and request counting of `ServerSessionDelegate`.
    static func makeSession(protocolClasses: [AnyClass] = [], timeout: TimeInterval = requestTimeout,
                            countRequests: Bool = true) -> URLSession {
        let c = Net.configuration(request: timeout, resource: max(15, timeout * 3))
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.waitsForConnectivity = false
        if !protocolClasses.isEmpty { c.protocolClasses = protocolClasses + (c.protocolClasses ?? []) }
        return URLSession(configuration: c, delegate: ServerSessionDelegate(countRequests: countRequests), delegateQueue: nil)
    }

    // MARK: State

    /// Settings or the token changed, or a connection test succeeded: read them again and stop
    /// backing off.
    func reset() {
        benchedUntil = nil
        cachedToken = nil
        lastProblem = nil
    }

    /// Whether requests go to the server right now: enabled, configured and not backing off.
    var isAvailable: Bool { endpoint() != nil && !isBenched }

    /// Until when the server is being skipped after a failure, if it is.
    var skippedUntil: Date? { isBenched ? benchedUntil : nil }

    private var isBenched: Bool { benchedUntil.map { now() < $0 } ?? false }

    private struct Endpoint {
        let base: URL
        let token: String
    }

    /// The configured server and token; the Keychain is only read when the server is enabled.
    private func endpoint() -> Endpoint? {
        let s = settings()
        guard s.enabled, let base = s.baseURL else { return nil }
        let token: String?
        if let c = cachedToken, now().timeIntervalSince(c.read) < Self.tokenLifetime {
            token = c.value
        } else {
            token = tokens.read().flatMap(ServerToken.normalized)
            cachedToken = (token, now())
        }
        return token.map { Endpoint(base: base, token: $0) }
    }

    private func succeeded() {
        benchedUntil = nil
        lastProblem = nil
    }

    private func failed(_ reason: String, for seconds: TimeInterval? = nil) {
        let wait = seconds ?? backoff
        benchedUntil = now().addingTimeInterval(wait)
        lastProblem = reason
        fdLog.info("FlightDesk server skipped for \(Int(wait)) s: \(reason, privacy: .public)")
    }

    // MARK: Requests

    /// GETs `path` (each element one encoded segment) from the server. Nil means "use the public
    /// services": not configured, backing off, or this request failed.
    func get(_ path: [String], query: [(String, String)] = [], limit: Int = ResponseLimit.json) async -> Response? {
        await send("GET", path, query: query, limit: limit)
    }

    private func send(_ method: String, _ path: [String], query: [(String, String)] = [],
                      limit: Int = ResponseLimit.json, alsoAccept: Set<Int> = []) async -> Response? {
        guard let ep = endpoint(), !isBenched, let url = Self.url(ep.base, path, query: query) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(ep.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.boundedData(for: request, limit: limit)
            guard let http = response as? HTTPURLResponse else { failed("no HTTP response"); return nil }
            // Redirects to another origin are refused; this also rejects anything that slipped through.
            guard let final = http.url, ServerAddress.origin(of: final) == ServerAddress.origin(of: ep.base) else {
                failed("answered from another address")
                return nil
            }
            let status = http.statusCode
            switch status {
            case 200..<300, 404:
                succeeded()
                return Response(data: data, status: status)
            case _ where alsoAccept.contains(status):
                return Response(data: data, status: status)
            case 400:
                // The server refused this one request's input; it's working, so don't skip it.
                return nil
            case 401, 403:
                failed("the server rejected the token")
            case 429:
                failed("too many requests", for: Self.retryAfter(http).map { min(600, max(30, $0)) })
            case 502 where Self.isJSON(http), 503 where Self.isJSON(http):
                // The server is fine; the upstream behind this request isn't. Go direct this once.
                return nil
            case 300..<400:
                failed("redirected (HTTP \(status))")
            default:
                failed("HTTP \(status)")
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return nil }
            failed((error as? URLError).map { "\($0.code.rawValue) \($0.localizedDescription)" } ?? "\(type(of: error))")
        }
        return nil
    }

    /// `base` with `segments` appended (each fully percent-encoded) and `query` added, or nil.
    static func url(_ base: URL, _ segments: [String], query: [(String, String)] = []) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for s in segments {
            guard let e = RemoteURL.encode(s) else { return nil }
            path += "/" + e
        }
        c.percentEncodedPath = path
        c.percentEncodedQuery = nil
        if !query.isEmpty {
            var items: [URLQueryItem] = []
            for (name, value) in query {
                guard let n = RemoteURL.encode(name) else { return nil }
                items.append(URLQueryItem(name: n, value: value.isEmpty ? "" : RemoteURL.encode(value)))
            }
            c.percentEncodedQueryItems = items
        }
        return c.url
    }

    private static func isJSON(_ r: HTTPURLResponse) -> Bool {
        (r.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("json")
    }

    private static func retryAfter(_ r: HTTPURLResponse) -> TimeInterval? {
        r.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: Endpoints

    /// Aircraft within `radiusNM` of the position, nearest first, or nil to use the public feeds.
    /// The position is rounded to 2 decimals (about 1 km), as for the public feeds.
    func nearby(lat: Double, lon: Double, radiusNM: Int) async -> [Flight]? {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180, (1...250).contains(radiusNM) else { return nil }
        guard let r = await get(["v1", "nearby"], query: [("lat", String(format: "%.2f", lat)),
                                                          ("lon", String(format: "%.2f", lon)),
                                                          ("radius", String(radiusNM))]),
              r.status == 200 else { return nil }
        guard let decoded = try? JSONDecoder().decode(ServerNearbyResponse.self, from: r.data) else {
            failed("unreadable nearby response")
            return nil
        }
        return decoded.flights.sorted { $0.distance < $1.distance }
    }

    /// Asks the server to record the full track of a flight the user opened. Posted once per
    /// aircraft and callsign per session, and only while the server is in use.
    func watch(hex: String, callsign: String) async {
        guard let id = AircraftID.hex(hex, allowNonICAO: false) else { return }
        let key = id + "|" + callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !watched.contains(key), isAvailable else { return }
        watched.insert(key)
        // 429 here means the server's watch list is full: nothing to retry this session.
        if await send("POST", ["v1", "watch", id], alsoAccept: [429]) == nil { watched.remove(key) }
    }

    /// One page of the server's sightings log after `cursor` (from the start when nil).
    func sightings(after cursor: ServerSightingsPage.Cursor?, limit: Int = 1000) async -> ServerSightingsPage? {
        var query = [("since", String(cursor?.since ?? 0)), ("limit", String(limit))]
        if let after = cursor?.after, AircraftID.hex(after, allowNonICAO: false) != nil { query.append(("after", after)) }
        guard let r = await get(["v1", "history", "sightings"], query: query), r.status == 200 else { return nil }
        return try? JSONDecoder().decode(ServerSightingsPage.self, from: r.data)
    }

    // MARK: Connection test (Settings)

    struct TestResult: Equatable {
        var ok: Bool
        var message: String
        var detail: String?
    }

    /// Checks `/healthz`, then the token with `/v1/stats`, and describes the result.
    static func test(url raw: String, token rawToken: String, session: URLSession? = nil) async -> TestResult {
        let base: URL
        switch ServerAddress.check(raw) {
        case .success(let u): base = u
        case .failure(let p): return TestResult(ok: false, message: p.message)
        }
        guard let token = ServerToken.normalized(rawToken) else {
            return TestResult(ok: false, message: rawToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              ? "Enter the server’s token." : "The token has spaces or characters a token can’t contain.")
        }
        let session = session ?? makeSession(timeout: 8)
        let host = base.host ?? "the server"
        let start = Date()
        func request(_ segments: [String], auth: Bool) -> URLRequest? {
            guard let u = url(base, segments) else { return nil }
            var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            if auth { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            return r
        }
        do {
            struct Health: Decodable { let ok: Bool }
            guard let h = request(["healthz"], auth: false) else { return TestResult(ok: false, message: ServerAddress.Problem.invalid.message) }
            let (hData, hResp) = try await session.boundedData(for: h, limit: 64 << 10)
            let hCode = (hResp as? HTTPURLResponse)?.statusCode ?? 0
            guard hResp.url.flatMap(ServerAddress.origin(of:)) == ServerAddress.origin(of: base), !(300..<400).contains(hCode) else {
                return TestResult(ok: false, message: "\(host) redirected to another address. Enter the server’s final address.")
            }
            guard hCode == 200, (try? JSONDecoder().decode(Health.self, from: hData))?.ok == true else {
                return TestResult(ok: false, message: hCode == 200 || hCode == 404
                                  ? "\(host) answered, but it isn’t a FlightDesk server. Check the address."
                                  : "\(host) answered with an error (HTTP \(hCode)).")
            }
            guard let s = request(["v1", "stats"], auth: true) else { return TestResult(ok: false, message: ServerAddress.Problem.invalid.message) }
            let (sData, sResp) = try await session.boundedData(for: s, limit: ResponseLimit.json)
            let sCode = (sResp as? HTTPURLResponse)?.statusCode ?? 0
            switch sCode {
            case 200: break
            case 401, 403: return TestResult(ok: false, message: "The server rejected the token. Paste it again from the server’s setup.")
            case 429: return TestResult(ok: false, message: "The server is refusing this device after too many wrong tokens. Wait a minute and try again.")
            default: return TestResult(ok: false, message: "The server answered with an error (HTTP \(sCode)).")
            }
            let stats = (try? JSONDecoder().decode(ServerStats.self, from: sData)) ?? ServerStats()
            return connected(stats, elapsed: Date().timeIntervalSince(start))
        } catch {
            return TestResult(ok: false, message: describe(error, host: host))
        }
    }

    /// "Connected · 156 aircraft in its area · database 531 KB", detail "Version … · 85 ms".
    static func connected(_ s: ServerStats, elapsed: TimeInterval) -> TestResult {
        var parts = ["Connected"]
        if s.poller?.enabled == false {
            parts.append("area poller off")
        } else if let n = s.poller?.aircraft {
            parts.append("\(n.formatted()) aircraft in its area")
        }
        if let bytes = s.db?.totalBytes { parts.append("database \(bytes.formatted(.byteCount(style: .file)))") }
        let time = elapsed < 1 ? "\(max(1, Int(elapsed * 1000))) ms" : String(format: "%.1f s", elapsed)
        let detail = [s.version.map { "Version \($0)" }, time].compactMap { $0 }.joined(separator: " · ")
        return TestResult(ok: true, message: parts.joined(separator: " · "), detail: detail)
    }

    /// A helpful explanation for a failed connection.
    static func describe(_ error: Error, host: String) -> String {
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed: return "Couldn’t find \(host). Check the address."
        case .timedOut: return "No answer from \(host). Check that the server is running and reachable from \(DeviceName.this)."
        case .cannotConnectToHost: return "\(host) refused the connection. Check the address and port."
        case .notConnectedToInternet, .networkConnectionLost: return "Couldn’t reach \(host). Check your connection."
        case .appTransportSecurityRequiresSecureConnection: return "Plain http:// to \(host) isn’t allowed. Use https://."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "The secure connection to \(host) failed. Check the server’s HTTPS certificate."
        case .dataLengthExceedsMaximum: return "\(host) sent an unexpectedly large response."
        default: return e.localizedDescription
        }
    }
}

// MARK: - Session delegate

/// Keeps the token on the server it belongs to: a redirect is followed only within the same origin
/// (scheme, host and port) and is refused otherwise, so the `Authorization` header never reaches
/// another host. Also counts requests for Settings › Sources.
final class ServerSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let countRequests: Bool

    init(countRequests: Bool) { self.countRequests = countRequests }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url,
              let origin = ServerAddress.origin(of: from), origin == ServerAddress.origin(of: to) else {
            completionHandler(nil)
            return
        }
        var same = request
        if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            same.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        completionHandler(same)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        if countRequests, task.response != nil { ApiBudget.count(.flightdeskServer) }
    }
}
