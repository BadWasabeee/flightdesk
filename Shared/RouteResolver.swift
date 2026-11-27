// One route decision for every surface: the detail view, the main window, the panel, the menu bar,
// alerts and the widget all show the route this resolver picks. Pure logic plus a no-network
// wrapper that reads the shared lookup cache and any cached recorded track.

import Foundation

/// A verdict about a callsign's route, learned from a recorded track (detail view or the radar's
/// selected aircraft) and shared through the lookup cache so the list and widget agree with the
/// detail. It records where the flight really departed; a scheduled route from another origin is
/// then known to be stale.
struct RouteCorrection: Codable, Equatable {
    /// The aircraft (lowercase hex) the verdict is about; a callsign flown by another airframe is another flight.
    var hex: String
    /// Departure airport read from the recorded track.
    var origin: Airport
    /// When it was learned.
    var at: Date

    /// Longer than any flight, short enough not to carry over to the same callsign tomorrow.
    static let lifetime: TimeInterval = 12 * 3_600

    func applies(to hex: String, now: Date = Date()) -> Bool {
        self.hex == hex.lowercased() && now.timeIntervalSince(at) < Self.lifetime
    }
}

/// The route to show for a flight and how it was worked out.
struct RouteResolution: Equatable {
    var route: RouteInfo?
    /// Diversion or return, when the scheduled route still stands.
    var situation: FlightSituation?
    /// How the route was worked out, when it isn't simply the verified scheduled route.
    var note: String?
    /// The destination is a guess from the aircraft's descent.
    var destinationEstimated = false
}

enum RouteResolver {
    /// The departure airport and time of a recorded track that starts low (near the runway).
    static func departure(of track: FlightTrack) -> (airport: Airport, time: Date)? {
        guard let start = track.points.first, (track.startAltitudeFt ?? .infinity) < 3_000,
              let airport = AirportDB.nearest(to: start.point, within: 8) else { return nil }
        return (airport, start.time)
    }

    /// Picks the route to show: the scheduled route when it fits the live position and the known
    /// departure airport (keeping it during a diversion or return), else what the departure
    /// airport and the descent imply.
    static func resolve(scheduled: RouteInfo?, flight f: Flight, departedFrom origin: Airport?) -> RouteResolution {
        if let r = scheduled, origin == nil || origin?.code == r.from.code {
            if let s = FlightSituation.path(for: f, route: r, departedFrom: origin) {
                return RouteResolution(route: r, situation: s)
            }
            if FlightService.isPlausible(r, for: f) { return RouteResolution(route: r) }
            if origin != nil { return RouteResolution(route: r, note: "Origin confirmed by the recorded track.") }
            return RouteResolution()
        }
        guard let origin else { return RouteResolution() }
        let lead = scheduled.map { "The scheduled route (\($0.from.code) → \($0.to.code)) doesn’t match the recorded track. " }
            ?? "No scheduled route. "
        if let dest = AirportDB.likelyDestination(for: f), dest.code != origin.code {
            return RouteResolution(route: RouteInfo(airline: scheduled?.airline, flightNo: scheduled?.flightNo,
                                                    airlineCode: scheduled?.airlineCode, from: origin, to: dest),
                                   note: lead + "Origin from the recorded track; destination estimated from the descent.",
                                   destinationEstimated: true)
        }
        return RouteResolution(note: lead + "Origin from the recorded track.")
    }

    /// The correction to store after a recorded track showed the flight departed `origin`, or nil
    /// when the scheduled route already agrees.
    static func correction(departedFrom origin: Airport, scheduled: RouteInfo?, hex: String, now: Date = Date()) -> RouteCorrection? {
        guard scheduled?.from.code != origin.code else { return nil }
        return RouteCorrection(hex: hex.lowercased(), origin: origin, at: now)
    }
}

extension FlightService {
    /// The route to show for `f`: `scheduled` checked against the live position, the departure
    /// airport of any cached recorded track, and any stored route correction. Never fetches.
    static func verifiedRoute(_ scheduled: RouteInfo?, for f: Flight) async -> RouteResolution {
        let departed = await departure(for: f)
        return RouteResolver.resolve(scheduled: scheduled, flight: f, departedFrom: departed)
    }

    /// Where `f` departed, from a cached recorded track or else a stored route correction. Never fetches.
    static func departure(for f: Flight) async -> Airport? {
        if let track = TrackCache.track(hex: f.id, current: f.geoPoint), let d = RouteResolver.departure(of: track) {
            return d.airport
        }
        return await LookupCache.shared.correction(callsign: f.callsign, hex: f.id)?.origin
    }

    /// Stores what a freshly loaded recorded track says about `f`'s route, so every surface uses
    /// it. Returns true when this changed the stored verdict.
    @discardableResult
    static func learnRoute(from track: FlightTrack, for f: Flight, scheduled: RouteInfo?) async -> Bool {
        guard let origin = RouteResolver.departure(of: track)?.airport,
              let c = RouteResolver.correction(departedFrom: origin, scheduled: scheduled, hex: f.id) else { return false }
        let changed = await LookupCache.shared.record(correction: c, for: f.callsign)
        if changed {
            await LookupCache.shared.save()
            NotificationCenter.default.post(name: RouteCorrection.didChange, object: nil)
        }
        return changed
    }
}

extension RouteCorrection {
    /// Posted (in-process) after a new route correction is stored.
    static let didChange = Notification.Name("FlightDeskRouteCorrectionDidChange")
}
