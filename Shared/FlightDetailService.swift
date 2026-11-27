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
    static func report(hex: String) async throws -> AircraftReport? {
        let observer = Shared.location.map { GeoPoint(lat: $0.lat, lon: $0.lon) }
        let receiver = ReceiverSettings.current
        return try await ReceiverFeed.route(receiver, local: {
            try await ReceiverFeed.report(hex: hex, observer: observer, settings: receiver)
        }, internet: {
            let data = try await LiveFeed.fetch { $0.hexURL(hex) }
            let records = try JSONDecoder().decode(DetailResponse.self, from: data).ac ?? []
            return records.lazy.compactMap { AircraftReport(record: $0, observer: observer) }.first
        })
    }

    /// The aircraft's track for its current flight from the OpenSky Network (anonymous, rate-limited).
    /// Nil when unavailable, or when the track doesn't end near `current` (e.g. an earlier leg).
    static func track(hex: String, current: GeoPoint?) async -> FlightTrack? {
        let id = hex.lowercased().replacingOccurrences(of: "~", with: "")
        guard id.count == 6, let url = URL(string: "https://opensky-network.org/api/tracks/all?icao24=\(id)&time=0"),
              let (data, resp) = try? await FlightService.session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? [[Any]] else { return nil }
        return FlightTrack(waypoints: path, current: current)
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
