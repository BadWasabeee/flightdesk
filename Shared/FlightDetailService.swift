// Live data and pure geometry for the app's flight detail window.
// Compiled into every target, so it stays free of AppKit and MapKit.

import Foundation

/// A latitude/longitude pair in degrees.
struct GeoPoint: Equatable, Sendable {
    var lat: Double
    var lon: Double
}

extension Flight {
    var geoPoint: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

extension Airport {
    var geoPoint: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

// MARK: - Geometry & formatting helpers

enum FlightMath {
    /// `count` points evenly spaced along the great circle from `a` to `b`, both ends included.
    static func greatCircle(from a: GeoPoint, to b: GeoPoint, count: Int = 64) -> [GeoPoint] {
        let n = max(2, count)
        let φ1 = a.lat * .pi / 180, λ1 = a.lon * .pi / 180
        let φ2 = b.lat * .pi / 180, λ2 = b.lon * .pi / 180
        let d = 2 * asin(sqrt(pow(sin((φ2 - φ1) / 2), 2) + cos(φ1) * cos(φ2) * pow(sin((λ2 - λ1) / 2), 2)))
        guard d > 1e-9 else { return [a, b] }
        return (0..<n).map { i in
            let f = Double(i) / Double(n - 1)
            let A = sin((1 - f) * d) / sin(d), B = sin(f * d) / sin(d)
            let x = A * cos(φ1) * cos(λ1) + B * cos(φ2) * cos(λ2)
            let y = A * cos(φ1) * sin(λ1) + B * cos(φ2) * sin(λ2)
            let z = A * sin(φ1) + B * sin(φ2)
            return GeoPoint(lat: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, lon: atan2(y, x) * 180 / .pi)
        }
    }

    /// Time to cover `remainingNM` at `speedKT`, or nil when the aircraft is too slow for a meaningful estimate.
    /// Drops consecutive points closer than ~20 m; repeated vertices stop MapKit drawing the map.
    static func removingRepeats(_ points: [GeoPoint]) -> [GeoPoint] {
        var out: [GeoPoint] = []
        out.reserveCapacity(points.count)
        for p in points where p.lat.isFinite && p.lon.isFinite {
            if let last = out.last, FlightService.gcDistance(last.lat, last.lon, p.lat, p.lon) < 0.01 { continue }
            out.append(p)
        }
        return out
    }

    /// Points on a circle of `radiusNM` around `center` (true distances on the sphere).
    static func circle(around center: GeoPoint, radiusNM: Double, count: Int = 120) -> [GeoPoint] {
        let δ = radiusNM / 3440.065, φ1 = center.lat * .pi / 180, λ1 = center.lon * .pi / 180
        return (0..<count).map { i in
            let θ = Double(i) / Double(count) * 2 * .pi
            let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
            let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
            return GeoPoint(lat: φ2 * 180 / .pi, lon: λ2 * 180 / .pi)
        }
    }

    static func timeToGo(remainingNM: Double, speedKT: Double) -> TimeInterval? {
        guard speedKT > 50, remainingNM >= 0 else { return nil }
        return remainingNM / speedKT * 3600
    }

    /// "1 h 23 m", "12 m" or "< 1 m".
    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "< 1 m" }
        return minutes < 60 ? "\(minutes) m" : "\(minutes / 60) h \(minutes % 60) m"
    }

    /// 16-point compass name for a direction in degrees ("N", "NNE", …).
    static func compassPoint(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((d + 11.25) / 22.5) % 16]
    }
}

// MARK: - Single-aircraft lookup

/// One live report for a single aircraft.
struct AircraftReport: Equatable {
    var flight: Flight
    /// Transponder code, when reported.
    var squawk: String?
    var onGround: Bool
    /// When the position was received.
    var positionTime: Date
    /// Year the airframe was built, when the feed's aircraft database knows it.
    var year: Int? = nil
}

