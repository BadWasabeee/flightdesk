// Shared between the FlightDesk app and its widget extension:
// data models, settings types, the live data service and lookup caching.

import Foundation
import CoreLocation
import AppIntents
import os
import CryptoKit

let fdLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "flightdesk", category: "data")

// MARK: - Shared app-group storage (app ⇄ widget)

enum Shared {
    /// Injected from the build settings (Config/Base.xcconfig → Info.plist "FDAppGroupID").
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "FDAppGroupID") as? String ?? ""
    static let widgetKind = "FlightDeskWidget"
    static let defaults: UserDefaults = groupID.isEmpty ? .standard : (UserDefaults(suiteName: groupID) ?? .standard)

    static var location: (lat: Double, lon: Double, name: String)? {
        guard let la = defaults.object(forKey: "lat") as? Double,
              let lo = defaults.object(forKey: "lon") as? Double else { return nil }
        return (la, lo, defaults.string(forKey: "placeName") ?? "")
    }

    static func setLocation(lat: Double, lon: Double, name: String) {
        defaults.set(lat, forKey: "lat")
        defaults.set(lon, forKey: "lon")
        defaults.set(name, forKey: "placeName")
    }

    static var containerURL: URL {
        (groupID.isEmpty ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID))
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}

// MARK: - Settings types (also used as native widget configuration options)

enum LEDTheme: String, AppEnum, CaseIterable, Codable {
    case amber, green, red, blue, cyan, white
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "LED Color"
    static var caseDisplayRepresentations: [LEDTheme: DisplayRepresentation] = [
        .amber: "Amber", .green: "Green", .red: "Red", .blue: "Blue", .cyan: "Cyan", .white: "White",
    ]
}

enum UnitSystem: String, AppEnum, CaseIterable, Codable {
    case imperial, metric
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Units"
    static var caseDisplayRepresentations: [UnitSystem: DisplayRepresentation] = [
        .imperial: "Aviation (ft, kt, nm)", .metric: "Metric (m, km/h, km)",
    ]
}

enum SearchRadius: String, AppEnum, CaseIterable, Codable {
    case nm5 = "5", nm10 = "10", nm25 = "25", nm50 = "50", nm100 = "100"
    var nm: Int { Int(rawValue) ?? 25 }
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Radius"
    static var caseDisplayRepresentations: [SearchRadius: DisplayRepresentation] = [
        .nm5: "5 nm (9 km)", .nm10: "10 nm (19 km)", .nm25: "25 nm (46 km)",
        .nm50: "50 nm (93 km)", .nm100: "100 nm (185 km)",
    ]
}

enum BoardStyle: String, Codable, CaseIterable {
    /// Glowing dot-matrix flight board.
    case led
    /// Clean system look that follows Light and Dark Mode.
    case standard
    var title: String { self == .led ? "LED Board" : "Standard" }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BoardStyle(rawValue: raw) ?? (raw == "glass" ? .standard : .led)   // "glass" = 1.0 name
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value if present and valid, otherwise returns `fallback` (keeps old saved settings loadable).
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

struct DisplayOptions: Codable, Equatable {
    var style: BoardStyle = .led
    var theme: LEDTheme = .amber
    var units: UnitSystem = .imperial
    var showCities = true
    var showList = true
    var glow = true
    var dotMatrix = true
    var showHeader = true
    var showLogos = true

