// Searching, sorting, row text and map-label layout for the main window's aircraft list and radar map.
// Pure Foundation so it can be unit tested.

import Foundation

/// Order of the main window's aircraft list.
enum FlightSort: String, CaseIterable, Identifiable {
    /// Nearest first.
    case distance
    /// Lowest first: the aircraft easiest to see from the ground lead.
    case altitude
    /// Alphabetical by flight number (or callsign / registration).
    case flight

    var id: String { rawValue }
    var title: String {
        switch self {
        case .distance: "Distance"
        case .altitude: "Altitude"
        case .flight: "Flight"
        }
    }
}

enum FlightListFilter {
    /// Whether `flight` matches every whitespace-separated word of `query`, ignoring case and
    /// diacritics. Words are looked up in the callsign, flight number, registration, ICAO type and
    /// hex, aircraft model, airline name and code, route airports and squawk. An empty query
    /// matches everything.
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
            switch sort {
            case .distance: break
            case .altitude: if a.altitude != b.altitude { return a.altitude < b.altitude }
            case .flight:
                let order = a.displayNumber.localizedStandardCompare(b.displayNumber)
                if order != .orderedSame { return order == .orderedAscending }
            }
            if a.distance != b.distance { return a.distance < b.distance }
            return a.id < b.id
        }
    }

    /// `live` with route and aircraft details filled in from `known` (earlier resolved lookups, by
    /// hex) where the live record has none. A known route is reused while it still fits the
    /// aircraft's live position and heading, or with its diversion or return (which can take the
    /// aircraft off the scheduled route).
    static func merging(_ live: [Flight], known: [String: Flight]) -> [Flight] {
        live.map { flight in
            guard let k = known[flight.id] else { return flight }
            var f = flight
            if f.route == nil, let route = k.route, k.pathSituation != nil || FlightService.isPlausible(route, for: f) {
                f.route = route
                f.pathSituation = k.pathSituation
            }
            if f.aircraft == nil { f.aircraft = k.aircraft }
            return f
        }
    }

    private static func searchableFields(of f: Flight) -> [String] {
        var fields = [f.callsign, f.reg, f.typeCode, f.airlineName, f.id]
        fields += [f.route?.flightNo, f.airlineCode, f.aircraft?.model, f.route?.from.code, f.route?.from.city,
                   f.route?.to.code, f.route?.to.city, f.squawk].compactMap { $0 }
        return fields.filter { !$0.isEmpty }
    }
}

// MARK: - Row text

/// Climbing, descending or level, from the vertical rate (±300 ft/min dead band).
enum ClimbState: Equatable {
    case climbing, descending, level

    init(verticalRate: Double) {
        self = verticalRate > 300 ? .climbing : verticalRate < -300 ? .descending : .level
    }
}

/// Text for one aircraft in the main window's list, inspector and VoiceOver.
enum FlightRowText {
    /// Second line of a list row: the route ("ORD → DEN", or "ORD → MKE" while diverting there)
    /// when known, otherwise the airline or owner, then the ICAO type ("ORD → DEN · B738",
    /// "Southwest Airlines · B737").
    static func subtitle(_ f: Flight) -> String {
        let lead = f.route.map { "\($0.from.code) → \(f.destination?.code ?? $0.to.code)" } ?? f.airlineName
        return [lead, f.typeCode].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Second line of a list row for a flight with a runway phase: the compact phase ("Final 28C ·
    /// 6 nm") and what's left room for (the route, else the type, else the airline). Nil without a tag.
    static func phaseSubtitle(_ f: Flight, phase: RunwayPhase?, options: DisplayOptions) -> (tag: String, rest: String)? {
        guard let tag = phase?.tag(options.withStandardStyle) else { return nil }
        let rest = f.route.map { "\($0.from.code) → \(f.destination?.code ?? $0.to.code)" }
            ?? (f.typeCode.isEmpty ? f.airlineName : f.typeCode)
        return (tag, rest)
    }

    /// Who's flying it: the airline or owner, else "Private" for non-airline callsigns.
    static func operatorName(_ f: Flight) -> String {
        if !f.airlineName.isEmpty { return f.airlineName }
        return f.looksLikeAirline ? f.callsign : "Private / general aviation"
    }

    /// Vertical speed for the inspector: "+1,800 ft/min" / "−4.2 m/s", or "Level".
    static func verticalSpeed(_ rate: Double, units: UnitSystem) -> String {
        guard ClimbState(verticalRate: rate) != .level else { return "Level" }
        let sign = rate > 0 ? "+" : "−"
        if units == .metric { return sign + String(format: "%.1f m/s", abs(rate) * 0.00508) }
        return sign + "\((Int(abs(rate) / 50) * 50).formatted()) ft/min"
    }

    /// VoiceOver label: who the aircraft is.
    static func accessibilityLabel(_ f: Flight) -> String {
        var parts = [f.displayNumber]
        if let r = f.route { parts.append("\(r.from.code) to \(r.to.code)") }
        if !f.airlineName.isEmpty { parts.append(f.airlineName) }
        if let model = f.aircraft?.model, !model.isEmpty { parts.append(model) } else if !f.typeCode.isEmpty { parts.append(f.typeCode) }
        if let s = f.situation { parts.append(s.spoken) }
        return parts.joined(separator: ", ")
    }

    /// VoiceOver value: where it is, in words rather than unit abbreviations.
    static func accessibilityValue(_ f: Flight, units: UnitSystem) -> String {
        let metric = units == .metric
        let altitude = metric ? "\(Int(Double(f.altitude) * 0.3048).formatted()) meters" : "\(f.altitude.formatted()) feet"
        let climb: String
        switch ClimbState(verticalRate: f.verticalRate) {
        case .climbing: climb = ", climbing"
        case .descending: climb = ", descending"
        case .level: climb = ""
        }
        let distance = metric ? String(format: "%.1f kilometers", f.distance * 1.852) : String(format: "%.1f nautical miles", f.distance)
        return "\(altitude)\(climb), \(distance) \(spokenDirection(f.bearing))"
    }

    private static func spokenDirection(_ bearing: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let d = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d + 22.5) / 45) % 8]
    }
}

