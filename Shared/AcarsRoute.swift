// The route ahead of an aircraft, decoded from its own ACARS messages: FMS wind-data requests
// and flight plans (the whole remaining route) and position reports (position, next and following
// fix). Names are placed with `NavDB`; everything here is pure and unit-tested.

import Foundation

// MARK: - Parsing

/// A route point as written in a message: a fix or navaid ident, or a coordinate, with the
/// position when the message gives one.
struct RouteToken: Equatable, Sendable {
    /// The ident or coordinate as sent ("SLATN", "N40W050").
    let name: String
    /// The position the message gives (a coordinate, or a fix sent with its coordinates).
    let point: GeoPoint?
    /// The name is itself a coordinate.
    let isCoordinate: Bool

    /// The ident, or the coordinate written for reading (see `RouteWaypoint.label`).
    var label: String { RouteWaypoint(name: name, point: point, isCoordinate: isCoordinate).label }
}

/// What one message says about the route.
struct AcarsRouteReport: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `REQPWI`: the FMS asks for winds along the rest of its route, to the destination.
        case windRequest
        /// `FPN`: a flight plan, to the destination.
        case flightPlan
        /// `POS`: the aircraft's position and its next two waypoints.
        case position
    }

    var kind: Kind
    /// When the message was sent.
    var time: Date
    /// Waypoints still to fly, in order.
    var waypoints: [RouteToken]
    /// Where the aircraft was and when (position reports).
    var position: TimedPoint?

    /// The waypoints run to the end of the route, so they replace whatever an older message said lay beyond.
    var reachesDestination: Bool { kind != .position }
}

/// Reads route information from ARINC 702A FMS messages (ACARS label H1, after `AcarsDecoder.core`).
/// Messages end with a four-character check sequence, and a receiver may miss later blocks, so a
/// list that runs to the end of the text loses its last element.
enum AcarsRouteParser {
    /// The route information in `core`, or nil when it carries none.
    static func report(in core: String, sent: Date) -> AcarsRouteReport? {
        if core.hasPrefix("REQPWI") { return windRequest(core, sent: sent) }
        if core.hasPrefix("FPN") { return flightPlan(core, sent: sent) }
        if core.hasPrefix("POS") { return positionReport(core, sent: sent) }
        return nil
    }

    /// `REQPWI/…/WQ370.380:N39539W071575.SLATN.N40W050.…/DQ…`: the climb/cruise route after
    /// `WQ<levels>:`, up to the destination runway (`RW09L`) when it's listed.
    static func windRequest(_ core: String, sent: Date) -> AcarsRouteReport? {
        guard let start = core.range(of: "/WQ") else { return nil }
        let rest = core[start.upperBound...]
        guard let colon = rest.firstIndex(of: ":"), rest[..<colon].allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let body = rest[rest.index(after: colon)...]
        let end = body.firstIndex(of: "/")
        let waypoints = tokens(body[..<(end ?? body.endIndex)], runsToEnd: end == nil)
        guard !waypoints.isEmpty else { return nil }
        return AcarsRouteReport(kind: .windRequest, time: sent, waypoints: waypoints, position: nil)
    }

    /// `FPN/…/RP:DA:CYYC:AA:CYHZ:F:LOMLO,N51042W113232.Q961.DAPOP..SEFFY…` or
    /// `FPN/…/RP..SANEG,S27491E153026.H91.ADMAR…:DA:YBBN:AA:YMLT`: the route after `F:`, or
    /// straight after `RP`/`RI`. Airways between fixes are skipped, leaving the fixes at their ends.
    static func flightPlan(_ core: String, sent: Date) -> AcarsRouteReport? {
        guard let section = core.split(separator: "/").first(where: { $0.hasPrefix("RP") || $0.hasPrefix("RI") }) else { return nil }
        let parts = section.split(separator: ":", omittingEmptySubsequences: false)
        let index: Int
        if parts[0].count > 2 {
            index = 0
        } else if let f = parts.firstIndex(of: "F"), f + 1 < parts.count {
            index = f + 1
        } else {
            return nil
        }
        let route = index == 0 ? parts[0].dropFirst(2) : parts[index]
        let waypoints = tokens(route, runsToEnd: index == parts.count - 1 && section.endIndex == core.endIndex)
        guard !waypoints.isEmpty else { return nil }
        return AcarsRouteReport(kind: .flightPlan, time: sent, waypoints: waypoints, position: nil)
    }