/// adsb.lol record for the per-aircraft endpoint. Unlike the point query it has no observer
/// distance, may report ground traffic, and carries extra fields (squawk, description).
struct DetailAircraftRecord: Decodable {
    struct LastPosition: Decodable { let lat: Double; let lon: Double; let seen_pos: Double? }
    let hex: String
    let flight: String?
    let r: String?
    let t: String?
    let desc: String?
    let ownOp: String?
    let alt_baro: Altitude?
    let gs: Double?
    let track: Double?
    let true_heading: Double?
    let lat: Double?
    let lon: Double?
    let baro_rate: Double?
    let geom_rate: Double?
    let squawk: String?
    let seen_pos: Double?
    let lastPosition: LastPosition?
    /// Build year; feeds send it as a string ("2019"), occasionally as a number.
    let year: BuildYear?

    /// Decodes a year from a string or number, never failing the enclosing record.
    struct BuildYear: Decodable {
        let value: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw = (try? c.decode(Int.self)) ?? (try? c.decode(String.self)).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            value = raw.flatMap { (1900...2100).contains($0) ? $0 : nil }
        }
    }
}

private struct DetailResponse: Decodable {
    let ac: [DetailAircraftRecord]?
    private enum CodingKeys: String, CodingKey { case ac, aircraft }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ac = c.value(.ac, nil) ?? c.value(.aircraft, nil)
    }
}

extension AircraftReport {
    /// Builds a report from a record. Distance and bearing are computed locally from `observer`.
    init?(record a: DetailAircraftRecord, observer: GeoPoint?, now: Date = Date()) {
        let pos: (lat: Double, lon: Double, age: Double)
        if let lat = a.lat, let lon = a.lon {
            pos = (lat, lon, a.seen_pos ?? 0)
        } else if let last = a.lastPosition {
            pos = (last.lat, last.lon, last.seen_pos ?? 0)
        } else {
            return nil
        }
        var altitude = 0
        if case .feet(let ft)? = a.alt_baro { altitude = ft }
        flight = Flight(id: a.hex, callsign: (a.flight ?? "").trimmingCharacters(in: .whitespaces),
                        reg: a.r ?? a.hex.uppercased(), typeCode: a.t ?? "", altitude: altitude,
                        verticalRate: a.baro_rate ?? a.geom_rate ?? 0, speed: a.gs ?? 0,
                        track: a.track ?? a.true_heading, lat: pos.lat, lon: pos.lon, observer: observer)
        if a.desc != nil || a.ownOp != nil {
            flight.aircraft = AircraftInfo(model: a.desc?.capitalized, owner: a.ownOp?.capitalized)
        }
        let code = a.squawk?.trimmingCharacters(in: .whitespaces) ?? ""
        squawk = code.isEmpty ? nil : code
        flight.squawk = squawk
        if case .ground? = a.alt_baro { onGround = true } else { onGround = false }
        positionTime = now.addingTimeInterval(-pos.age)
        year = a.year?.value
    }
}

private extension Flight {
    init(id: String, callsign: String, reg: String, typeCode: String, altitude: Int, verticalRate: Double,
         speed: Double, track: Double?, lat: Double, lon: Double, observer: GeoPoint?) {
        self.id = id
        self.callsign = callsign
        self.reg = reg
        self.typeCode = typeCode
        self.altitude = altitude
        self.verticalRate = verticalRate
        self.speed = speed
        self.track = track
        self.lat = lat
        self.lon = lon
        distance = observer.map { FlightService.gcDistance($0.lat, $0.lon, lat, lon) } ?? 0
        bearing = observer.map { FlightService.initialBearing($0.lat, $0.lon, lat, lon) } ?? 0
    }
}

