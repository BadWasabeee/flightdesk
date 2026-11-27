// Where Siri and Shortcuts get their flights: the same path as the widget. The location is the
// one stored in the app group (set in FlightDesk, shared with the widget), the area and filters
// come from Settings, and the list comes from `FlightService`, which reuses the shared
// `NearbyCache` while it's fresh and otherwise makes one fetch through the budgeted feeds
// (`LiveFeed` skips any service `ApiBudget` has paused). Routes and aircraft come from the
// shared `LookupCache`.

import Foundation
import AppIntents

/// Why an intent couldn't answer.
enum FlightIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLocation
    case unreachable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLocation: "No location is set. Open FlightDesk Settings and choose your location first."
        case .unreachable: "FlightDesk can’t reach flight data right now. Try again in a minute."
        }
    }
}

enum IntentFlights {
    /// The user's area: the shared location plus Settings.
    struct Area {
        var lat: Double
        var lon: Double
        var name: String
        var settings: AppSettings
        var units: UnitSystem { settings.display.units }
    }

    /// Flights near the user, nearest first, and the radius they were looked for in.
    struct Nearby {
        var flights: [Flight]
        var area: Area
        var radiusNM: Int
    }

    /// Radii the app and widgets ask for, so a request in one of them can reuse a cached list.
    static let cachedRadii = SearchRadius.allCases.map(\.nm).sorted()

    /// The stored location and current Settings, or `noLocation`.
    static func area() throws -> Area {
        guard let loc = Shared.location else { throw FlightIntentError.noLocation }
        return Area(lat: loc.lat, lon: loc.lon, name: loc.name, settings: AppSettings.load())
    }

    /// The radius to fetch for a request of `requestedNM`: the app's own radius when the request
    /// fits inside it (its list is usually cached already), else the smallest standard radius that
    /// covers it, at most the largest one.
    static func fetchRadius(requestedNM: Double?, appRadiusNM: Int) -> Int {
        guard let r = requestedNM, r > Double(appRadiusNM) else { return appRadiusNM }
        return cachedRadii.first { Double($0) >= r } ?? cachedRadii.last ?? appRadiusNM
    }

    /// Up to `limit` flights within `radiusNM` (default: the Settings radius), with routes and
    /// aircraft, nearest first. Private and GA traffic follows Settings.
    static func nearby(limit: Int, radiusNM: Double? = nil) async throws -> Nearby {
        let area = try area()
        let fetch = fetchRadius(requestedNM: radiusNM, appRadiusNM: area.settings.radius.nm)
        let limit = max(1, limit)
        let flights: [Flight]
        do {
            flights = try await FlightService.nearby(lat: area.lat, lon: area.lon, radiusNM: fetch,
                                                     includeGA: area.settings.includeGA,
                                                     limit: limit, enrich: min(limit, 10))
        } catch {
            fdLog.error("Intent fetch failed: \(error.localizedDescription)")
            throw FlightIntentError.unreachable
        }
        let within = radiusNM.map { r in flights.filter { $0.distance <= r } } ?? flights
        return Nearby(flights: within, area: area, radiusNM: radiusNM.map { Int($0.rounded(.up)) } ?? fetch)
    }

    /// Every aircraft within the Settings radius (private and GA included, without routes), nearest first.
    static func everything() async throws -> (flights: [Flight], area: Area) {
        let area = try area()
        do {
            let all = try await FlightService.allNearby(lat: area.lat, lon: area.lon, radiusNM: area.settings.radius.nm)
            return (all.sorted { $0.distance < $1.distance }, area)
        } catch {
            fdLog.error("Intent fetch failed: \(error.localizedDescription)")
            throw FlightIntentError.unreachable
        }
    }

    /// The nearby aircraft that `query` names (callsign, flight number, registration or hex), with
    /// its route and aircraft, or nil when it isn't in range.
    static func find(_ query: String) async throws -> (flight: Flight?, area: Area) {
        let (all, area) = try await everything()
        guard let match = FlightMatcher.find(query, in: all) else { return (nil, area) }
        return (await enriched(match), area)
    }

    /// The nearby aircraft with these hex addresses, with routes, in the order asked for.
    static func flights(ids: [String]) async throws -> [Flight] {
        let wanted = ids.map { $0.lowercased() }
        let all = try await everything().flights
        var out: [Flight] = []
        for id in wanted {
            if let f = all.first(where: { $0.id.lowercased() == id }) { out.append(await enriched(f)) }
        }
        return out
    }

    /// `f` with its aircraft and verified route (and any diversion), as `FlightService.nearby`
    /// adds them: from the shared lookup cache, which only fetches what it hasn't seen.
    static func enriched(_ f: Flight) async -> Flight {
        var f = f
        let scheduled = f.looksLikeAirline ? await LookupCache.shared.route(f.callsign) : nil
        let resolution = await FlightService.verifiedRoute(scheduled, for: f)
        f.aircraft = await LookupCache.shared.aircraft(f.id)
        f.route = resolution.route
        f.pathSituation = resolution.situation
        await LookupCache.shared.save()
        return f
    }
}