    /// `POSN42285W087484,BRTMN,035113,174,TAAYZ,035331,PETTY,M15,…`: position, fix passed,
    /// report time (hhmmss UTC), flight level, next fix and its ETA, then the fix after. Fixes may
    /// also be coordinates.
    static func positionReport(_ core: String, sent: Date) -> AcarsRouteReport? {
        let f = core.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count > 3, f[0].hasPrefix("POS"), let p = packed(f[0].dropFirst(3)) else { return nil }
        let time = utcTime(f[2], near: sent) ?? sent
        let waypoints = [4, 6].compactMap { $0 < f.count - 1 ? token(f[$0].trimmingCharacters(in: .whitespaces)[...]) : nil }
        return AcarsRouteReport(kind: .position, time: sent, waypoints: waypoints, position: TimedPoint(point: p, time: time))
    }

    /// The waypoints of a "."-separated route (".." is a direct leg), ending before a runway.
    private static func tokens(_ route: Substring, runsToEnd: Bool) -> [RouteToken] {
        var elements = route.split(separator: ".")
        if runsToEnd, !elements.isEmpty { elements.removeLast() }
        if let rw = elements.firstIndex(where: isRunway) { elements.removeSubrange(rw...) }
        return elements.compactMap(token)
    }

    /// `RW09L`.
    private static func isRunway(_ s: Substring) -> Bool {
        let c = Array(s.utf8)
        return (4...5).contains(c.count) && s.hasPrefix("RW") && (48...57).contains(c[2]) && (48...57).contains(c[3])
    }

