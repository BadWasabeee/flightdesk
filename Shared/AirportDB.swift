// Airports with scheduled service, bundled with the app, the widget and the tests.

import Foundation

/// Airports with scheduled service, bundled from OurAirports (public domain), used to name the
/// departure airport of a recorded track and to estimate where a descending aircraft is landing.
///
/// The table is parsed on first use (about 3,200 rows; codes and most city names fit in Swift's
/// inline small-string storage, so it stays well under a megabyte, which matters in the widget).
enum AirportDB {
    private final class BundleToken {}

    /// `IATA,ICAO,lat,lon,city` rows from `airports.csv`, from the bundle this code is compiled
    /// into (app, widget extension or test bundle).
    static let all: [Airport] = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "airports", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fdLog.error("airports.csv is missing from the bundle")
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            let c = line.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false)
            guard c.count == 5, let lat = Double(c[2]), let lon = Double(c[3]) else { return nil }
            return Airport(code: String(c[0]), city: String(c[4]), lat: lat, lon: lon)
        }
    }()

    /// The closest airport to `p`, if one is within `nm`.
    static func nearest(to p: GeoPoint, within nm: Double) -> Airport? {
        let latWindow = nm / 60 + 0.1
        var best: (airport: Airport, distance: Double)?
        for a in all where abs(a.lat - p.lat) <= latWindow {
            let d = FlightService.gcDistance(p.lat, p.lon, a.lat, a.lon)
            if d <= nm, d < (best?.distance ?? .infinity) { best = (a, d) }
        }
        return best?.airport
    }

    /// For an aircraft descending on approach, the nearest airport roughly ahead of it (within
    /// 80 nm and 40° of its track, or any airport within 8 nm).
    static func likelyDestination(for f: Flight) -> Airport? {
        guard f.altitude < 15_000, f.verticalRate < -300, let track = f.track else { return nil }
        var best: (airport: Airport, distance: Double)?
        for a in all where abs(a.lat - f.lat) <= 1.5 {
            let d = FlightService.gcDistance(f.lat, f.lon, a.lat, a.lon)
            guard d < 80, d < (best?.distance ?? .infinity) else { continue }
            if d < 8 || FlightService.angleBetween(track, FlightService.initialBearing(f.lat, f.lon, a.lat, a.lon)) < 40 {
                best = (a, d)
            }
        }
        return best?.airport
    }
}