enum FlightDetailService {
    /// The latest report for one aircraft, or nil when the live feeds no longer have it.
    /// Only the aircraft's hex is sent; the observer position is used locally. Uses the user's own
    /// receiver first when enabled (see `ReceiverFeed.route` for the fallback order).
    /// With `preferCache`, a fresh shared nearby list answers instead of a network request (it lacks
    /// extras such as the build year, so callers do one full fetch first).
    static func report(hex: String, preferCache: Bool = false) async throws -> AircraftReport? {
        let observer = Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) }
        let receiver = ReceiverSettings.current
        return try await ReceiverFeed.route(receiver, local: {
            try await ReceiverFeed.report(hex: hex, observer: observer, settings: receiver)
        }, internet: {
            // Inside the search radius the shared nearby list already has this aircraft: no request.
            if preferCache, let e = NearbyCache.latest(maxAge: 20), let f = e.flights.first(where: { $0.id == hex }) {
                return AircraftReport(flight: f, squawk: f.squawk, onGround: false, positionTime: e.time)
            }
            let data = try await LiveFeed.fetch { $0.hexURL(hex) }
            let records = try JSONDecoder().decode(DetailResponse.self, from: data).ac ?? []
            return records.lazy.compactMap { AircraftReport(record: $0, observer: observer) }.first
        })
    }

    /// The aircraft's track for its current flight from the OpenSky Network (anonymous, about 400
    /// requests a day). Each flight's track is downloaded once and cached on disk for the app and
    /// widget; live positions extend it afterwards. Nil when unavailable, when OpenSky is near its
    /// limit, or when the track belongs to another leg.
    static func track(hex: String, current: GeoPoint?) async -> FlightTrack? {
        guard let id = TrackCache.openSkyID(hex) else { return nil }
        if let cached = TrackCache.track(for: id, current: current) { return cached }
        guard ApiBudget.isAvailable(.openSky),
              let url = RemoteURL.make("https://opensky-network.org/api/tracks/all", query: [("icao24", id), ("time", "0")]),
              let (data, resp) = try? await FlightService.session.boundedData(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let track = FlightTrack(data: data, current: current) else { return nil }
        TrackCache.store(data, for: id)
        return track
    }

    /// Route and aircraft details for a flight from the shared lookup cache. The route is returned
    /// unchecked; callers verify it against each live position with `FlightService.isPlausible`.
    static func enrichment(for f: Flight) async -> (route: RouteInfo?, aircraft: AircraftInfo?) {
        async let route = f.looksLikeAirline ? LookupCache.shared.route(f.callsign) : nil
        async let aircraft = LookupCache.shared.aircraft(f.id)
        let result = await (route, aircraft)
        await LookupCache.shared.save()
        if let key = AirlineLogos.Key(icao: f.airlineICAO, iata: result.0?.airlineCode) { await AirlineLogos.prefetch([key]) }
        return result
    }
}

/// A position with the time it was reported.
struct TimedPoint: Equatable, Sendable {
    var point: GeoPoint
    var time: Date
}

/// A recorded track, oldest first.
struct FlightTrack: Equatable, Sendable {
    var points: [TimedPoint]
    /// Altitude of the first waypoint in feet (low means the track starts at the departure airport).
    var startAltitudeFt: Double?

    /// Parses OpenSky waypoints `[time, lat, lon, baro altitude m, true track, on ground]`.
    /// Returns nil for tracks that are too short, stale (> 30 min old) or don't end near `current`.
    init?(waypoints: [[Any]], current: GeoPoint?, now: Date = Date()) {
        let parsed = waypoints.compactMap { w -> (TimedPoint, Double?)? in
            guard w.count >= 3, let t = (w[0] as? NSNumber)?.doubleValue,
                  let lat = (w[1] as? NSNumber)?.doubleValue, let lon = (w[2] as? NSNumber)?.doubleValue else { return nil }
            let alt = w.count > 3 ? (w[3] as? NSNumber)?.doubleValue : nil
            return (TimedPoint(point: GeoPoint(lat: lat, lon: lon), time: Date(timeIntervalSince1970: t)), alt)
        }
        guard parsed.count > 1, let last = parsed.last?.0, now.timeIntervalSince(last.time) < 30 * 60 else { return nil }
        if let c = current, FlightService.gcDistance(c.lat, c.lon, last.point.lat, last.point.lon) > 60 { return nil }
        points = parsed.map(\.0)
        startAltitudeFt = parsed.first?.1.map { $0 * 3.28084 }
    }
}

// MARK: - Detail presentation (pure, unit-tested)

/// Formatting and small decisions for the flight detail view, kept free of UI frameworks so
/// they can be unit-tested.
enum DetailFormat {
    /// Distance with sensible precision: one decimal under 10, whole grouped numbers above
    /// ("6,424 nm", "3.7 nm").
    static func distance(_ nm: Double, units: UnitSystem, locale: Locale = .autoupdatingCurrent) -> String {
        let metric = units == .metric
        let value = max(0, metric ? nm * 1.852 : nm)
        let number = value < 9.95
            ? value.formatted(.number.precision(.fractionLength(1)).locale(locale))
            : Int(value.rounded()).formatted(.number.locale(locale))
        return "\(number) \(metric ? "km" : "nm")"
    }

