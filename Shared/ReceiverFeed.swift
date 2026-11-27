// Reads live aircraft straight from the user's own ADS-B receiver on the local network
// (dump1090-fa / SkyAware, readsb, tar1090, ultrafeeder). Compiled into every target.

import Foundation

// MARK: - Settings

/// The user's own receiver. Stored on its own key in the app group so the widget sees it too.
struct ReceiverSettings: Codable, Equatable, Sendable {
    /// Read from the receiver at all.
    var enabled = false
    /// What the user typed: a base URL such as `http://raspberrypi.local/tar1090`, or the JSON itself.
    var url = ""
    /// Never fall back to the internet feeds.
    var useAsOnlySource = false

    static let defaultsKey = "receiver"

    var hasURL: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The receiver should be asked for data.
    var isActive: Bool { enabled && hasURL }
    /// Distinguishes cached results by source mode, so switching sources (or "receiver only")
    /// never serves a list fetched under another mode.
    var cacheTag: String { isActive ? (useAsOnlySource ? "|rx-only" : "|rx") : "" }

    static var current: ReceiverSettings {
        guard let data = Shared.defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(ReceiverSettings.self, from: data) else { return ReceiverSettings() }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Shared.defaults.set(data, forKey: Self.defaultsKey)
    }

    init(enabled: Bool = false, url: String = "", useAsOnlySource: Bool = false) {
        self.enabled = enabled
        self.url = url
        self.useAsOnlySource = useAsOnlySource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, false)
        url = c.value(.url, "")
        useAsOnlySource = c.value(.useAsOnlySource, false)
    }
}

// MARK: - Wire format

/// A receiver's `aircraft.json`: `{"now": …, "messages": …, "aircraft": [ … ]}`.
/// Unlike the aggregator APIs it has no observer distance (`dst`/`dir`) and often no registration/type.
struct ReceiverAircraftFile: Decodable, Sendable {
    let now: Double?
    let messages: Int?
    let aircraft: [ReceiverAircraft]

    private enum CodingKeys: String, CodingKey { case now, messages, aircraft }
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = c.value(.now, nil)
        messages = c.value(.messages, nil)
        // One malformed entry shouldn't hide every other aircraft.
        var list = try c.nestedUnkeyedContainer(forKey: .aircraft)
        var out: [ReceiverAircraft] = []
        while !list.isAtEnd {
            if let a = try? list.decode(ReceiverAircraft.self) { out.append(a) } else { _ = try? list.decode(Skip.self) }
        }
        aircraft = out
    }
}

/// One aircraft in a receiver's `aircraft.json`. Older dump1090 builds use `altitude`/`speed`/`vert_rate`.
struct ReceiverAircraft: Decodable, Sendable {
    let hex: String
    var flight: String? = nil
    var r: String? = nil
    var t: String? = nil
    var alt_baro: Altitude? = nil
    var altitude: Altitude? = nil
    var gs: Double? = nil
    var speed: Double? = nil
    var track: Double? = nil
    var lat: Double? = nil
    var lon: Double? = nil
    /// Seconds since the position was last updated.
    var seen_pos: Double? = nil
    var baro_rate: Double? = nil
    var geom_rate: Double? = nil
    var vert_rate: Double? = nil
    var squawk: String? = nil
}

extension Flight {
    /// Builds a flight from a receiver record, computing distance and bearing from `observer`.
    /// Nil without a position, with a position older than `maxPositionAge` seconds, or (unless
    /// `allowGround`) for ground traffic, matching what the aggregator feeds return.
    init?(receiver a: ReceiverAircraft, observer: GeoPoint, maxPositionAge: TimeInterval = ReceiverFeed.maxPositionAge,
          allowGround: Bool = false) {
        guard let lat = a.lat, let lon = a.lon, abs(lat) <= 90, abs(lon) <= 180,
              (a.seen_pos ?? 0) <= maxPositionAge else { return nil }
        let alt: Int
        switch a.alt_baro ?? a.altitude {
        case .feet(let ft)?: alt = ft
        case .ground?: guard allowGround else { return nil }; alt = 0
        case nil: return nil
        }
        id = a.hex.lowercased()
        callsign = (a.flight ?? "").trimmingCharacters(in: .whitespaces)
        reg = a.r ?? a.hex.uppercased()
        typeCode = a.t ?? ""
        altitude = alt
        verticalRate = a.baro_rate ?? a.geom_rate ?? a.vert_rate ?? 0
        speed = a.gs ?? a.speed ?? 0
        track = a.track
        self.lat = lat
        self.lon = lon
        distance = FlightService.gcDistance(observer.lat, observer.lon, lat, lon)
        bearing = FlightService.initialBearing(observer.lat, observer.lon, lat, lon)
        let code = a.squawk?.trimmingCharacters(in: .whitespaces) ?? ""
        squawk = code.isEmpty ? nil : code
    }
}