    private var metric: Bool { units == .metric }
    var isStandard: Bool { style == .standard }
    /// LED board: compact "12,450FT". Standard: "12,450 ft".
    private func unit(_ value: String, _ led: String, _ standard: String) -> String {
        isStandard ? "\(value) \(standard)" : value + led
    }
    func altitude(_ ft: Int) -> String {
        metric ? unit(Int(Double(ft) * 0.3048).formatted(), "M", "m") : unit(ft.formatted(), "FT", "ft")
    }
    func speed(_ kt: Double) -> String { metric ? unit("\(Int(kt * 1.852))", "KMH", "km/h") : unit("\(Int(kt))", "KT", "kt") }
    func distance(_ nm: Double) -> String {
        metric ? unit(String(format: "%.1f", nm * 1.852), "KM", "km") : unit(String(format: "%.1f", nm), "NM", "nm")
    }
    func radius(_ nm: Int) -> String {
        metric ? unit("\(Int((Double(nm) * 1.852).rounded()))", "KM", "km") : unit("\(nm)", "NM", "nm")
    }
}

extension DisplayOptions {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplayOptions()
        self.init(style: c.value(.style, d.style), theme: c.value(.theme, d.theme), units: c.value(.units, d.units),
                  showCities: c.value(.showCities, d.showCities), showList: c.value(.showList, d.showList),
                  glow: c.value(.glow, d.glow), dotMatrix: c.value(.dotMatrix, d.dotMatrix),
                  showHeader: c.value(.showHeader, d.showHeader), showLogos: c.value(.showLogos, d.showLogos))
    }
}

// MARK: - App settings (written by the app, read by the widget as its defaults)

struct AppSettings: Codable, Equatable {
    var display = DisplayOptions()
    var radius: SearchRadius = .nm25
    var includeGA = true
    var rotate = true
    var showPanel = false
    var keepOnTop = false
    var widgetRefreshSeconds = 30

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        display = c.value(.display, d.display)
        radius = c.value(.radius, d.radius)
        includeGA = c.value(.includeGA, d.includeGA)
        rotate = c.value(.rotate, d.rotate)
        showPanel = c.value(.showPanel, d.showPanel)
        keepOnTop = c.value(.keepOnTop, d.keepOnTop)
        widgetRefreshSeconds = c.value(.widgetRefreshSeconds, d.widgetRefreshSeconds)
    }

    static func load() -> AppSettings {
        guard let data = Shared.defaults.data(forKey: "settings.v2"), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
    func save() { Shared.defaults.set(try? JSONEncoder().encode(self), forKey: "settings.v2") }
}

// MARK: - Domain models

struct Airport: Codable, Equatable {
    var code: String
    var city: String
    var lat: Double
    var lon: Double
}

struct RouteInfo: Codable, Equatable {
    var airline: String?
    var flightNo: String?
    /// IATA airline designator (e.g. "DL"), used for the logo. Absent in older cache entries.
    var airlineCode: String? = nil
    var from: Airport
    var to: Airport
}

struct AircraftInfo: Codable, Equatable {
    var model: String?
    var owner: String?
}

struct Flight: Identifiable, Equatable, Codable {
    let id: String          // ICAO 24-bit hex
    let callsign: String
    let reg: String
    let typeCode: String
    var altitude: Int       // feet
    let verticalRate: Double
    let speed: Double       // knots
    let track: Double?      // degrees true
    var lat: Double
    var lon: Double
    var distance: Double    // nm from you
    var bearing: Double     // degrees from you to the aircraft
    var route: RouteInfo?
    var aircraft: AircraftInfo?

    var airlineName: String { route?.airline ?? aircraft?.owner ?? "" }
    var airlineCode: String? { route?.airlineCode }

