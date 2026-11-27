// A nearby flight as Shortcuts and Siri see it.

import Foundation
import AppIntents

/// An aircraft FlightDesk can currently see, identified by its ICAO hex address.
struct FlightEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Flight"
    static let defaultQuery = FlightQuery()

    /// Lowercase ICAO 24-bit hex address.
    let id: String

    @Property(title: "Callsign") var callsign: String
    @Property(title: "Flight Number") var flightNumber: String?
    @Property(title: "Airline") var airline: String?
    @Property(title: "Registration") var registration: String
    @Property(title: "Aircraft Type") var type: String
    @Property(title: "Type Code") var typeCode: String
    @Property(title: "Origin") var origin: String?
    @Property(title: "Destination") var destination: String?
    @Property(title: "Altitude") var altitude: Measurement<UnitLength>
    @Property(title: "Ground Speed") var speed: Measurement<UnitSpeed>
    @Property(title: "Distance") var distance: Measurement<UnitLength>
    /// Degrees true from the user to the aircraft.
    @Property(title: "Bearing") var bearing: Double
    @Property(title: "Direction") var direction: String
    @Property(title: "Vertical Trend") var trend: String
    @Property(title: "Situation") var situation: String?
    @Property(title: "Summary") var summary: String
    @Property(title: "FlightDesk Link") var link: URL?

    /// "UA1543", the boards' flight label.
    let title: String
    /// "Boeing 737 · ORD → DEN · 4.0 nm N · 7,300 ft", in the user's units.
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)",
                              image: .init(systemName: AircraftClass(typeCode: typeCode).symbol))
    }

    init(flight f: Flight, units: UnitSystem, locale: Locale = .current) {
        var display = DisplayOptions().withStandardStyle
        display.units = units
        // Plain stored properties first: the @Property setters need a fully initialized self.
        id = f.id.lowercased()
        title = f.displayNumber
        var parts: [String] = []
        let model = f.aircraft?.model.map(FlightSpeech.simplifiedModel) ?? f.typeCode
        if !model.isEmpty { parts.append(model) }
        if let r = f.route, let to = f.destination { parts.append("\(r.from.code) → \(to.code)") }
        if let s = f.situation { parts.append(s.title) }
        parts.append("\(display.distance(f.distance)) \(f.direction)")
        parts.append(display.altitude(f.altitude))
        subtitle = parts.joined(separator: " · ")
        callsign = f.callsign
        flightNumber = f.route?.flightNo
        // The scheduled operator only: for private aircraft `airlineName` falls back to the
        // registered owner, which isn't an airline.
        airline = f.route?.airline
        registration = f.reg
        type = f.aircraft?.model ?? f.typeCode
        typeCode = f.typeCode
        origin = f.route.map { Self.place($0.from) }
        destination = f.destination.map(Self.place)
        altitude = Measurement(value: Double(f.altitude), unit: .feet)
        speed = Measurement(value: f.speed, unit: .knots)
        distance = Measurement(value: f.distance, unit: .nauticalMiles)
        bearing = f.bearing.rounded()
        direction = FlightSpeech.compassWord(f.direction)
        trend = FlightSpeech.verticalPhrase(of: f) ?? "level"
        situation = f.situation?.title
        summary = FlightSpeech.summary(of: f, units: units, locale: locale)
        link = FlightLink.url(for: f.id)
    }

    /// "Chicago (ORD)", or the code alone when the city isn't known.
    static func place(_ a: Airport) -> String { a.city.isEmpty ? a.code : "\(a.city) (\(a.code))" }

    /// Entities for `flights` in the units chosen in Settings.
    static func from(_ flights: [Flight], units: UnitSystem = AppSettings.load().display.units) -> [FlightEntity] {
        flights.map { FlightEntity(flight: $0, units: units) }
    }
}

/// Resolves flights by hex address from what FlightDesk can currently see, and searches them by
/// callsign, flight number, registration or hex.
struct FlightQuery: EntityStringQuery {
    func entities(for identifiers: [FlightEntity.ID]) async throws -> [FlightEntity] {
        FlightEntity.from(try await IntentFlights.flights(ids: identifiers))
    }

    func entities(matching string: String) async throws -> [FlightEntity] {
        let (all, area) = try await IntentFlights.everything()
        var found = FlightMatcher.search(string, in: all).prefix(10).map { $0 }
        // Routes for the first few, so the picker reads like the boards.
        for i in found.indices.prefix(5) { found[i] = await IntentFlights.enriched(found[i]) }
        return FlightEntity.from(found, units: area.units)
    }

    func suggestedEntities() async throws -> [FlightEntity] {
        let nearby = try await IntentFlights.nearby(limit: 10)
        return FlightEntity.from(nearby.flights, units: nearby.area.units)
    }
}