// MARK: - Errors

enum ReceiverError: LocalizedError, Equatable {
    case invalidURL
    /// The server answered, but not with aircraft JSON at any known path.
    case noAircraftData(host: String)
    case httpStatus(Int)
    case notAircraftJSON

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter your receiver’s address, like http://raspberrypi.local/tar1090."
        case .noAircraftData(let host): "\(host) answered, but no aircraft data was found there. Enter the address of the receiver’s map page (tar1090, SkyAware or dump1090) — FlightDesk finds aircraft.json from it."
        case .httpStatus(let code): "The receiver answered with an error (HTTP \(code))."
        case .notAircraftJSON: "The receiver answered, but not with aircraft data."
        }
    }
}

// MARK: - Receiver feed

enum ReceiverFeed {
    /// Positions older than this are skipped (the aircraft has likely left coverage).
    static let maxPositionAge: TimeInterval = 60
    /// How long a failing receiver is skipped (when internet feeds may stand in).
    static let benchSeconds: TimeInterval = 60

    /// JSON paths tried below the user's base URL, most common first.
    static let knownPaths = [
        "/data/aircraft.json",              // tar1090, readsb, dump1090-fa (SkyAware), ultrafeeder
        "/aircraft.json",
        "/tar1090/data/aircraft.json",
        "/skyaware/data/aircraft.json",     // PiAware
        "/dump1090-fa/data/aircraft.json",
        "/dump1090/data/aircraft.json",
    ]

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 8
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: URL discovery

