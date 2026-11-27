// Plain-language position: runway phase, vertical state, nearest airport and next fix.

import Foundation

/// The next route fix and the distance to it, from the caller's route decoding.
struct NextFix: Equatable, Sendable {
    var name: String
    var distanceNM: Double
}

/// A plain-language description of where an aircraft is, one sentence per aspect.
struct PositionDescription: Equatable, Sendable {
    /// "Final RWY 28C at ORD · 6.0 nm · on glidepath", "Landed at ORD on RWY 28C".
    var phase: String?
    /// "Cruising at FL370", "Descending through 6,000 ft"; nil on the ground.
    var vertical: String?
    /// "12 nm NW of ORD", "Over ORD", "At ORD".
    var location: String?
    /// "Next waypoint PAITN · 34 nm".
    var next: String?
    /// Whether `phase` describes the present (false for a departure runway).
    var phaseIsCurrent = false

    /// The single most useful line: a current runway phase, else the vertical state, else the location.
    var headline: String {
        (phaseIsCurrent ? phase : nil) ?? vertical ?? phase ?? location ?? ""
    }

    /// Every available line, phase first.
    var lines: [String] { [phase, vertical, location, next].compactMap { $0 } }
}

/// Builds `PositionDescription`s in the user's units. Pure: the caller supplies the runway phase
/// (`ApproachAnalyzer`) and nearest airport (`AirportDB.nearest(to:within:)`).
enum PositionDescriber {
    /// Pressure altitude from which altitudes are given as flight levels (the US transition altitude).
    static let flightLevelFromFt = 18_000
    /// How far away the nearest airport is still worth naming.
    static let nearbyAirportNM = 40.0

    /// - Parameters:
    ///   - phase: from `ApproachAnalyzer.phase(of:onGround:trail:qnhHPa:)`.
    ///   - nearest: the closest airport, if any within `nearbyAirportNM`.
    ///   - onGround: the feed's ground flag.
    ///   - now: reference time for "departed … ago".
    static func describe(_ f: Flight, phase: RunwayPhase?, nearest: Airport?, onGround: Bool = false,
                         nextFix: NextFix? = nil, options: DisplayOptions, locale: Locale = .autoupdatingCurrent,
                         now: Date = Date()) -> PositionDescription {
        var sentence = options
        sentence.style = .standard          // "6,000 ft", not the LED board's "6,000FT"
        let text = Formatter(options: sentence, locale: locale)
        let grounded = onGround || phase.map(isGroundPhase) == true
        return PositionDescription(
            phase: phase.map { phaseText($0, airborne: !grounded, text: text, now: now) },
            vertical: grounded ? nil : verticalText(f, text: text),
            location: nearest.flatMap { location(of: f.geoPoint, airport: $0, grounded: grounded, options: sentence, locale: locale) },
            next: nextFix.map { "Next waypoint \($0.name) · \(text.distance($0.distanceNM))" },
            phaseIsCurrent: phase?.isCurrent ?? false)
    }

    /// `describe` with the nearest airport looked up in the bundled table.
    static func describe(_ f: Flight, phase: RunwayPhase?, onGround: Bool = false, nextFix: NextFix? = nil,
                         options: DisplayOptions, now: Date = Date()) -> PositionDescription {
        describe(f, phase: phase, nearest: AirportDB.nearest(to: f.geoPoint, within: nearbyAirportNM),
                 onGround: onGround, nextFix: nextFix, options: options, now: now)
    }

    // MARK: - Pieces

    private struct Formatter {
        let options: DisplayOptions
        let locale: Locale
        func distance(_ nm: Double) -> String { DetailFormat.distance(nm, units: options.units, locale: locale) }
        func altitude(_ ft: Int) -> String { options.altitude(ft) }
    }

    private static func isGroundPhase(_ phase: RunwayPhase) -> Bool {
        switch phase {
        case .landed, .onRunway, .taxiing: return true
        case .finalApproach, .takingOff, .departed, .goAround: return false
        }
    }

    private static func phaseText(_ phase: RunwayPhase, airborne: Bool, text: Formatter, now: Date) -> String {
        let code = phase.airport.code
        switch phase {
        case .finalApproach(let f):
            var parts = ["Final RWY \(f.runway) at \(code)", text.distance(f.distanceNM)]
            switch f.glidepath {
            case .onPath?: parts.append("on glidepath")
            case .high?: parts.append("above glidepath")
            case .low?: parts.append("below glidepath")
            case nil: break
            }
            return parts.joined(separator: " · ")
        case .landed(_, let runway): return "Landed at \(code) on RWY \(runway)"
        case .onRunway(_, let runway): return "On RWY \(runway) at \(code)"
        case .taxiing: return "Taxiing at \(code)"
        case .takingOff(_, let runway):
            return airborne ? "Climbing out of \(code) on RWY \(runway)" : "Taking off from \(code) on RWY \(runway)"
        case .departed(_, let runway, let time):
            return "Departed \(code) on RWY \(runway) · \(FlightMath.durationText(now.timeIntervalSince(time))) ago"
        case .goAround(_, let runway): return "Go-around at \(code) from RWY \(runway)"
        }
    }

