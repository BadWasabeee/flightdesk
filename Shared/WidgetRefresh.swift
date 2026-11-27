// Lets the app keep desktop widgets fresh without reloading them on every tick: widgets record
// which areas they show, the app re-checks those areas at the user's interval, and reloads the
// widgets only when the aircraft they would show have changed meaningfully.

import Foundation

/// An area a widget shows: position (rounded like every feed request), radius and GA filter.
struct WidgetArea: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    var radiusNM: Int
    var includeGA: Bool

    init(lat: Double, lon: Double, radiusNM: Int, includeGA: Bool) {
        self.lat = (lat * 100).rounded() / 100
        self.lon = (lon * 100).rounded() / 100
        self.radiusNM = radiusNM
        self.includeGA = includeGA
    }

    var id: String { String(format: "%.2f,%.2f,%d,%d", lat, lon, radiusNM, includeGA ? 1 : 0) }
    var observer: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

/// Areas recently drawn by widgets, written by the widget extension and read by the app.
enum WidgetDemand {
    private struct Stamped: Codable { var area: WidgetArea; var at: Date }

    static let key = "widget.areas.v1"
    /// An area no widget has drawn for this long is dropped (timelines reload at least every 5 min).
    static let lifetime: TimeInterval = 20 * 60
    static let maxAreas = 6
    private static let lock = NSLock()

    private static func load(_ defaults: UserDefaults) -> [String: Stamped] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Stamped].self, from: $0) } ?? [:]
    }

    /// Notes that a widget is showing `area` (called from the widget's timeline).
    static func record(_ area: WidgetArea, now: Date = Date(), defaults: UserDefaults = Shared.defaults) {
        lock.lock(); defer { lock.unlock() }
        var all = load(defaults).filter { now.timeIntervalSince($0.value.at) < lifetime }
        all[area.id] = Stamped(area: area, at: now)
        if all.count > maxAreas {
            all = Dictionary(uniqueKeysWithValues: all.sorted { $0.value.at > $1.value.at }.prefix(maxAreas).map { ($0.key, $0.value) })
        }
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
    }

    /// Areas widgets have shown recently.
    static func current(now: Date = Date(), defaults: UserDefaults = Shared.defaults) -> [WidgetArea] {
        lock.lock(); defer { lock.unlock() }
        return load(defaults).values.filter { now.timeIntervalSince($0.at) < lifetime }.map(\.area).sorted { $0.id < $1.id }
    }

    /// Forgets every area (after a location change; widgets re-record on their next timeline).
    static func clear(defaults: UserDefaults = Shared.defaults) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}

/// Decides whether fresh data is worth a widget reload.
enum WidgetRefresh {
    /// Flights a widget lists (matches `FlightService.nearby`'s default limit).
    static let maxShown = 12
    /// The widget timeline covers 5 minutes; reload at least this often while the app runs.
    static let maxAge: TimeInterval = 300
    /// A dead-reckoned position this far from the live one is visibly wrong.
    static let positionToleranceNM = 0.5
    static let altitudeToleranceFt = 500

    /// What a widget would list from every aircraft in range: nearest first, GA filtered.
    static func shown(_ all: [Flight], includeGA: Bool) -> [Flight] {
        Array(all.filter { includeGA || $0.looksLikeAirline }.sorted { $0.distance < $1.distance }.prefix(maxShown))
    }

    /// Whether `fresh` differs enough from what a widget drew from `drawn` (fetched at `drawnAt`)
    /// and has dead-reckoned since: different aircraft, a different featured set, a new callsign
    /// or squawk, or a position or altitude the projection got wrong.
    static func isMeaningfulChange(drawn: [Flight], drawnAt: Date, fresh: [Flight], now: Date, observer: GeoPoint) -> Bool {
        if now.timeIntervalSince(drawnAt) >= maxAge { return true }
        guard Set(drawn.map(\.id)) == Set(fresh.map(\.id)),
              Set(drawn.prefix(5).map(\.id)) == Set(fresh.prefix(5).map(\.id)) else { return true }
        let byID = Dictionary(drawn.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let elapsed = now.timeIntervalSince(drawnAt)
        for f in fresh {
            guard let old = byID[f.id] else { return true }
            if old.squawk != f.squawk || old.callsign != f.callsign { return true }
            let p = old.projected(by: elapsed, observerLat: observer.lat, observerLon: observer.lon)
            if FlightService.gcDistance(p.lat, p.lon, f.lat, f.lon) > positionToleranceNM { return true }
            if abs(p.altitude - f.altitude) > altitudeToleranceFt { return true }
        }
        return false
    }
}