    /// URLs that may serve `aircraft.json` for what the user typed, in probing order. Adds `http://`
    /// when no scheme is given, ignores query/fragment and a copied page name (`index.html`), and
    /// returns a URL ending in `.json` as is.
    static func candidateURLs(for input: String) -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if !text.contains("://") { text = "http://" + text }
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty else { return [] }
        c.scheme = scheme
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        var path = c.path
        func trimSlashes() { while path.hasSuffix("/") { path.removeLast() } }
        trimSlashes()
        if path.lowercased().hasSuffix(".json") {
            c.path = path
            return c.url.map { [$0] } ?? []
        }
        if let last = path.split(separator: "/").last?.lowercased(), last.hasSuffix(".html") || last.hasSuffix(".htm") {
            path = String(path[..<path.lastIndex(of: "/")!])
            trimSlashes()
        }
        var paths = knownPaths
        if path.lowercased().hasSuffix("/data") { paths.swapAt(0, 1) }   // user already typed …/data
        var seen = Set<String>()
        return paths.compactMap { suffix in
            c.path = path + suffix
            guard let u = c.url, seen.insert(u.absoluteString).inserted else { return nil }
            return u
        }
    }

    private static let resolvedKey = "receiverResolvedURL"

    /// The JSON URL discovered for `base`, if any. Kept apart from `ReceiverSettings` so a settings
    /// save from the UI never races with discovery in the widget.
    static func rememberedURL(for base: String) -> URL? {
        guard let map = Shared.defaults.dictionary(forKey: resolvedKey) as? [String: String],
              let s = map[base] else { return nil }
        return URL(string: s)
    }

    static func remember(_ url: URL, for base: String) {
        Shared.defaults.set([base: url.absoluteString], forKey: resolvedKey)
    }

    /// Fetches and decodes one candidate URL.
    static func get(_ url: URL) async throws -> ReceiverAircraftFile {
        let (data, resp) = try await session.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ReceiverError.httpStatus(code) }
        guard let file = try? JSONDecoder().decode(ReceiverAircraftFile.self, from: data) else {
            throw ReceiverError.notAircraftJSON
        }
        return file
    }

    /// Probes every candidate path in parallel and returns the first working one in probing order.
    static func discover(_ base: String) async throws -> (url: URL, file: ReceiverAircraftFile) {
        let candidates = candidateURLs(for: base)
        guard let host = candidates.first?.host else { throw ReceiverError.invalidURL }
        let results = await withTaskGroup(of: (Int, Result<ReceiverAircraftFile, Error>).self) { group in
            for (i, url) in candidates.enumerated() {
                group.addTask {
                    do { return (i, .success(try await get(url))) } catch { return (i, .failure(error)) }
                }
            }
            var out: [Int: Result<ReceiverAircraftFile, Error>] = [:]
            for await (i, r) in group { out[i] = r }
            return out
        }
        var firstError: Error?
        var serverAnswered = false
        for i in candidates.indices {
            switch results[i] {
            case .success(let file)?: return (candidates[i], file)
            case .failure(let e)?:
                if e is ReceiverError { serverAnswered = true }
                if firstError == nil { firstError = e }
            case nil: break
            }
        }
        if serverAnswered { throw ReceiverError.noAircraftData(host: host) }
        throw firstError ?? ReceiverError.invalidURL
    }

    /// The receiver's current aircraft, using the remembered JSON URL and re-discovering it when the
    /// server answers but the path no longer works. Updates `FeedHealth`.
    static func fetchFile(_ settings: ReceiverSettings) async throws -> ReceiverAircraftFile {
        do {
            let file: ReceiverAircraftFile
            if let url = rememberedURL(for: settings.url) {
                do {
                    file = try await get(url)
                } catch is ReceiverError {
                    let found = try await discover(settings.url)
                    remember(found.url, for: settings.url)
                    file = found.file
                }
            } else {
                let found = try await discover(settings.url)
                remember(found.url, for: settings.url)
                file = found.file
            }
            await FeedHealth.shared.receiverSucceeded()
            return file
        } catch {
            fdLog.info("Receiver unavailable: \(error.localizedDescription, privacy: .public)")
            await FeedHealth.shared.receiverFailed(for: benchSeconds)
            throw error
        }
    }

    // MARK: Queries

    /// Aircraft within `radiusNM` of `observer`, nearest first.
    static func flights(in file: ReceiverAircraftFile, observer: GeoPoint, radiusNM: Int) -> [Flight] {
        file.aircraft
            .compactMap { Flight(receiver: $0, observer: observer) }
            .filter { $0.distance <= Double(radiusNM) }
            .sorted { $0.distance < $1.distance }
    }

    /// Nearby aircraft from the receiver. The position is only used locally.
    static func nearby(lat: Double, lon: Double, radiusNM: Int, settings: ReceiverSettings) async throws -> [Flight] {
        let file = try await fetchFile(settings)
        await FeedHealth.shared.served(.receiver)
        return flights(in: file, observer: GeoPoint(lat: lat, lon: lon), radiusNM: radiusNM)
    }

    /// The live report for one aircraft from a receiver file, or nil when it isn't there with a fresh position.
    static func report(hex: String, in file: ReceiverAircraftFile, observer: GeoPoint?, now: Date = Date()) -> AircraftReport? {
        let id = hex.lowercased()
        guard let a = file.aircraft.first(where: { $0.hex.lowercased() == id }),
              let flight = Flight(receiver: a, observer: observer ?? GeoPoint(lat: a.lat ?? 0, lon: a.lon ?? 0),
                                  allowGround: true) else { return nil }
        var f = flight
        if observer == nil { f.distance = 0; f.bearing = 0 }
        let code = a.squawk?.trimmingCharacters(in: .whitespaces) ?? ""
        let onGround: Bool
        if case .ground? = a.alt_baro ?? a.altitude { onGround = true } else { onGround = false }
        return AircraftReport(flight: f, squawk: code.isEmpty ? nil : code, onGround: onGround,
                              positionTime: now.addingTimeInterval(-(a.seen_pos ?? 0)))
    }

    static func report(hex: String, observer: GeoPoint?, settings: ReceiverSettings) async throws -> AircraftReport? {
        let file = try await fetchFile(settings)
        guard let r = report(hex: hex, in: file, observer: observer) else { return nil }
        await FeedHealth.shared.served(.receiver)
        return r
    }

    // MARK: Source routing

    /// Runs the receiver (`local`) and/or the internet feeds in the order the settings and feed health
    /// call for. A nil result means "answered, but doesn't have it", so the other source is tried.
    /// - Inactive receiver: internet only.  "Only my receiver": receiver only.
    /// - Healthy receiver: receiver, then internet.  Benched receiver: internet, then receiver.
    static func route<T>(_ settings: ReceiverSettings,
                         local: () async throws -> T?,
                         internet: () async throws -> T?) async throws -> T? {
        guard settings.isActive else { return try await internet() }
        if settings.useAsOnlySource { return try await local() }
        if await FeedHealth.shared.receiverIsHealthy() {
            if let v = try? await local() { return v }
            return try await internet()
        }
        var internetError: Error?
        do { if let v = try await internet() { return v } } catch { internetError = error }
        if let v = try? await local() { return v }
        if let internetError { throw internetError }
        return nil
    }

    // MARK: Connection test (Settings)

    struct TestResult: Equatable {
        var ok: Bool
        var message: String
        /// The JSON URL in use, when connected.
        var detail: String?
    }

    /// Discovers the receiver at `base`, remembers the working path, and describes the result.
    /// `radiusLabel` is the search radius as the user sees it (e.g. "100 nm" or "185 km").
    static func test(_ base: String, observer: GeoPoint?, radiusNM: Int?, radiusLabel: String? = nil) async -> TestResult {
        let start = Date()
        do {
            let found = try await discover(base)
            let elapsed = Date().timeIntervalSince(start)
            remember(found.url, for: base)
            await FeedHealth.shared.receiverSucceeded()
            let software = await softwareName(near: found.url)
            var near: Int?
            if let observer, let radiusNM { near = flights(in: found.file, observer: observer, radiusNM: radiusNM).count }
            return connected(total: found.file.aircraft.count, near: near,
                             radius: radiusLabel ?? radiusNM.map { "\($0) nm" }, software: software,
                             elapsed: elapsed, url: found.url)
        } catch {
            return TestResult(ok: false, message: describe(error, base: base))
        }
    }

    /// The success message, e.g. "Connected to readsb · 214 aircraft, 37 within 100 nm"
    /// with detail "http://pi.local/tar1090/data/aircraft.json · 45 ms".
    static func connected(total: Int, near: Int?, radius: String?, software: String?,
                          elapsed: TimeInterval, url: URL) -> TestResult {
        var text = software.map { "Connected to \($0)" } ?? "Connected"
        text += " · \(total.formatted()) aircraft"
        if let near, let radius { text += ", \(near.formatted()) within \(radius)" }
        let time = elapsed < 1 ? "\(max(1, Int(elapsed * 1000))) ms" : String(format: "%.1f s", elapsed)
        return TestResult(ok: true, message: text, detail: "\(url.absoluteString) · \(time)")
    }

    /// Best-effort decoder name from the `receiver.json` next to `aircraft.json` and the URL path.
    static func softwareName(near url: URL) async -> String? {
        struct Info: Decodable { let version: String? }
        let infoURL = url.deletingLastPathComponent().appendingPathComponent("receiver.json")
        var version = ""
        if let (data, resp) = try? await session.data(from: infoURL), (resp as? HTTPURLResponse)?.statusCode == 200 {
            version = ((try? JSONDecoder().decode(Info.self, from: data))?.version ?? "").lowercased()
        }
        return softwareName(version: version, path: url.path.lowercased())
    }

    static func softwareName(version: String, path: String) -> String? {
        if version.contains("readsb") || version.contains("wiedehopf") { return "readsb" }
        if version.contains("dump1090-fa") || path.contains("skyaware") || path.contains("dump1090-fa") { return "dump1090-fa" }
        if version.contains("dump1090") || path.contains("dump1090") { return "dump1090" }
        if path.contains("tar1090") { return "tar1090" }
        return nil
    }

    /// A helpful explanation for a failed connection.
    static func describe(_ error: Error, base: String) -> String {
        let host = candidateURLs(for: base).first?.host ?? "the receiver"
        if let e = error as? ReceiverError { return e.localizedDescription }
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "Couldn’t find \(host). Check the name, or use the receiver’s IP address, like http://192.168.1.50."
        case .timedOut:
            return "No answer from \(host). Check that the receiver is on and on the same network as this Mac."
        case .cannotConnectToHost:
            return "\(host) refused the connection. Check the port: tar1090 and SkyAware use 80, ultrafeeder often 8080."
        case .notConnectedToInternet, .networkConnectionLost:
            return "Couldn’t reach \(host). Allow FlightDesk in System Settings › Privacy & Security › Local Network."
        case .appTransportSecurityRequiresSecureConnection:
            return "macOS blocks plain http to \(host). Use the receiver’s IP address or its .local name instead."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "The secure connection to \(host) failed. Try http:// instead of https://."
        default:
            return e.localizedDescription
        }
    }
}