    private static func verticalText(_ f: Flight, text: Formatter) -> String {
        let rounded = Int((Double(f.altitude) / 100).rounded()) * 100
        let level: String
        if rounded >= flightLevelFromFt {
            let fl = String(format: "FL%03d", rounded / 100)
            level = text.options.units == .metric ? "\(text.altitude(rounded)) (\(fl))" : fl
        } else {
            level = text.altitude(rounded)
        }
        if f.verticalRate > 300 { return "Climbing through \(level)" }
        if f.verticalRate < -300 { return "Descending through \(level)" }
        return rounded >= flightLevelFromFt ? "Cruising at \(level)" : "Level at \(level)"
    }

    // MARK: - Shared pieces

    /// "12 nm NW of ORD", or "Over ORD" / "At ORD" (`grounded`) within 2 nm; nil beyond `nearbyAirportNM`.
    static func location(of p: GeoPoint, airport: Airport, grounded: Bool = false, options: DisplayOptions = DisplayOptions(),
                         locale: Locale = .autoupdatingCurrent) -> String? {
        let d = FlightService.gcDistance(airport.lat, airport.lon, p.lat, p.lon)
        guard d <= nearbyAirportNM else { return nil }
        if d < 2 { return grounded ? "At \(airport.code)" : "Over \(airport.code)" }
        let direction = FlightMath.compassPoint(FlightService.initialBearing(airport.lat, airport.lon, p.lat, p.lon))
        return "\(DetailFormat.distance(d, units: options.units, locale: locale)) \(direction) of \(airport.code)"
    }

    /// `location(of:airport:…)` relative to the nearest airport in the bundled table.
    static func location(of p: GeoPoint, options: DisplayOptions = DisplayOptions()) -> String? {
        AirportDB.nearest(to: p, within: nearbyAirportNM).flatMap { location(of: p, airport: $0, options: options) }
    }

    /// "Touchdown ≈ 21:42 (in 2 m)": when the aircraft reaches the threshold at its current ground speed.
    /// - Parameter now: when `approach` was worked out.
    static func touchdown(_ approach: FinalApproach, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                          timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = timeZone
        let time = now.addingTimeInterval(approach.eta).formatted(style)
        return "Touchdown ≈ \(time) (in \(FlightMath.durationText(approach.eta)))"
    }
}

// MARK: - Compact tags

extension RunwayPhase {
    /// A short label for list rows, the widget, the panel and the menu: "Final 28C · 6 nm" (LED
    /// "6NM"; the board uppercases the rest), "Landed 28C", "Departing 10L", "Go-around 28C",
    /// "Taxiing". Nil for `.departed`, which is history. Without `distance` a final is just "Final 28C".
    func tag(_ o: DisplayOptions, distance: Bool = true) -> String? {
        switch self {
        case .finalApproach(let f):
            let base = "Final \(f.runway)"
            return distance ? "\(base) · \(Self.compactDistance(f.distanceNM, o))" : base
        case .landed(_, let r): return "Landed \(r)"
        case .onRunway(_, let r): return "Runway \(r)"
        case .taxiing: return "Taxiing"
        case .takingOff(_, let r): return "Departing \(r)"
        case .goAround(_, let r): return "Go-around \(r)"
        case .departed: return nil
        }
    }

    /// SF Symbol for labels.
    var symbol: String {
        switch self {
        case .finalApproach, .landed, .onRunway: return "airplane.arrival"
        case .takingOff, .departed: return "airplane.departure"
        case .goAround: return "arrow.uturn.up"
        case .taxiing: return "road.lanes"
        }
    }

    /// Go-arounds are worth a caution colour; everything else is routine.
    var isCaution: Bool {
        if case .goAround = self { return true }
        return false
    }

    /// "6 nm" / "6NM", with one decimal under 2 ("1.4 nm").
    private static func compactDistance(_ nm: Double, _ o: DisplayOptions) -> String {
        let metric = o.units == .metric
        let value = max(0, metric ? nm * 1.852 : nm)
        let number = value < 1.95 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
        let unit = metric ? "km" : "nm"
        return o.isStandard ? "\(number) \(unit)" : number + unit.uppercased()
    }
}