    /// "Level", "+1,250 fpm" (rounded to 50) or, for metric users, "−6.4 m/s".
    static func verticalRate(_ fpm: Double, units: UnitSystem, locale: Locale = .autoupdatingCurrent) -> String {
        guard abs(fpm) >= 100 else { return "Level" }
        if units == .metric {
            let ms = fpm * 0.00508
            return "\(ms.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()).locale(locale))) m/s"
        }
        let rounded = Int((fpm / 50).rounded()) * 50
        return "\(rounded.formatted(.number.sign(strategy: .always()).locale(locale))) fpm"
    }

    /// Three-digit heading with its compass point: "095° E".
    static func heading(_ degrees: Double) -> String {
        let d = (Int(degrees.rounded()) % 360 + 360) % 360
        return String(format: "%03d° ", d) + FlightMath.compassPoint(Double(d))
    }

    /// "2009 · 17 years old", or just the year for a brand-new airframe.
    static func built(_ year: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let age = calendar.component(.year, from: now) - year
        guard age > 0 else { return String(year) }
        return "\(String(year)) · \(age) \(age == 1 ? "year" : "years") old"
    }

    /// "just now", "4 min ago", "2 h 5 m ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3_600 { return "\(Int(s / 60)) min ago" }
        return "\(FlightMath.durationText(s)) ago"
    }

    /// The headline identifier for an aircraft: its flight number, callsign or registration.
    static func title(for f: Flight?, hex: String) -> String {
        guard let f, !f.displayNumber.isEmpty else { return hex.uppercased() }
        return f.displayNumber
    }

    /// "LAS → MKE · Southwest Airlines" (the diversion airport while diverting); empty when nothing
    /// is known beyond the number.
    static func subtitle(for f: Flight?) -> String {
        guard let f else { return "" }
        var parts: [String] = []
        if let r = f.route { parts.append("\(r.from.code) → \((f.destination ?? r.to).code)") }
        if !f.airlineName.isEmpty { parts.append(f.airlineName) } else if let model = f.aircraft?.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    /// Arrival state shown on the route card.
    enum Arrival: Equatable {
        case landed
        case landing
        /// Time to go at the current ground speed (an estimate, labelled as such).
        case estimate(TimeInterval)
    }

    /// Arrival state from the live position, or nil when there's nothing honest to say
    /// (on the ground away from the destination, or too slow for an estimate).
    static func arrival(remainingNM: Double, speedKT: Double, altitudeFt: Int, verticalRate: Double, onGround: Bool) -> Arrival? {
        if onGround { return remainingNM < 5 ? .landed : nil }
        if remainingNM < 10, altitudeFt < 3_000, verticalRate < -200 { return .landing }
        return FlightMath.timeToGo(remainingNM: remainingNM, speedKT: speedKT).map(Arrival.estimate)
    }

    /// How much to draw for other aircraft at a map zoom level (visible latitude span in degrees):
    /// nothing at continental scale, bare icons regionally, labelled icons close in.
    enum MapDetail: Int, Comparable {
        case hidden, icons, labelled
        init(latitudeSpan: Double) {
            self = latitudeSpan < 5 ? .labelled : latitudeSpan < 14 ? .icons : .hidden
        }
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// A map region in degrees.
    struct Framing: Equatable {
        var center: GeoPoint
        var latitudeDelta: Double
        var longitudeDelta: Double
    }

    /// The smallest region containing `points` plus a margin, handling routes across the
    /// antimeridian (the region spans the longitudes' largest gap's complement).
    static func framing(_ points: [GeoPoint], margin: Double = 0.18, minimumDegrees: Double = 0.3) -> Framing? {
        let pts = points.filter { $0.lat.isFinite && $0.lon.isFinite }
        guard !pts.isEmpty else { return nil }
        func wrap(_ l: Double) -> Double { ((l + 180).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) - 180 }
        let lons = pts.map { wrap($0.lon) }.sorted()
        var start = lons[0], biggestGap = 360 - (lons[lons.count - 1] - lons[0])
        for i in lons.indices.dropFirst() where lons[i] - lons[i - 1] > biggestGap {
            biggestGap = lons[i] - lons[i - 1]
            start = lons[i]
        }
        let lonSpan = 360 - biggestGap
        let lats = pts.map { min(85, max(-85, $0.lat)) }
        let minLat = lats.min()!, maxLat = lats.max()!
        // Centre on the Mercator midpoint so the route sits in the middle of the map.
        func y(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
        let midY = (y(minLat) + y(maxLat)) / 2
        let centerLat = (2 * atan(exp(midY)) - .pi / 2) * 180 / .pi
        let halfLat = max(maxLat - centerLat, centerLat - minLat)
        let latDelta = min(170, max(minimumDegrees, 2 * halfLat * (1 + 2 * margin)))
        let cosLat = max(0.2, cos(centerLat * .pi / 180))
        let lonDelta = min(360, max(minimumDegrees / cosLat, lonSpan * (1 + 2 * margin)))
        return Framing(center: GeoPoint(lat: centerLat, lon: wrap(start + lonSpan / 2)),
                       latitudeDelta: latDelta, longitudeDelta: lonDelta)
    }

    /// What to say about where to look: a headline ("Look 32° up, toward NE") and a detail line.
    static func lookUp(_ sky: SkyPosition) -> (headline: String, detail: String) {
        let bearing = String(format: "%03d°", Int(sky.azimuth.rounded()) % 360)
        guard sky.isAboveHorizon else {
            return ("Below your horizon", "Toward \(sky.compassPoint) (\(bearing)), hidden by the Earth’s curve")
        }
        let up = sky.elevation < 1 ? "less than 1°" : "\(Int(sky.elevation.rounded()))°"
        return ("Look \(up) up, toward \(sky.compassPoint)", "Bearing \(bearing)")
    }
}

extension FlightTrack {
    /// Parses an OpenSky `/tracks` response.
    init?(data: Data, current: GeoPoint?, now: Date = Date()) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? [[Any]] else { return nil }
        self.init(waypoints: path, current: current, now: now)
    }
}

/// Recorded tracks on disk, one file per aircraft, so each flight's track is fetched only once.
enum TrackCache {
    /// A cached track is reused for at most this long (longer than any flight).
    static let lifetime: TimeInterval = 20 * 3_600
    private static var dir: URL { Shared.containerURL.appendingPathComponent("tracks", isDirectory: true) }

    static func store(_ data: Data, for id: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        prune()
    }

    /// OpenSky keys tracks by the bare 24-bit address, without readsb's "~" marker.
    static func openSkyID(_ hex: String) -> String? {
        AircraftID.hex(hex.replacingOccurrences(of: "~", with: ""), allowNonICAO: false)
    }

    /// The cached track for an aircraft by its feed hex, without fetching (see `track(for:current:now:)`).
    static func track(hex: String, current: GeoPoint?, now: Date = Date()) -> FlightTrack? {
        openSkyID(hex).flatMap { track(for: $0, current: current, now: now) }
    }

    /// The cached track for `id`, if it's recent and the aircraft could plausibly have flown from
    /// the track's end to `current` since (otherwise it's an earlier leg).
    static func track(for id: String, current: GeoPoint?, now: Date = Date()) -> FlightTrack? {
        let file = dir.appendingPathComponent("\(id).json")
        guard let fetched = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(fetched) < lifetime,
              let data = try? Data(contentsOf: file),
              let track = FlightTrack(data: data, current: nil, now: fetched),
              let end = track.points.last else { return nil }
        if let c = current, !isContinuation(from: end, to: c, now: now) { return nil }
        return track
    }

    /// Whether an aircraft at `end` could be at `current` by `now` (≤ 650 kt plus slack).
    static func isContinuation(from end: TimedPoint, to current: GeoPoint, now: Date) -> Bool {
        let hours = max(0, now.timeIntervalSince(end.time)) / 3_600
        return FlightService.gcDistance(end.point.lat, end.point.lon, current.lat, current.lon) <= hours * 650 + 60
    }

    /// Deletes cached tracks older than `lifetime`.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if -date.timeIntervalSinceNow > lifetime { try? fm.removeItem(at: f) }
        }
    }
}