    /// How far along its route the aircraft is (0 = origin, 1 = destination), from its live position.
    var progress: Double? {
        guard let r = route else { return nil }
        let flown = FlightService.gcDistance(r.from.lat, r.from.lon, lat, lon)
        let left = FlightService.gcDistance(lat, lon, r.to.lat, r.to.lon)
        guard flown + left > 1 else { return nil }
        return min(1, max(0, flown / (flown + left)))
    }
    var displayNumber: String { route?.flightNo ?? (callsign.isEmpty ? reg : callsign) }
    var looksLikeAirline: Bool {
        let c = Array(callsign)
        return c.count >= 4 && c[0...2].allSatisfy(\.isLetter) && c[3].isNumber
    }
    var climbSymbol: String { verticalRate > 300 ? "▲" : verticalRate < -300 ? "▼" : "" }
    var direction: String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return dirs[Int((bearing.truncatingRemainder(dividingBy: 360) + 382.5) / 45) % 8]
    }

    /// Dead-reckons the aircraft forward along its live track/speed/climb rate and
    /// recomputes distance and bearing from the observer.
    func projected(by seconds: Double, observerLat: Double, observerLon: Double) -> Flight {
        guard seconds > 0, let track, speed > 30 else { return self }
        var f = self
        let d = speed * seconds / 3600 / 3440.065          // angular distance (radians)
        let φ1 = lat * .pi / 180, λ1 = lon * .pi / 180, θ = track * .pi / 180
        let φ2 = asin(sin(φ1) * cos(d) + cos(φ1) * sin(d) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(d) * cos(φ1), cos(d) - sin(φ1) * sin(φ2))
        f.lat = φ2 * 180 / .pi
        f.lon = λ2 * 180 / .pi
        f.altitude = max(0, altitude + Int(verticalRate * seconds / 60))
        f.distance = FlightService.gcDistance(observerLat, observerLon, f.lat, f.lon)
        f.bearing = FlightService.initialBearing(observerLat, observerLon, f.lat, f.lon)
        return f
    }

    init?(adsb a: ADSBAircraft) {
        guard let lat = a.lat, let lon = a.lon, let dst = a.dst, case .feet(let alt)? = a.alt_baro else { return nil }
        id = a.hex
        callsign = (a.flight ?? "").trimmingCharacters(in: .whitespaces)
        reg = a.r ?? a.hex.uppercased()
        typeCode = a.t ?? ""
        altitude = alt
        verticalRate = a.baro_rate ?? a.geom_rate ?? 0
        speed = a.gs ?? 0
        track = a.track
        self.lat = lat
        self.lon = lon
        distance = dst
        bearing = a.dir ?? 0
    }
}

/// Everything a panel or widget needs to draw one frame.
struct PanelModel: Equatable {
    var flights: [Flight] = []
    var featuredIndex = 0
    var status = ""
    var placeName = ""
    var radiusNM = 25
    var updated: Date?

    var featured: Flight? { flights.isEmpty ? nil : flights[min(featuredIndex, flights.count - 1)] }
    var others: [Flight] { flights.filter { $0.id != featured?.id } }
}

// MARK: - API wire formats

enum Altitude: Decodable {
    case ground, feet(Int)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .feet(Int(n)) } else { self = .ground }
    }
}

struct ADSBResponse: Decodable { let ac: [ADSBAircraft]? }
struct ADSBAircraft: Decodable {
    let hex: String
    let flight: String?
    let r: String?
    let t: String?
    let alt_baro: Altitude?
    let gs: Double?
    let track: Double?
    let lat: Double?
    let lon: Double?
    let dst: Double?
    let dir: Double?
    let baro_rate: Double?
    let geom_rate: Double?
}

private struct DBRouteResponse: Decodable { let response: Inner
    struct Inner: Decodable { let flightroute: Route }
    struct Route: Decodable {
        let callsign_iata: String?
        let airline: Airline?
        let origin: DBAirport
        let destination: DBAirport
    }
    struct Airline: Decodable { let name: String; let iata: String? }
}
private struct DBAirport: Decodable {
    let iata_code: String?; let icao_code: String; let municipality: String?
    let latitude: Double; let longitude: Double
    var airport: Airport { Airport(code: iata_code ?? icao_code, city: municipality ?? "", lat: latitude, lon: longitude) }
}
private struct DBAircraftResponse: Decodable { let response: Inner
    struct Inner: Decodable { let aircraft: Aircraft }
    struct Aircraft: Decodable { let type: String?; let manufacturer: String?; let registered_owner: String? }
}

// MARK: - Live data service

enum FlightService {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpAdditionalHeaders = ["User-Agent": "FlightDesk/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") (+https://github.com/BadWasabeee/flightdesk)"]
        return URLSession(configuration: c)
    }()

    /// Live aircraft around a point (adsb.lol, real-time ADS-B/MLAT), enriched with
    /// aircraft model and a route that has been checked against the live position.
    static func nearby(lat: Double, lon: Double, radiusNM: Int, includeGA: Bool,
                       limit: Int = 12, enrich: Int = 10) async throws -> [Flight] {
        // Privacy: only a coarse position (2 decimals ≈ 1 km) ever leaves the Mac.
        let url = URL(string: String(format: "https://api.adsb.lol/v2/point/%.2f/%.2f/%d", lat, lon, radiusNM))!
        let (data, resp) = try await session.data(from: url)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw URLError(.badServerResponse) }
        let all = try JSONDecoder().decode(ADSBResponse.self, from: data).ac ?? []
        var list = all.compactMap(Flight.init(adsb:))
            .filter { includeGA || $0.looksLikeAirline }
            .sorted { $0.distance < $1.distance }
        list = Array(list.prefix(limit))

