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
        await AirlineLogos.prefetch(Set(list.compactMap(\.logoKey)))
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

// AppKit/ImageIO are only needed here: SVG logos are rasterized to PNG once, and every logo is
// checked for a transparent background before it is cached.
import AppKit
import ImageIO

extension Flight {
    /// ICAO airline designator from an airline-style callsign ("SWA2210" → "SWA"). Known even
    /// when no route has been verified.
    var airlineICAO: String? { looksLikeAirline ? String(callsign.prefix(3)).uppercased() : nil }
    /// Which airline logo to show for this flight.
    var logoKey: AirlineLogos.Key? { AirlineLogos.Key(icao: airlineICAO, iata: airlineCode) }
}

/// Transparent-background airline logos, downloaded once into the shared container so the widget
/// can draw them synchronously. Only airline codes are ever sent, never a location.
///
/// Sources, tried in order until one has a usable logo:
/// 1. Soaring Symbols (curated SVG icons, by ICAO or IATA via its MIT-licensed catalog), via jsDelivr.
/// 2. Jxck-S/airline-logos on GitHub (transparent PNG logos by ICAO, two sets), via jsDelivr
///    with raw.githubusercontent.com as a fallback.
/// 3. sexym0nk3y/airline-logos on GitHub (PNG logos by ICAO), same hosts.
/// 4. Kiwi.com's public logo CDN (by IATA).
/// Everything except the curated icons must pass `isUsable` (a transparent background), so
/// square tiles, placeholders and blank images are skipped.
enum AirlineLogos {
    /// An airline to look up: its ICAO designator (preferred) and/or IATA code.
    struct Key: Hashable, Sendable {
        let icao: String?
        let iata: String?

        init?(icao: String?, iata: String?) {
            let icao = icao?.uppercased(), iata = iata?.uppercased()
            self.icao = icao.flatMap { $0.count == 3 && $0.allSatisfy(\.isLetter) && $0.allSatisfy(\.isASCII) ? $0 : nil }
            self.iata = iata.flatMap { $0.count == 2 && $0.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII } ? $0 : nil }
            if self.icao == nil && self.iata == nil { return nil }
        }

