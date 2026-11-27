// Text for the iPhone Lock Screen widgets, which only have room for a few characters: the nearest
// flight's distance and altitude, its number and route. Pure Foundation so it can be unit tested.

import Foundation

enum NearestFlightText {
    /// The closest aircraft, or nil when there are none.
    static func nearest(_ flights: [Flight]) -> Flight? { flights.min { $0.distance < $1.distance } }

    /// "4.2" (nautical miles or kilometres); whole numbers from 10 up so it fits a small circle.
    static func distanceValue(_ nm: Double, units: UnitSystem) -> String {
        let v = units == .metric ? nm * 1.852 : nm
        return v < 9.95 ? String(format: "%.1f", v) : String(Int(v.rounded()))
    }

    static func distanceUnit(_ units: UnitSystem) -> String { units == .metric ? "km" : "nm" }

    /// "12k ft", "8.5k ft", "850 ft" / "3.7k m", "900 m"; "GND" on the ground.
    static func shortAltitude(_ ft: Int, units: UnitSystem) -> String {
        guard ft > 0 else { return "GND" }
        let v = units == .metric ? Double(ft) * 0.3048 : Double(ft)
        let unit = units == .metric ? "m" : "ft"
        if v < 1000 { return "\(Int((v / 10).rounded()) * 10) \(unit)" }
        let k = v / 1000
        return k < 9.95 ? String(format: "%.1fk %@", k, unit) : "\(Int(k.rounded()))k \(unit)"
    }

    /// "MKE → ORD" (or the diversion airport), nil when the route is unknown.
    static func route(_ f: Flight) -> String? {
        guard let r = f.route, let to = f.destination, !r.from.code.isEmpty, !to.code.isEmpty else { return nil }
        return "\(r.from.code) → \(to.code)"
    }

    /// The rectangular widget's second line: the route, else who operates it, else the type.
    static func detail(_ f: Flight) -> String {
        if let s = f.situation { return s.tag }
        if let r = route(f) { return r }
        if !f.airlineName.isEmpty { return f.airlineName }
        return f.typeCode.isEmpty ? f.reg : f.typeCode
    }

    /// "4.2 nm NE · 12k ft".
    static func position(_ f: Flight, units: UnitSystem) -> String {
        "\(distanceValue(f.distance, units: units)) \(distanceUnit(units)) \(f.direction) · \(shortAltitude(f.altitude, units: units))"
    }

    /// The inline widget beside the clock: "DL1342 MKE→ORD 4.2 nm".
    static func inline(_ f: Flight, units: UnitSystem) -> String {
        let route = route(f).map { $0.replacingOccurrences(of: " → ", with: "→") }
        return [f.displayNumber, route, "\(distanceValue(f.distance, units: units)) \(distanceUnit(units))"]
            .compactMap { $0 }.joined(separator: " ")
    }
}
