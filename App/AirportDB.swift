import Foundation

/// Airports with scheduled service, bundled from OurAirports (public domain), used to name the
/// departure airport of a recorded track and to estimate where a descending aircraft is landing.
enum AirportDB {
    /// `IATA,ICAO,lat,lon,city` rows from `airports.csv`.
    static let all: [Airport] = {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let c = line.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false)
            guard c.count == 5, let lat = Double(c[2]), let lon = Double(c[3]) else { return nil }
            return Airport(code: String(c[0]), city: String(c[4]), lat: lat, lon: lon)
        }
    }()

    /// The closest airport to `p`, if one is within `nm`.
    static func nearest(to p: GeoPoint, within nm: Double) -> Airport? {
        all.lazy
            .map { ($0, FlightService.gcDistance(p.lat, p.lon, $0.lat, $0.lon)) }
            .filter { $0.1 <= nm }
            .min { $0.1 < $1.1 }?.0
    }

    /// For an aircraft descending on approach, the nearest airport roughly ahead of it.
    static func likelyDestination(for f: Flight) -> Airport? {
        guard f.altitude < 15_000, f.verticalRate < -300, let track = f.track else { return nil }
        var best: (airport: Airport, distance: Double)?
        for a in all {
            let d = FlightService.gcDistance(f.lat, f.lon, a.lat, a.lon)
            guard d < 80, d < (best?.distance ?? .infinity) else { continue }
            let bearing = FlightService.initialBearing(f.lat, f.lon, a.lat, a.lon)
            let off: Double = abs((bearing - track + 540).truncatingRemainder(dividingBy: 360) - 180)
            if d < 8 || off < 40 { best = (a, d) }
        }
        return best?.airport
    }
}