// MARK: - Map label decluttering

/// Chooses which aircraft on the radar map get a flight-number label, so labels never overlap
/// each other or cover other aircraft. Works in screen points on a north-up Web Mercator map.
enum MapLabelLayout {
    /// The visible map: its centre, span in degrees and size in points.
    struct Viewport: Equatable {
        var center: GeoPoint
        var latitudeDelta: Double
        var longitudeDelta: Double
        var size: CGSize
    }

    /// One aircraft that could be labelled.
    struct Item: Equatable {
        var id: String
        var point: GeoPoint
        var text: String
    }

    /// Size of an aircraft icon's footprint, in points.
    static let iconSize = CGSize(width: 18, height: 18)
    /// Height of a label and its gap below the icon centre.
    static let labelHeight: CGFloat = 13
    static let labelOffset: CGFloat = 12

    /// Screen position of `p`, or nil when the viewport is degenerate.
    static func project(_ p: GeoPoint, in v: Viewport) -> CGPoint? {
        guard v.latitudeDelta > 0, v.longitudeDelta > 0, v.size.width > 0, v.size.height > 0 else { return nil }
        func mercator(_ lat: Double) -> Double {
            let φ = max(-85, min(85, lat)) * .pi / 180
            return log(tan(.pi / 4 + φ / 2))
        }
        // The region's centre is the view's centre; its latitude span covers the height, which in
        // Mercator units is about the span divided by cos(latitude).
        let height = v.latitudeDelta * .pi / 180 / max(0.05, cos(v.center.lat * .pi / 180))
        var dLon = p.lon - v.center.lon
        dLon = (dLon + 540).truncatingRemainder(dividingBy: 360) - 180
        let x = (dLon / v.longitudeDelta + 0.5) * v.size.width
        let y = (0.5 - (mercator(p.lat) - mercator(v.center.lat)) / height) * v.size.height
        return CGPoint(x: x, y: y)
    }

    /// The label's rectangle for an icon centred at `p`.
    static func labelRect(at p: CGPoint, text: String) -> CGRect {
        let width = CGFloat(text.count) * 6.2 + 6
        return CGRect(x: p.x - width / 2, y: p.y + labelOffset, width: width, height: labelHeight)
    }

    /// The ids to label. `items` come in priority order (nearest first); `pinned` (the selection)
    /// is always labelled; ids in `prefer` (the previous result) go before the rest so labels
    /// don't flicker as aircraft move. At most `limit` labels are placed.
    static func labelled(_ items: [Item], in v: Viewport, pinned: String? = nil,
                         prefer: Set<String> = [], limit: Int = 60) -> Set<String> {
        let bounds = CGRect(origin: .zero, size: v.size).insetBy(dx: -20, dy: -20)
        let projected: [(item: Item, at: CGPoint)] = items.compactMap { item in
            guard let p = project(item.point, in: v), bounds.contains(p) else { return nil }
            return (item, p)
        }
        let icons = projected.map { (id: $0.item.id, rect: CGRect(x: $0.at.x - iconSize.width / 2, y: $0.at.y - iconSize.height / 2,
                                                                  width: iconSize.width, height: iconSize.height)) }
        func rank(_ id: String) -> Int { id == pinned ? 0 : prefer.contains(id) ? 1 : 2 }
        let ordered = projected.enumerated().sorted { a, b in
            let ra = rank(a.element.item.id), rb = rank(b.element.item.id)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)

        var placed: [CGRect] = []
        var result: Set<String> = []
        for (item, at) in ordered {
            let rect = labelRect(at: at, text: item.text)
            if item.id != pinned {
                guard result.count < limit else { break }
                if placed.contains(where: { $0.intersects(rect) }) { continue }
                if icons.contains(where: { $0.id != item.id && $0.rect.intersects(rect) }) { continue }
            }
            placed.append(rect)
            result.insert(item.id)
        }
        return result
    }
}