        await withTaskGroup(of: (Int, RouteInfo?, AircraftInfo?).self) { group in
            for i in list.indices.prefix(enrich) {
                let f = list[i]
                group.addTask {
                    let route = f.looksLikeAirline ? await LookupCache.shared.route(f.callsign) : nil
                    let aircraft = await LookupCache.shared.aircraft(f.id)
                    return (i, route.flatMap { isPlausible($0, for: f) ? $0 : nil }, aircraft)
                }
            }
            for await (i, r, a) in group { list[i].route = r; list[i].aircraft = a }
        }
        await LookupCache.shared.save()
        await AirlineLogos.prefetch(Set(list.compactMap(\.airlineCode)))
        fdLog.info("Fetched \(list.count) flights within \(radiusNM) nm")
        return list
    }

    // MARK: Route plausibility — reject stale/reused-callsign routes using the live position.

    static func isPlausible(_ r: RouteInfo, for f: Flight) -> Bool {
        let total = gcDistance(r.from.lat, r.from.lon, r.to.lat, r.to.lon)
        let fromOrigin = gcDistance(r.from.lat, r.from.lon, f.lat, f.lon)
        let toDest = gcDistance(f.lat, f.lon, r.to.lat, r.to.lon)
        // Near either airport anything goes (departures/arrivals manoeuvre).
        if fromOrigin < 40 || toDest < 40 { return true }
        // Must be roughly between the two airports, close to the great-circle path.
        let detour = fromOrigin + toDest - total
        guard detour < max(80, total * 0.15) else { return false }
        // And heading generally toward the destination.
        if let track = f.track {
            let want = initialBearing(f.lat, f.lon, r.to.lat, r.to.lon)
            let diff = abs((track - want + 540).truncatingRemainder(dividingBy: 360) - 180)
            if diff > 100 { return false }
        }
        return true
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }

    /// Great-circle distance in nautical miles.
    static func gcDistance(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let a = sin(rad(la2 - la1) / 2) * sin(rad(la2 - la1) / 2)
            + cos(rad(la1)) * cos(rad(la2)) * sin(rad(lo2 - lo1) / 2) * sin(rad(lo2 - lo1) / 2)
        return 2 * 3440.065 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func initialBearing(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let y = sin(rad(lo2 - lo1)) * cos(rad(la2))
        let x = cos(rad(la1)) * sin(rad(la2)) - sin(rad(la1)) * cos(rad(la2)) * cos(rad(lo2 - lo1))
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: Lookups (adsbdb). Second value = definitive answer (safe to cache).

    static func fetchRoute(_ callsign: String) async -> (RouteInfo?, Bool) {
        guard let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(callsign)") else { return (nil, true) }
        guard let (data, resp) = try? await session.data(from: url) else { return (nil, false) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let r = try? JSONDecoder().decode(DBRouteResponse.self, from: data).response.flightroute else {
            return (nil, code == 200 || code == 404)
        }
        return (RouteInfo(airline: r.airline?.name, flightNo: r.callsign_iata, airlineCode: r.airline?.iata,
                          from: r.origin.airport, to: r.destination.airport), true)
    }

    static func fetchAircraft(_ hex: String) async -> (AircraftInfo?, Bool) {
        guard let url = URL(string: "https://api.adsbdb.com/v0/aircraft/\(hex)") else { return (nil, true) }
        guard let (data, resp) = try? await session.data(from: url) else { return (nil, false) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let a = try? JSONDecoder().decode(DBAircraftResponse.self, from: data).response.aircraft else {
            return (nil, code == 200 || code == 404)
        }
        let model = [a.manufacturer, a.type].compactMap { $0 }.joined(separator: " ")
        return (AircraftInfo(model: model.isEmpty ? nil : model, owner: a.registered_owner), true)
    }

    // MARK: Geocoding

    /// Resolves "City", "Airport name" or "lat, lon" to coordinates. Results are cached.
    static func resolve(_ text: String) async -> (lat: Double, lon: Double, name: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let key = "geo:" + t.lowercased()
        if let c = Shared.defaults.array(forKey: key), c.count == 3,
           let la = c[0] as? Double, let lo = c[1] as? Double, let n = c[2] as? String {
            return (la, lo, n)
        }
        var result: (lat: Double, lon: Double, name: String)?
        let parts = t.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let la = parts[0], let lo = parts[1], abs(la) <= 90, abs(lo) <= 180 {
            result = (la, lo, await placeName(lat: la, lon: lo))
        } else if let m = try? await CLGeocoder().geocodeAddressString(t).first, let loc = m.location {
            result = (loc.coordinate.latitude, loc.coordinate.longitude, m.locality ?? m.name ?? t)
        }
        if let r = result { Shared.defaults.set([r.lat, r.lon, r.name], forKey: key) }
        return result
    }

    static func placeName(lat: Double, lon: Double) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
        return marks?.first?.locality ?? String(format: "%.2f, %.2f", lat, lon)
    }
}

// MARK: - Persistent lookup cache (shared file in the app-group container)

actor LookupCache {
    static let shared = LookupCache()

    struct Entry<T: Codable>: Codable { var value: T?; var at: Date }
    struct Store: Codable {
        var routes: [String: Entry<RouteInfo>] = [:]
        var aircraft: [String: Entry<AircraftInfo>] = [:]
    }

    private var store: Store?
    private var dirty = false
    private var url: URL { Shared.containerURL.appendingPathComponent("lookup-cache-v2.json") }

    private func load() {
        if store == nil {
            store = (try? JSONDecoder().decode(Store.self, from: Data(contentsOf: url))) ?? Store()
        }
    }

    func route(_ callsign: String) async -> RouteInfo? {
        load()
        if let e = store?.routes[callsign], Date().timeIntervalSince(e.at) < 6 * 3600 { return e.value }
        let (v, definitive) = await FlightService.fetchRoute(callsign)
        if definitive { store?.routes[callsign] = Entry(value: v, at: Date()); dirty = true }
        return v
    }

    func aircraft(_ hex: String) async -> AircraftInfo? {
        load()
        if let e = store?.aircraft[hex], Date().timeIntervalSince(e.at) < 30 * 86400 { return e.value }
        let (v, definitive) = await FlightService.fetchAircraft(hex)
        if definitive { store?.aircraft[hex] = Entry(value: v, at: Date()); dirty = true }
        return v
    }

    func save() {
        guard dirty, var s = store else { return }
        if s.routes.count > 1500 {
            s.routes = Dictionary(uniqueKeysWithValues: s.routes.sorted { $0.value.at > $1.value.at }.prefix(1000).map { ($0.key, $0.value) })
        }
        if s.aircraft.count > 3000 {
            s.aircraft = Dictionary(uniqueKeysWithValues: s.aircraft.sorted { $0.value.at > $1.value.at }.prefix(2000).map { ($0.key, $0.value) })
        }
        store = s
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: url, options: .atomic)
        dirty = false
    }
}

// MARK: - Sample data (widget gallery previews, settings preview)

extension PanelModel {
    static let sample: PanelModel = {
        func f(_ id: String, _ cs: String, _ t: String, _ alt: Int, _ vr: Double, _ gs: Double, _ d: Double, _ b: Double,
               _ route: RouteInfo?, _ model: String?) -> Flight {
            let json = """
            {"hex":"\(id)","flight":"\(cs)","r":"N\(id)","t":"\(t)","alt_baro":\(alt),"gs":\(gs),"lat":39.7,"lon":-104.9,"dst":\(d),"dir":\(b),"baro_rate":\(vr)}
            """
            var fl = Flight(adsb: try! JSONDecoder().decode(ADSBAircraft.self, from: Data(json.utf8)))!
            fl.route = route
            fl.aircraft = AircraftInfo(model: model, owner: route?.airline)
            return fl
        }
        let sea = Airport(code: "SEA", city: "Seattle", lat: 47.4, lon: -122.3)
        let jfk = Airport(code: "JFK", city: "New York", lat: 40.6, lon: -73.8)
        let ord = Airport(code: "ORD", city: "Chicago", lat: 41.9, lon: -87.9)
        let lhr = Airport(code: "LHR", city: "London", lat: 51.5, lon: -0.46)
        let den = Airport(code: "DEN", city: "Denver", lat: 39.8, lon: -104.7)
        let bos = Airport(code: "BOS", city: "Boston", lat: 42.4, lon: -71.0)
        return PanelModel(flights: [
            f("a1b2c3", "DAL1342", "A321", 12_450, 1800, 312, 4.2, 95,
              RouteInfo(airline: "Delta Air Lines", flightNo: "DL1342", airlineCode: "DL", from: sea, to: jfk), "Airbus A321-211"),
            f("a2b3c4", "UAL960", "B789", 36_000, 0, 488, 11.8, 40,
              RouteInfo(airline: "United Airlines", flightNo: "UA960", airlineCode: "UA", from: ord, to: lhr), "Boeing 787 9"),
            f("a3b4c5", "SWA2210", "B38M", 7_200, -1400, 260, 14.5, 160,
              RouteInfo(airline: "Southwest Airlines", flightNo: "WN2210", airlineCode: "WN", from: den, to: ord), "Boeing 737 MAX 8"),
            f("a4b5c6", "JBU488", "A220", 24_100, 900, 401, 19.3, 300,
              RouteInfo(airline: "JetBlue", flightNo: "B6488", airlineCode: "B6", from: bos, to: den), "Airbus A220-300"),
            f("a5b6c7", "N172SP", "C172", 3_500, 0, 105, 21.0, 220, nil, "Cessna 172S"),
        ], placeName: "Denver", radiusNM: 25, updated: Date())
    }()
}


// MARK: - Airline logos

/// Square airline logos, downloaded once into the shared container so the widget can draw them
/// synchronously. Source: Kiwi.com's public airline logo CDN, keyed by IATA code.
enum AirlineLogos {
    private static var dir: URL { Shared.containerURL.appendingPathComponent("logos", isDirectory: true) }
    private static let maxAge: TimeInterval = 30 * 86_400
    private static let missAge: TimeInterval = 7 * 86_400
    /// The CDN answers unknown airlines with a generic image instead of a 404.
    private static let placeholders: Set<String> = [
        "53545c0ed6a76040fb5afe0af343ff29feb7545fceae2caaa0680c711c95657b",   // grey plane
        "1fe23e6d0b1ae8e9a8b8102f7dde086e9e3dd4de6a82f5ee73fa4616fd820855",   // "K" badge
    ]

    private static func valid(_ code: String) -> Bool {
        (2...3).contains(code.count) && code.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Local file for an airline's logo, if one has been downloaded.
    static func file(for code: String?) -> URL? {
        guard let code = code?.uppercased(), valid(code) else { return nil }
        let u = dir.appendingPathComponent("\(code).png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func prefetch(_ codes: Set<String>) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await withTaskGroup(of: Void.self) { g in
            for code in codes.map({ $0.uppercased() }) where valid(code) {
                g.addTask { await fetch(code) }
            }
        }
    }

    private static func age(_ u: URL) -> TimeInterval? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow }
    }

    private static func fetch(_ code: String) async {
        let png = dir.appendingPathComponent("\(code).png"), miss = dir.appendingPathComponent("\(code).none")
        if let a = age(png), a < maxAge { return }
        if let a = age(miss), a < missAge { return }
        guard let url = URL(string: "https://images.kiwi.com/airlines/128x128/\(code).png"),
              let (data, resp) = try? await FlightService.session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        if data.count < 1_000 || !data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || placeholders.contains(SHA256.hash(data: data).hex) {
            try? Data().write(to: miss)
        } else {
            try? data.write(to: png, options: .atomic)
        }
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
