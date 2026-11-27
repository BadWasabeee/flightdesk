// Unusual situations worth a label on every surface (widget, panel, main window, detail, alerts):
// emergency squawks, diversions, returns to the departure airport and holding patterns.
// Pure Foundation so the rules are unit-tested.

import Foundation

/// Something unusual about a flight, in priority order (earlier cases matter more).
enum FlightSituation: Codable, Equatable {
    /// Squawk 7500.
    case hijack
    /// Squawk 7700 (general emergency).
    case emergency(squawk: String)
    /// Squawk 7600 (lost communications).
    case radioFailure
    /// Descending toward an airport that isn't the scheduled destination.
    case diverting(to: Airport, scheduled: Airport)
    /// Descending back toward the airport it departed from.
    case returning(to: Airport)
    /// Flying a holding pattern (detail view only, from its live trail).
    case holding

    enum Severity: Equatable {
        /// Emergencies and hijack (shown in red).
        case critical
        /// Diversions, returns, radio failure and holding (shown in orange).
        case caution
    }

    // MARK: Detection thresholds

    /// Below this a descent can be an approach.
    static let approachCeilingFt = 15_000
    /// A real descent, not altitude-hold noise.
    static let descentFPM = -500.0
    /// A flight this close to its scheduled destination is arriving, whatever it's doing.
    static let arrivalRadiusNM = 80.0
    /// A return is only claimed this close to the departure airport.
    static let returnRadiusNM = 120.0
    /// "Heading toward" an airport: within this many degrees of the bearing to it.
    static let towardDegrees = 40.0

    // MARK: Detection

    /// The situation a transponder code declares, if any.
    static func squawk(_ code: String?) -> FlightSituation? {
        switch code?.trimmingCharacters(in: .whitespaces) {
        case "7500": .hijack
        case "7700": .emergency(squawk: "7700")
        case "7600": .radioFailure
        default: nil
        }
    }

    /// A diversion or return worked out from the live position and the scheduled `route`.
    ///
    /// - `departedFrom`: the departure airport from a recorded track (or a stored route
    ///   correction), when known. A return is only claimed when it confirms the scheduled
    ///   origin: without it, "descending toward the origin" is far more often a stale schedule for
    ///   the opposite leg than a real return. Callers must not pass a route the recorded track
    ///   contradicts (see `RouteResolver`).
    /// - Returns nil for normal climbs, cruise and arrivals at the scheduled destination.
    static func path(for f: Flight, route r: RouteInfo, departedFrom: Airport? = nil) -> FlightSituation? {
        guard f.altitude < approachCeilingFt, f.verticalRate < descentFPM, let track = f.track,
              r.from.code != r.to.code else { return nil }
        let toOrigin = FlightService.gcDistance(f.lat, f.lon, r.from.lat, r.from.lon)
        let toDest = FlightService.gcDistance(f.lat, f.lon, r.to.lat, r.to.lon)
        func heading(to a: Airport, distance: Double) -> Bool {
            distance < 8 || FlightService.angleBetween(track, FlightService.initialBearing(f.lat, f.lon, a.lat, a.lon)) < towardDegrees
        }
        let towardDest = heading(to: r.to, distance: toDest)

        // Returning: back toward a confirmed departure airport, unless the destination is nearer along the same heading.
        if departedFrom?.code == r.from.code, toOrigin <= returnRadiusNM, toDest > 40,
           heading(to: r.from, distance: toOrigin), !(towardDest && toDest < toOrigin) {
            return .returning(to: r.from)
        }

        // Diverting: approaching another airport, well away from the destination, from somewhere
        // along the scheduled route (a schedule for a different leg puts the aircraft off its path).
        guard toDest > arrivalRadiusNM, let landing = AirportDB.likelyDestination(for: f),
              landing.code != r.to.code, landing.code != r.from.code else { return nil }
        let total = FlightService.gcDistance(r.from.lat, r.from.lon, r.to.lat, r.to.lon)
        guard toOrigin + toDest - total < max(80, total * 0.15) else { return nil }
        // An airport that's merely on the way to the destination (a step-down descent) isn't a
        // diversion; it is once the aircraft has turned off its course or is landing there.
        let toLanding = FlightService.gcDistance(f.lat, f.lon, landing.lat, landing.lon)
        guard !towardDest || (toLanding < 15 && f.altitude < 5_000) else { return nil }
        return .diverting(to: landing, scheduled: r.to)
    }