    /// A route element: an ident (2–5 letters) or a coordinate, either optionally followed by
    /// its coordinates (`SEFFY,N51234W107083`). Airways, procedures and the like are nil.
    static func token(_ s: Substring) -> RouteToken? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        let name = parts[0]
        let given: GeoPoint?
        switch parts.count {
        case 1: given = nil
        case 2:
            guard let p = packed(parts[1]) else { return nil }
            given = p
        default: return nil
        }
        if let p = coordinate(name) { return RouteToken(name: String(name), point: given ?? p, isCoordinate: true) }
        guard (2...5).contains(name.count), name.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        return RouteToken(name: String(name), point: given, isCoordinate: false)
    }

    /// A coordinate waypoint in one of the forms FMS messages use:
    /// - whole degrees, `N40W050`;
    /// - degrees and minutes to a tenth, `N39539W071575` (39°53.9′ N, 71°57.5′ W);
    /// - ARINC 424 five-character names: `4050N` is 40° N 50° W, with the letter giving the
    ///   quadrant (N = north/west, E = north/east, S = south/east, W = south/west) and, when it
    ///   comes third (`40N50`), adding 100° to the longitude (40° N 150° W).
    static func coordinate(_ s: Substring) -> GeoPoint? {
        let c = Array(s.utf8)
        func digits(_ r: Range<Int>) -> Int? {
            guard r.upperBound <= c.count, r.allSatisfy({ (48...57).contains(c[$0]) }) else { return nil }
            return r.reduce(0) { $0 * 10 + Int(c[$1] - 48) }
        }
        func sign(_ ch: UInt8, _ positive: Character, _ negative: Character) -> Double? {
            ch == positive.asciiValue ? 1 : ch == negative.asciiValue ? -1 : nil
        }
        switch c.count {
        case 7:
            guard let ns = sign(c[0], "N", "S"), let ew = sign(c[3], "E", "W"),
                  let lat = digits(1..<3), let lon = digits(4..<7) else { return nil }
            return valid(ns * Double(lat), ew * Double(lon))
        case 13:
            return packed(s)
        case 5:
            let quadrant: UInt8, lat: Int, lon: Int
            if let d = digits(0..<4) {
                (quadrant, lat, lon) = (c[4], d / 100, d % 100)
            } else if let a = digits(0..<2), let b = digits(3..<5) {
                (quadrant, lat, lon) = (c[2], a, 100 + b)
            } else {
                return nil
            }
            switch Character(UnicodeScalar(quadrant)) {
            case "N": return valid(Double(lat), -Double(lon))
            case "E": return valid(Double(lat), Double(lon))
            case "S": return valid(-Double(lat), Double(lon))
            case "W": return valid(-Double(lat), -Double(lon))
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `N42285W087484`: degrees and minutes to a tenth, as FMS position reports send it.
    static func packed(_ s: Substring) -> GeoPoint? {
        let c = Array(s.utf8)
        guard c.count == 13, let ns: Double = c[0] == 78 ? 1 : c[0] == 83 ? -1 : nil,
              let ew: Double = c[6] == 69 ? 1 : c[6] == 87 ? -1 : nil else { return nil }
        func number(_ r: Range<Int>) -> Double? {
            r.allSatisfy({ (48...57).contains(c[$0]) }) ? Double(r.reduce(0) { $0 * 10 + Int(c[$1] - 48) }) : nil
        }
        guard let latD = number(1..<3), let latM = number(3..<6), let lonD = number(7..<10), let lonM = number(10..<13),
              latM < 600, lonM < 600 else { return nil }
        return valid(ns * (latD + latM / 600), ew * (lonD + lonM / 600))
    }

    private static func valid(_ lat: Double, _ lon: Double) -> GeoPoint? {
        abs(lat) <= 90 && abs(lon) <= 180 ? GeoPoint(lat: lat, lon: lon) : nil
    }

    /// `hhmmss` (UTC) as the moment at or shortly before `sent` (allowing ten minutes of clock skew).
    static func utcTime(_ s: Substring, near sent: Date) -> Date? {
        guard s.count == 6, let n = Int(s), n / 10_000 < 24, n / 100 % 100 < 60, n % 100 < 60 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard var t = utc.date(bySettingHour: n / 10_000, minute: n / 100 % 100, second: n % 100, of: sent) else { return nil }
        if t.timeIntervalSince(sent) > 600 { t.addTimeInterval(-86_400) }
        return sent.timeIntervalSince(t) < 3_600 ? t : nil
    }
}

// MARK: - Decoded route

/// A waypoint of a decoded route.
struct RouteWaypoint: Equatable, Sendable {
    /// The ident or coordinate as sent.
    let name: String
    /// Where it is; nil when the name isn't in the navigation data (or no candidate fits the route).
    let point: GeoPoint?
    let isCoordinate: Bool

    /// For the map: the ident, or a coordinate as "40N 50W" (whole degrees) or "39.9N 72.0W".
    var label: String {
        guard isCoordinate, let p = point else { return name }
        func part(_ v: Double, _ pos: String, _ neg: String) -> String {
            let a = abs(v)
            return (a.rounded() == a ? String(Int(a)) : String(format: "%.1f", a)) + (v < 0 ? neg : pos)
        }
        return "\(part(p.lat, "N", "S")) \(part(p.lon, "E", "W"))"
    }
}

/// The route an aircraft reported over ACARS, merged from its messages.
struct AcarsRoute: Equatable, Sendable {
    /// In flying order; names that couldn't be placed keep their place with no point.
    var waypoints: [RouteWaypoint]
    /// Positions from position reports, oldest first.
    var positions: [TimedPoint]
    /// When the newest message used was sent.
    var updated: Date

    var resolvedCount: Int { waypoints.lazy.filter { $0.point != nil }.count }
}

/// Where a route is expected to go, for choosing between same-named fixes.
struct AcarsRouteContext: Equatable, Sendable {
    var origin: GeoPoint?
    var destination: GeoPoint?
    /// The aircraft's known positions, oldest first.
    var track: [TimedPoint] = []

    /// Where the aircraft was within ten minutes of `time`, if known.
    func position(at time: Date) -> GeoPoint? {
        let near = track.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
        guard let near, abs(near.time.timeIntervalSince(time)) <= 600 else { return nil }
        return near.point
    }
}

/// Places route names with a `NavDB` and merges successive messages into one route.
enum AcarsRouteResolver {
    /// Candidates farther than this from the origin–destination great circle are rejected.
    static let corridorNM: Double = 600
    /// The longest plausible leg between consecutive waypoints (oceanic legs are 10° of longitude).
    static let maxLegNM: Double = 1_200
    /// A message whose route passes farther than this from the older route doesn't continue it.
    static let joinNM: Double = 250

    /// The route from `reports` (any order): each message's waypoints are placed, then merged
    /// oldest first, a newer message replacing the older route from where it starts. Nil when no
    /// message names a waypoint or position.
    static func route(from reports: [AcarsRouteReport], context: AcarsRouteContext, navDB: NavDB) -> AcarsRoute? {
        let sorted = reports.sorted { $0.time < $1.time }
        guard let newest = sorted.last else { return nil }
        var route: [RouteWaypoint] = []
        for r in sorted where !r.waypoints.isEmpty {
            let start = r.position?.point ?? context.position(at: r.time)
            let placed = resolve(r.waypoints, from: start, context: context, navDB: navDB)
            route = merge(route, with: placed, from: r.position?.point, reachesDestination: r.reachesDestination)
        }
        var positions: [TimedPoint] = []
        for p in sorted.compactMap(\.position) where p.time > (positions.last?.time ?? .distantPast) { positions.append(p) }
        guard !route.isEmpty || !positions.isEmpty else { return nil }
        return AcarsRoute(waypoints: route, positions: positions, updated: newest.time)
    }

    /// Places each token: coordinates as written; names at the candidate that fits the route best.
    /// A candidate must lie within `corridorNM` of the origin–destination great circle (when both
    /// are known) and within `maxLegNM` per leg of the previous placed point; among those, the
    /// one with the shortest detour from the previous point to the next unambiguous one wins.
    static func resolve(_ tokens: [RouteToken], from start: GeoPoint?, context: AcarsRouteContext, navDB: NavDB) -> [RouteWaypoint] {
        func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double { FlightService.gcDistance(a.lat, a.lon, b.lat, b.lon) }
        let candidates: [[GeoPoint]] = tokens.map { t in
            if let p = t.point { return [p] }
            let all = navDB.candidates(for: t.name).map(\.point)
            guard let o = context.origin, let d = context.destination else { return all }
            return all.filter { RouteGeometry.nearest(on: o, d, to: $0).distance <= corridorNM }
        }
        var out: [RouteWaypoint] = []
        var previous: (point: GeoPoint, index: Int)? = start.map { ($0, -1) }
        for (i, t) in tokens.enumerated() {
            let next = candidates[(i + 1)...].first { $0.count == 1 }?.first
            func detour(_ c: GeoPoint) -> Double {
                (previous.map { distance($0.point, c) } ?? 0) + (next.map { distance(c, $0) } ?? 0)
            }
            let fits = candidates[i].filter { c in
                guard t.point == nil, let previous else { return true }
                return distance(previous.point, c) <= maxLegNM * Double(i - previous.index)
            }
            let point = fits.min { detour($0) < detour($1) }
            if let point { previous = (point, i) }
            out.append(RouteWaypoint(name: t.name, point: point, isCoordinate: t.isCoordinate))
        }
        return out
    }

    /// `newer` replaces `older` from where it joins it: at its first waypoint's name, else where
    /// its start (the reporting position, or its first placed waypoint) projects onto the older
    /// route. A route that runs to the destination drops the rest of the older one; a partial
    /// one (a position report's next two fixes) rejoins it after its last waypoint.
    static func merge(_ older: [RouteWaypoint], with newer: [RouteWaypoint], from position: GeoPoint?,
                      reachesDestination: Bool) -> [RouteWaypoint] {
        guard !older.isEmpty else { return newer }
        guard let first = newer.first, let last = newer.last else { return older }
        let head: ArraySlice<RouteWaypoint>
        if let i = older.firstIndex(where: { $0.name == first.name }) {
            head = older[..<i]
        } else if let p = position ?? newer.lazy.compactMap(\.point).first, let i = joinIndex(of: p, in: older) {
            head = older[..<i]
        } else {
            return newer
        }
        guard !reachesDestination else { return Array(head) + newer }
        if let j = older.lastIndex(where: { $0.name == last.name }), j >= head.count {
            return Array(head) + newer + older[(j + 1)...]
        }
        if let p = newer.last(where: { $0.point != nil })?.point, let j = joinIndex(of: p, in: older), j >= head.count {
            return Array(head) + newer + older[j...]
        }
        return Array(head) + newer
    }

    /// The index of the first waypoint of `route` ahead of `p`, when `p` lies within `joinNM` of it.
    static func joinIndex(of p: GeoPoint, in route: [RouteWaypoint]) -> Int? {
        let placed = route.indices.compactMap { i in route[i].point.map { (index: i, point: $0) } }
        guard let s = RouteGeometry.nearestSegment(placed.map(\.point), to: p), s.distance <= joinNM else { return nil }
        return s.index == 0 && s.fraction == 0 ? 0 : placed[s.index].index + 1
    }
}

// MARK: - Route ahead of the aircraft

/// How a decoded route is drawn for an aircraft.
struct AcarsRoutePlan: Equatable, Sendable {
    /// Origin → placed waypoints → destination, each leg a great circle (for framing the flight).
    var path: [GeoPoint]
    /// From the aircraft through the waypoints still ahead to the destination.
    var remaining: [GeoPoint]
    /// Placed waypoints still ahead of the aircraft.
    var ahead: [RouteWaypoint]
    /// Along `remaining`.
    var remainingNM: Double
}

extension AcarsRoute {
    /// The farthest the aircraft may be from the route for it to be the one it's flying.
    static let onRouteNM: Double = 250

    /// The route as flown from `aircraft`: waypoints count as ahead once the aircraft's nearest
    /// point on the origin → waypoints → destination line comes before them. Nil when the route
    /// has no placed waypoints, the aircraft is more than `onRouteNM` from it, or nothing lies ahead.
    func plan(aircraft: GeoPoint, origin: GeoPoint?, destination: GeoPoint?) -> AcarsRoutePlan? {
        let placed = waypoints.compactMap { w in w.point.map { (point: $0, waypoint: Optional(w)) } }
        guard !placed.isEmpty else { return nil }
        var nodes: [(point: GeoPoint, waypoint: RouteWaypoint?)] = origin.map { [($0, nil)] } ?? []
        nodes += placed
        if let destination { nodes.append((destination, nil)) }
        guard let s = RouteGeometry.nearestSegment(nodes.map(\.point), to: aircraft), s.distance <= Self.onRouteNM else { return nil }
        // Nearest to a segment's end (fraction 1) means the aircraft is at or past that node.
        let next = s.fraction >= 1 ? s.index + 2 : s.index + 1
        guard next < nodes.count else { return nil }
        let rest = nodes[next...]
        let remaining = Self.greatCircles([aircraft] + rest.map(\.point))
        return AcarsRoutePlan(path: Self.greatCircles(nodes.map(\.point)), remaining: remaining,
                              ahead: rest.compactMap(\.waypoint), remainingNM: Self.length(remaining))
    }

    /// `points` joined by great circles, about one vertex per 40 nm, without repeated vertices.
    static func greatCircles(_ points: [GeoPoint]) -> [GeoPoint] {
        var out: [GeoPoint] = points.prefix(1).map { $0 }
        for (a, b) in zip(points, points.dropFirst()) {
            let nm = FlightService.gcDistance(a.lat, a.lon, b.lat, b.lon)
            out += FlightMath.greatCircle(from: a, to: b, count: max(2, Int(nm / 40) + 1)).dropFirst()
        }
        return FlightMath.removingRepeats(out)
    }

    static func length(_ path: [GeoPoint]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + FlightService.gcDistance($1.0.lat, $1.0.lon, $1.1.lat, $1.1.lon) }
    }
}
