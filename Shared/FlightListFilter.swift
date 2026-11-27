// Searching, sorting and merging the main window's list of nearby aircraft.
// Pure Foundation so it can be unit tested.

import Foundation

/// Order of the main window's flight list.
enum FlightSort: String, CaseIterable, Identifiable {
    /// Nearest first.
    case distance
    /// Lowest first: the aircraft easiest to see from the ground lead.
    case altitude

    var id: String { rawValue }
    var title: String { self == .distance ? "Distance" : "Altitude" }
}

enum FlightListFilter {
    /// Whether `flight` matches every whitespace-separated word of `query`, ignoring case and
    /// diacritics. Words are looked up in the callsign, flight number, registration, ICAO type,
    /// aircraft model, airline name and code, and route airports. An empty query matches everything.
    static func matches(_ flight: Flight, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = searchableFields(of: flight)
        return words.allSatisfy { word in
            haystack.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The flights matching `query`, in `sort` order. Ties fall back to distance, then hex, so the
    /// order is stable between refreshes.
    static func apply(_ flights: [Flight], query: String, sort: FlightSort) -> [Flight] {
        flights.filter { matches($0, query: query) }.sorted { a, b in
            if sort == .altitude, a.altitude != b.altitude { return a.altitude < b.altitude }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.id < b.id
        }
    }

    /// `live` with route and aircraft details filled in from `known` (earlier lookups, by hex)
    /// where the live record has none. A known route is only reused while it still fits the
    /// aircraft's live position and heading.
    static func merging(_ live: [Flight], known: [String: Flight]) -> [Flight] {
        live.map { flight in
            guard let k = known[flight.id] else { return flight }
            var f = flight
            if f.route == nil, let route = k.route, FlightService.isPlausible(route, for: f) { f.route = route }
            if f.aircraft == nil { f.aircraft = k.aircraft }
            return f
        }
    }

    private static func searchableFields(of f: Flight) -> [String] {
        var fields = [f.callsign, f.reg, f.typeCode, f.airlineName]
        fields += [f.route?.flightNo, f.airlineCode, f.aircraft?.model, f.route?.from.code, f.route?.from.city,
                   f.route?.to.code, f.route?.to.city].compactMap { $0 }
        return fields.filter { !$0.isEmpty }
    }
}