    /// Whether a live trail shows a holding pattern: the track turning through at least 300° in
    /// one direction within the last 8 minutes.
    static func isHolding(trail: [TimedPoint], now: Date = Date()) -> Bool {
        let recent = trail.filter { now.timeIntervalSince($0.time) <= 8 * 60 }
        guard recent.count >= 5 else { return false }
        // Bearings of legs long enough (≥ 0.3 nm) for the direction to be meaningful.
        var bearings: [Double] = []
        var anchor = recent[0].point
        for p in recent.dropFirst() where FlightService.gcDistance(anchor.lat, anchor.lon, p.point.lat, p.point.lon) >= 0.3 {
            bearings.append(FlightService.initialBearing(anchor.lat, anchor.lon, p.point.lat, p.point.lon))
            anchor = p.point
        }
        guard bearings.count >= 4 else { return false }
        var turn = 0.0
        for (a, b) in zip(bearings, bearings.dropFirst()) {
            turn += (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
        }
        return abs(turn) >= 300
    }

    // MARK: Presentation

    var severity: Severity {
        switch self {
        case .hijack, .emergency: .critical
        case .radioFailure, .diverting, .returning, .holding: .caution
        }
    }

    /// SF Symbol for the label.
    var symbol: String {
        switch self {
        case .hijack: "exclamationmark.octagon.fill"
        case .emergency: "exclamationmark.triangle.fill"
        case .radioFailure: "antenna.radiowaves.left.and.right.slash"
        case .diverting: "arrow.triangle.turn.up.right.diamond.fill"
        case .returning: "arrow.uturn.backward"
        case .holding: "arrow.triangle.2.circlepath"
        }
    }

    /// Label text: "Emergency · 7700", "Diverting to MKE".
    var title: String {
        switch self {
        case .hijack: "Hijack · 7500"
        case .emergency(let code): "Emergency · \(code)"
        case .radioFailure: "Radio failure · 7600"
        case .diverting(let to, _): "Diverting to \(to.code)"
        case .returning(let to): "Returning to \(to.code)"
        case .holding: "Holding"
        }
    }

    /// Short board tag: "EMERGENCY", "DIVERT MKE".
    var tag: String {
        switch self {
        case .hijack: "HIJACK"
        case .emergency: "EMERGENCY"
        case .radioFailure: "RADIO FAIL"
        case .diverting(let to, _): "DIVERT \(to.code)"
        case .returning(let to): "RETURN \(to.code)"
        case .holding: "HOLDING"
        }
    }

    /// What the situation means, without a squawk code (spotter alert headlines).
    var headline: String {
        switch self {
        case .hijack: "Hijack"
        case .emergency: "Emergency"
        case .radioFailure: "Radio failure"
        case .diverting(let to, _): "Diverting to \(Self.spokenName(to))"
        case .returning(let to): "Returning to \(Self.spokenName(to))"
        case .holding: "Holding"
        }
    }

    /// VoiceOver text: "Emergency, squawking 7700", "Diverting to Milwaukee (MKE) instead of Denver (DEN)".
    var spoken: String {
        switch self {
        case .hijack: "Hijack, squawking 7500"
        case .emergency(let code): "Emergency, squawking \(code)"
        case .radioFailure: "Radio failure, squawking 7600"
        case .diverting(let to, let scheduled): "Diverting to \(Self.spokenName(to)) instead of \(Self.spokenName(scheduled))"
        case .returning(let to): "Returning to \(Self.spokenName(to))"
        case .holding: "Holding"
        }
    }

    /// Where the flight is now heading instead of its scheduled destination, if that changed.
    var newDestination: Airport? {
        switch self {
        case .diverting(let to, _), .returning(let to): to
        default: nil
        }
    }

    private static func spokenName(_ a: Airport) -> String { a.city.isEmpty ? a.code : "\(a.city) (\(a.code))" }
}

extension Flight {
    /// The most important unusual situation: an emergency squawk, else a diversion or return.
    var situation: FlightSituation? { FlightSituation.squawk(squawk) ?? pathSituation }

    /// Where the aircraft is actually going: the diversion or return airport, else the route's destination.
    var destination: Airport? { pathSituation?.newDestination ?? route?.to }
}