        /// The cache file name (and the `code` passed to `AirlineLogo`).
        var id: String { icao ?? iata ?? "" }
    }

    private static var dir: URL { Shared.containerURL.appendingPathComponent("logos-v2", isDirectory: true) }
    private static var legacyDir: URL { Shared.containerURL.appendingPathComponent("logos", isDirectory: true) }
    private static let maxAge: TimeInterval = 30 * 86_400
    private static let missAge: TimeInterval = 7 * 86_400
    /// Longest side of a cached logo, in pixels.
    private static let side = 128

    /// Images the sources serve for airlines they don't really have (SHA-256 of the file).
    private static let placeholders: Set<String> = [
        "53545c0ed6a76040fb5afe0af343ff29feb7545fceae2caaa0680c711c95657b",   // Kiwi: grey plane
        "1fe23e6d0b1ae8e9a8b8102f7dde086e9e3dd4de6a82f5ee73fa4616fd820855",   // Kiwi: "K" badge
        "10cb7d062c8cb9098ebaa9e17e6ce29d9d6faad9f49597ee49293bc78f66556f",   // Jxck-S: blue/green square
        "c893c140ac2e42bfea1f787471fc6a8e708d32afbcb60d581b9ccad54270e17f",   // Jxck-S: plain black disc
    ]

    private static func valid(_ id: String) -> Bool {
        (2...3).contains(id.count) && id.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
    }

    /// Local file for an airline's logo (by `Key.id`), if one has been downloaded.
    static func file(for code: String?) -> URL? {
        guard let code = code?.uppercased(), valid(code) else { return nil }
        let u = dir.appendingPathComponent("\(code).png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func prefetch(_ keys: Set<Key>) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Drop the old solid-background logos — only inside our own app-group container, never a shared Caches folder.
        if !Shared.groupID.isEmpty, fm.fileExists(atPath: legacyDir.path) { try? fm.removeItem(at: legacyDir) }
        // One request per airline even if it's passed under several keys (e.g. with and without IATA).
        var byID: [String: Key] = [:]
        for k in keys where byID[k.id]?.iata == nil { byID[k.id] = k }
        await withTaskGroup(of: Void.self) { g in
            for key in byID.values { g.addTask { await fetch(key) } }
        }
    }

    private static func age(_ u: URL) -> TimeInterval? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow }
    }

    // MARK: Sources

    private struct Candidate {
        /// Mirrors of the same file, tried in order while they fail (not on 404).
        var urls: [URL]
        /// Curated SVG: rasterized, and trusted without the transparency check.
        var isSVG = false
    }

    private static func github(_ repo: String, _ branch: String, _ path: String) -> Candidate {
        Candidate(urls: [URL(string: "https://cdn.jsdelivr.net/gh/\(repo)@\(branch)/\(path)"),
                         URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/\(path)")].compactMap { $0 })
    }

    private static func candidates(for key: Key) async -> [Candidate] {
        var list: [Candidate] = []
        if let slug = await SoaringSymbols.shared.slug(icao: key.icao, iata: key.iata),
           let u = URL(string: "\(SoaringSymbols.base)/dist/airlines/\(slug)/icon.svg") {
            list.append(Candidate(urls: [u], isSVG: true))
        }
        if let icao = key.icao {
            list.append(github("Jxck-S/airline-logos", "main", "flightaware_logos/\(icao).png"))
            list.append(github("Jxck-S/airline-logos", "main", "radarbox_logos/\(icao).png"))
            list.append(github("sexym0nk3y/airline-logos", "main", "logos/\(icao).png"))
        }
        if let iata = key.iata, let u = URL(string: "https://images.kiwi.com/airlines/128x128/\(iata).png") {
            list.append(Candidate(urls: [u]))
        }
        return list
    }

    private enum Download { case data(Data), notFound, failed }

    private static func download(_ urls: [URL]) async -> Download {
        for url in urls {
            guard let (data, resp) = try? await FlightService.session.data(from: url),
                  let code = (resp as? HTTPURLResponse)?.statusCode else { continue }
            if code == 200 { return .data(data) }
            if code == 404 { return .notFound }
        }
        return .failed
    }

    private static func fetch(_ key: Key) async {
        let id = key.id
        guard valid(id) else { return }
        let png = dir.appendingPathComponent("\(id).png"), miss = dir.appendingPathComponent("\(id).none")
        if let a = age(png), a < maxAge { return }
        if let a = age(miss), a < missAge { return }
        // Only record a miss when every source answered; a network failure shouldn't hide logos for a week.
        var definitive = true
        for c in await candidates(for: key) {
            switch await download(c.urls) {
            case .data(let data):
                let out = c.isSVG ? rasterizedSVG(data) : (isUsable(data) ? trimmedPNG(data) : nil)
                if let out {
                    try? out.write(to: png, options: .atomic)
                    try? FileManager.default.removeItem(at: miss)
                    return
                }
            case .notFound: continue
            case .failed: definitive = false
            }
        }
        // An expired logo stays in place (still shown) if no source has a newer one.
        if definitive { try? Data().write(to: miss) }
    }

    // MARK: Image checks

    /// Whether downloaded PNG data is a real logo on a transparent background: not a known
    /// placeholder, transparent around the edges and corners, not blank, and not all white.
    static func isUsable(_ data: Data) -> Bool {
        guard data.count >= 200, data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
              !placeholders.contains(SHA256.hash(data: data).hex),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let n = 64
        guard let px = rgba(img, width: n, height: n) else { return false }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { px[(y * n + x) * 4 + 3] }
        // Corners (inset 2 px, past any anti-aliased border) must be see-through.
        guard [alpha(2, 2), alpha(n - 3, 2), alpha(2, n - 3), alpha(n - 3, n - 3)].allSatisfy({ $0 < 16 }) else { return false }
        var clear = 0, solid = 0, white = 0
        for i in 0..<(n * n) {
            let a = px[i * 4 + 3]
            if a < 16 { clear += 1 }
            if a > 128 {
                solid += 1
                // Premultiplied: near-white when every channel is close to alpha.
                if (0..<3).allSatisfy({ Int(px[i * 4 + $0]) * 10 >= Int(a) * 9 }) { white += 1 }
            }
        }
        let total = Double(n * n)
        return Double(clear) / total >= 0.15            // a background tile, not a logo
            && Double(solid) / total >= 0.03            // blank
            && Double(white) < Double(solid) * 0.9      // invisible on light backgrounds
    }

    /// An SVG rendered to PNG (longest side `side` px), so the widget only ever reads PNGs.
    static func rasterizedSVG(_ data: Data) -> Data? {
        guard data.count > 20, let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let k = CGFloat(side) / max(img.size.width, img.size.height)
        let w = max(1, Int((img.size.width * k).rounded())), h = max(1, Int((img.size.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().flatMap(trimmed).flatMap(pngData)
    }

    /// PNG data with transparent margins cropped, so logos from different sources fill the same space.
    private static func trimmedPNG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return trimmed(img).flatMap(pngData)
    }

    private static func trimmed(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let px = rgba(img, width: w, height: h) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        // Rows in `px` run top-down, matching CGImage cropping coordinates.
        let pad = 1
        let r = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                       width: min(w, maxX + pad + 1) - max(0, minX - pad),
                       height: min(h, maxY + pad + 1) - max(0, minY - pad))
        return img.cropping(to: r)
    }

    /// Premultiplied RGBA pixels, top row first.
    private static func rgba(_ img: CGImage, width: Int, height: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? px : nil
    }

    private static func pngData(_ img: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// The Soaring Symbols catalog (MIT-licensed data), reduced to code → slug and cached for a week.
actor SoaringSymbols {
    static let shared = SoaringSymbols()
    static let base = "https://cdn.jsdelivr.net/npm/soaring-symbols@0"
    private var loading: Task<[String: String], Never>?

    private var file: URL { Shared.containerURL.appendingPathComponent("logos-v2/soaring-symbols.json") }

    func slug(icao: String?, iata: String?) async -> String? {
        if loading == nil { loading = Task { await Self.load(from: file) } }
        guard let map = await loading?.value else { return nil }
        return icao.flatMap { map["ICAO:\($0)"] } ?? iata.flatMap { map["IATA:\($0)"] }
    }

    private static func load(from file: URL) async -> [String: String] {
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { -$0.timeIntervalSinceNow } ?? .infinity
        if let cached, age < 7 * 86_400 { return cached }
        guard let url = URL(string: "\(base)/dist/airlines.json"),
              let (data, resp) = try? await FlightService.session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return cached ?? [:] }
        let map = parse(data)
        if map.isEmpty { return cached ?? [:] }
        if let out = try? JSONEncoder().encode(map) { try? out.write(to: file, options: .atomic) }
        return map
    }

    /// Codes of active airlines that have a colour icon. A shared IATA code (a controlled duplicate)
    /// goes to the airline that holds it outright.
    static func parse(_ data: Data) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let airlines = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["airlines"] as? [[String: Any]]) ?? []
        var map: [String: String] = [:]
        for a in airlines {
            guard let slug = a["slug"] as? String, !slug.isEmpty,
                  slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  a["defunct"] as? Bool != true,
                  let icon = (a["assets"] as? [String: Any])?["icon"] as? [String: Any],
                  icon["color"] as? Bool == true else { continue }
            if let icao = (a["icao"] as? String)?.uppercased(), map["ICAO:\(icao)"] == nil { map["ICAO:\(icao)"] = slug }
            if let iata = (a["iata"] as? String)?.uppercased(), a["iata_duplicate"] as? Bool != true,
               map["IATA:\(iata)"] == nil { map["IATA:\(iata)"] = slug }
        }
        return map
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Deep links (widget → app)

/// flightdesk://flight/<icao-hex> opens the flight detail window in the app.
enum FlightLink {
    static let scheme = "flightdesk"

    static func url(for hex: String) -> URL {
        URL(string: "\(scheme)://flight/\(hex.lowercased())")!
    }

    /// The aircraft hex from a FlightDesk deep link, or nil for anything else.
    static func hex(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "flight" else { return nil }
        let h = url.lastPathComponent.lowercased()
        return h.range(of: "^~?[0-9a-f]{6}$", options: .regularExpression) != nil ? h : nil
    }
}
