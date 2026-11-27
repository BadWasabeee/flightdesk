// Runway phase detection: final approach, landing, taxi, takeoff, departure and go-around.
// Pure geometry on the live position and an optional recorded trail; no UI or network.

import Foundation

/// A recorded position, oldest first in a trail.
struct TrailSample: Equatable, Sendable {
    var point: GeoPoint
    var time: Date
    /// Barometric altitude in feet, when recorded.
    var altitudeFt: Double?
}

extension FlightTrack {
    /// The track as trail samples; only the first carries an altitude (`startAltitudeFt`).
    var trailSamples: [TrailSample] {
        points.enumerated().map { i, p in TrailSample(point: p.point, time: p.time, altitudeFt: i == 0 ? startAltitudeFt : nil) }
    }
}

/// Where the aircraft sits relative to a 3° glidepath.
enum GlidepathStatus: Equatable, Sendable {
    case onPath, high, low
}

/// An aircraft established on final approach to a runway.
struct FinalApproach: Equatable, Sendable {
    var airport: Airport
    /// Runway end designator ("28C").
    var runway: String
    /// Along-track distance to the threshold.
    var distanceNM: Double
    /// Offset from the extended centreline (positive = right of it, looking toward the runway).
    var crossTrackNM: Double
    /// Height above (+) or below (−) a 3° glidepath crossing the threshold at 50 ft, from 0.5 nm out.
    var glidepathDeviationFt: Double?
    var glidepath: GlidepathStatus?
    /// Time to the threshold at the current ground speed.
    var eta: TimeInterval
}

/// What an aircraft is doing on or around a runway.
enum RunwayPhase: Equatable, Sendable {
    case finalApproach(FinalApproach)
    /// On the runway centreline after arriving (touchdown or rollout).
    case landed(airport: Airport, runway: String)
    /// On the runway centreline with nothing to tell landing from takeoff.
    case onRunway(airport: Airport, runway: String)
    /// On the ground at the airport, off the runway or slow across it.
    case taxiing(airport: Airport)
    /// Takeoff roll, or climbing out along the runway's extended centreline.
    case takingOff(airport: Airport, runway: String)
    /// Took off from this runway; `time` is the first recorded point on its centreline or climb-out path.
    case departed(airport: Airport, runway: String, time: Date)
    /// Was on final, now climbing away along the runway heading.
    case goAround(airport: Airport, runway: String)

    var airport: Airport {
        switch self {
        case .finalApproach(let f): return f.airport
        case .landed(let a, _), .onRunway(let a, _), .taxiing(let a), .takingOff(let a, _), .departed(let a, _, _), .goAround(let a, _):
            return a
        }
    }

    /// Runway end designator, when the phase names one.
    var runway: String? {
        switch self {
        case .finalApproach(let f): return f.runway
        case .landed(_, let r), .onRunway(_, let r), .takingOff(_, let r), .departed(_, let r, _), .goAround(_, let r): return r
        case .taxiing: return nil
        }
    }

    /// False for `.departed`, which describes the past rather than what the aircraft is doing now.
    var isCurrent: Bool {
        if case .departed = self { return false }
        return true
    }
}

/// Works out the runway phase of one aircraft from its live position and, optionally, its trail.
///
/// Altitudes are barometric (pressure altitude, referenced to 1013.25 hPa) unless the caller
/// supplies the aircraft's selected QNH, so height above the runway can be off by several hundred
/// feet in unusual weather; the height limits and glidepath bands are deliberately wide. A runway
/// is only named when the aircraft passes every check; among parallels the one with the smallest
/// centreline offset wins.
struct ApproachAnalyzer {
    /// Radius around the aircraft for candidate airports.
    static let searchRadiusNM = 25.0

    let airports: [AirportRunways]
    let origin: Airport?
    let destination: Airport?

    init(airports: [AirportRunways], origin: Airport? = nil, destination: Airport? = nil) {
        self.airports = airports
        self.origin = origin
        self.destination = destination
    }

    /// The current runway phase, else the departure runway from the trail, else nil.
    /// - Parameters:
    ///   - onGround: the feed's ground flag (`AircraftReport.onGround`).
    ///   - trail: recorded positions, oldest first; needed for go-arounds and departures.
    ///   - qnhHPa: the aircraft's selected altimeter setting, when the feed reports it.
    func phase(of f: Flight, onGround: Bool = false, trail: [TrailSample] = [], qnhHPa: Double? = nil) -> RunwayPhase? {
        let frames = self.frames
        guard !frames.isEmpty else { return nil }
        let altitude = Double(f.altitude) + (qnhHPa.map { ($0 - 1013.25) * 27.3 } ?? 0)
        let state = State(position: f.geoPoint, altitude: altitude, verticalRate: f.verticalRate, speed: f.speed, track: f.track)

        if let runway = groundRunway(state, onGround: onGround, frames: frames) {
            return groundPhase(state, nearest: runway, frames: frames, trail: trail)
        }
        if onGround { return nil }
        if let track = state.track {
            if let g = goAround(state, track: track, frames: frames, trail: trail) { return g }
            if let fa = finalApproach(state, track: track, frames: frames) { return .finalApproach(fa) }
            if let t = takingOff(state, track: track, frames: frames, trail: trail) { return t }
        }
        return departure(trail: trail, frames: frames)
    }

    /// The runway the trail shows the aircraft taking off from, when the trail starts at an airport.
    func departure(trail: [TrailSample]) -> RunwayPhase? {
        departure(trail: trail, frames: frames)
    }

    private var frames: [RunwayFrame] {
        airports.flatMap { a in a.runways.flatMap { r in r.ends.map { RunwayFrame(airport: a.airport, runway: r, end: $0) } } }
    }

    // MARK: - Thresholds

    /// Largest track/heading difference that counts as aligned.
    private static let alignmentDeg = 15.0
    /// Largest along-track distance for final approach.
    private static let finalMaxNM = 20.0
    /// Height above the threshold of a 3° glidepath per nautical mile.
    private static let glidepathFtPerNM = 318.4

    /// Allowed centreline offset on final: 0.3 nm at 1 nm out, widening to 1.2 nm.
    private static func finalCrossLimit(_ distanceNM: Double) -> Double { min(1.2, 0.25 + 0.05 * distanceNM) }

    /// Allowed centreline offset climbing out: 0.3 nm over the runway, widening past its end.
    private static func climbOutCrossLimit(beyondEndNM: Double) -> Double { 0.3 + 0.05 * max(0, beyondEndNM) }

    private static func aligned(_ track: Double, _ heading: Double, within limit: Double = alignmentDeg) -> Bool {
        FlightService.angleBetween(track, heading) <= limit
    }

    // MARK: - Phases

    private struct State {
        let position: GeoPoint
        let altitude: Double
        let verticalRate: Double
        let speed: Double
        let track: Double?
    }

    /// The nearest runway when the aircraft is on the ground within 2.5 nm of one (flagged, or
    /// within 100 ft of its elevation below 80 kt).
    private func groundRunway(_ s: State, onGround: Bool, frames: [RunwayFrame]) -> RunwayFrame? {
        guard let nearest = frames.filter({ $0.end == $0.runway.low })
            .map({ ($0, $0.distanceToRunway(s.position)) }).min(by: { $0.1 < $1.1 }),
              nearest.1 <= 2.5,
              onGround || (s.altitude - nearest.0.runway.elevationFt <= 100 && s.speed < 80) else { return nil }
        return nearest.0
    }

    /// Landed, takeoff roll or lined up when on a runway centreline and aligned with it; taxiing when slow elsewhere.
    private func groundPhase(_ s: State, nearest: RunwayFrame, frames: [RunwayFrame], trail: [TrailSample]) -> RunwayPhase? {
        let onCentreline = frames.compactMap { frame -> (RunwayFrame, Double)? in
            let (along, cross) = frame.locate(s.position)
            guard abs(cross) <= 0.04, along >= -0.05, along <= frame.lengthNM + 0.05,
                  let track = s.track, Self.aligned(track, frame.end.heading, within: 20) else { return nil }
            return (frame, abs(cross))
        }.min { $0.1 < $1.1 }?.0

        guard let frame = onCentreline else { return s.speed < 40 ? .taxiing(airport: nearest.airport) : nil }
        let airport = frame.airport, runway = frame.end.ident
        let arrival: Bool, departure: Bool
        if let first = trail.first, trail.count > 1, frame.distance(from: first.point) > 8 {
            (arrival, departure) = (true, false)
        } else if trail.count > 1, trail.allSatisfy({ frame.distance(from: $0.point) <= 3 }) {
            (arrival, departure) = (false, true)
        } else {
            let isOrigin = origin?.code == airport.code, isDestination = destination?.code == airport.code
            (arrival, departure) = (isDestination && !isOrigin, isOrigin && !isDestination)
        }
        if arrival { return .landed(airport: airport, runway: runway) }
        if departure, s.speed >= 30 { return .takingOff(airport: airport, runway: runway) }
        return .onRunway(airport: airport, runway: runway)
    }

    private func finalApproach(_ s: State, track: Double, frames: [RunwayFrame]) -> FinalApproach? {
        guard s.speed >= 60, s.verticalRate <= 300 else { return nil }
        let candidates = frames.compactMap { frame -> Candidate<Double>? in
            let (along, cross) = frame.locate(s.position)
            let distance = -along
            let height = s.altitude - frame.runway.elevationFt
            guard distance > 0, distance <= Self.finalMaxNM, abs(cross) <= Self.finalCrossLimit(distance),
                  Self.aligned(track, frame.end.heading),
                  height >= -300, height <= min(6_000, 1_500 + 2 * Self.glidepathFtPerNM * distance),
                  s.verticalRate < -300 || height <= 4_000 else { return nil }
            return Candidate(frame: frame, crossTrack: cross, value: distance)
        }
        guard let best = Self.pick(candidates, preferring: destination) else { return nil }
        let distance = best.value
        let height = s.altitude - best.frame.runway.elevationFt
        var deviation: Double?, status: GlidepathStatus?
        if distance >= 0.5 {
            deviation = height - (50 + distance * Self.glidepathFtPerNM)
            // ±0.7° around 3°: wide enough to absorb typical pressure-altitude error.
            let angle = atan2(height - 50, distance * 6_076.12) * 180 / .pi
            status = angle > 3.7 ? .high : angle < 2.3 ? .low : .onPath
        }
        return FinalApproach(airport: best.frame.airport, runway: best.frame.end.ident, distanceNM: distance,
                             crossTrackNM: best.crossTrack, glidepathDeviationFt: deviation, glidepath: status,
                             eta: distance / s.speed * 3_600)
    }

    private func takingOff(_ s: State, track: Double, frames: [RunwayFrame], trail: [TrailSample]) -> RunwayPhase? {
        guard s.speed >= 60, s.verticalRate > 300 else { return nil }
        let candidates = frames.compactMap { frame -> Candidate<Void>? in
            let (along, cross) = frame.locate(s.position)
            let beyond = along - frame.lengthNM
            let height = s.altitude - frame.runway.elevationFt
            guard along >= 0, beyond <= 5, abs(cross) <= Self.climbOutCrossLimit(beyondEndNM: beyond),
                  Self.aligned(track, frame.end.heading), height >= -300, height <= 3_000 else { return nil }
            return Candidate(frame: frame, crossTrack: cross, value: ())
        }
        guard let best = Self.pick(candidates, preferring: origin)?.frame else { return nil }
        // Climbing over the runway after arriving is a go-around or missed approach, not a takeoff.
        if let first = trail.first, best.distance(from: first.point) > 8 { return nil }
        if trail.isEmpty, destination?.code == best.airport.code, origin?.code != best.airport.code { return nil }
        return .takingOff(airport: best.airport, runway: best.end.ident)
    }

    private func goAround(_ s: State, track: Double, frames: [RunwayFrame], trail: [TrailSample]) -> RunwayPhase? {
        guard !trail.isEmpty, s.speed >= 60, s.verticalRate > 500 else { return nil }
        let candidates = frames.compactMap { frame -> Candidate<Void>? in
            let (along, cross) = frame.locate(s.position)
            let height = s.altitude - frame.runway.elevationFt
            guard along >= -3, along - frame.lengthNM <= 5, abs(cross) <= 0.6, Self.aligned(track, frame.end.heading),
                  height >= -300, height <= 3_000, wasOnFinal(trail, frame: frame) else { return nil }
            return Candidate(frame: frame, crossTrack: cross, value: ())
        }
        guard let best = Self.pick(candidates, preferring: destination)?.frame else { return nil }
        return .goAround(airport: best.airport, runway: best.end.ident)
    }

    /// Whether a trail sample from the last 15 minutes was on this runway's final, heading in.
    private func wasOnFinal(_ trail: [TrailSample], frame: RunwayFrame) -> Bool {
        guard let latest = trail.last?.time else { return false }
        for (i, sample) in trail.enumerated() where latest.timeIntervalSince(sample.time) <= 15 * 60 {
            let (along, cross) = frame.locate(sample.point)
            let distance = -along
            guard distance >= 0.3, distance <= Self.finalMaxNM, abs(cross) <= Self.finalCrossLimit(distance) else { continue }
            if let alt = sample.altitudeFt, alt - frame.runway.elevationFt > 6_000 { continue }
            if let direction = Self.direction(from: i, in: trail), !Self.aligned(direction, frame.end.heading, within: 20) { continue }
            return true
        }
        return false
    }

    private func departure(trail: [TrailSample], frames: [RunwayFrame]) -> RunwayPhase? {
        guard trail.count > 1, let first = trail.first else { return nil }
        let candidates = frames.compactMap { frame -> Candidate<Date>? in
            guard frame.distance(from: first.point) <= 6 else { return nil }
            if let alt = first.altitudeFt, alt - frame.runway.elevationFt > 3_000 { return nil }
            for (i, sample) in trail.enumerated() {
                guard frame.distance(from: sample.point) <= 8 else { break }
                guard let direction = Self.direction(from: i, in: trail) else { continue }
                let (along, cross) = frame.locate(sample.point)
                let beyond = along - frame.lengthNM
                // On the runway itself the sample must be on the centreline, not a parallel taxiway.
                let limit = beyond <= 0 ? 0.05 : Self.climbOutCrossLimit(beyondEndNM: beyond)
                if along >= -0.2, beyond <= 6, abs(cross) <= limit, Self.aligned(direction, frame.end.heading) {
                    return Candidate(frame: frame, crossTrack: cross, value: sample.time)
                }
            }
            return nil
        }
        guard let best = Self.pick(candidates, preferring: origin) else { return nil }
        return .departed(airport: best.frame.airport, runway: best.frame.end.ident, time: best.value)
    }

    // MARK: - Helpers

    private struct Candidate<Value> {
        let frame: RunwayFrame
        let crossTrack: Double
        let value: Value
    }

    /// The candidate at `preferred` if there is one, else any, with the smallest centreline offset.
    private static func pick<V>(_ candidates: [Candidate<V>], preferring preferred: Airport?) -> Candidate<V>? {
        let atPreferred = candidates.filter { $0.frame.airport.code == preferred?.code }
        return (atPreferred.isEmpty ? candidates : atPreferred).min { abs($0.crossTrack) < abs($1.crossTrack) }
    }

    /// Direction of travel from trail sample `i` to the next one at least 0.2 nm (and at most 10 nm) away.
    private static func direction(from i: Int, in trail: [TrailSample]) -> Double? {
        let a = trail[i].point
        for b in trail[(i + 1)...].lazy.map(\.point) {
            let d = FlightService.gcDistance(a.lat, a.lon, b.lat, b.lon)
            if d > 10 { return nil }
            if d >= 0.2 { return FlightService.initialBearing(a.lat, a.lon, b.lat, b.lon) }
        }
        return nil
    }
}

/// One runway end as a local flat frame (accurate to well under 1% within 25 nm).
private struct RunwayFrame {
    let airport: Airport
    let runway: Runway
    let end: RunwayEnd
    /// Threshold-to-threshold distance.
    let lengthNM: Double

    init(airport: Airport, runway: Runway, end: RunwayEnd) {
        self.airport = airport
        self.runway = runway
        self.end = end
        let far = end == runway.low ? runway.high.threshold : runway.low.threshold
        lengthNM = FlightService.gcDistance(end.threshold.lat, end.threshold.lon, far.lat, far.lon)
    }

    /// Along-track distance past the threshold in the landing direction (negative before it) and
    /// offset from the centreline (positive = right), in nautical miles.
    func locate(_ p: GeoPoint) -> (along: Double, cross: Double) {
        let t = end.threshold
        let dLon = (p.lon - t.lon + 540).truncatingRemainder(dividingBy: 360) - 180
        let x = dLon * 60 * cos(t.lat * .pi / 180), y = (p.lat - t.lat) * 60
        let h = end.heading * .pi / 180
        return (x * sin(h) + y * cos(h), x * cos(h) - y * sin(h))
    }

    /// Distance from `p` to the runway surface (its centreline segment).
    func distanceToRunway(_ p: GeoPoint) -> Double {
        let (along, cross) = locate(p)
        let outside = along < 0 ? -along : max(0, along - lengthNM)
        return hypot(outside, cross)
    }

    /// Distance from `p` to this end's threshold.
    func distance(from p: GeoPoint) -> Double {
        FlightService.gcDistance(p.lat, p.lon, end.threshold.lat, end.threshold.lon)
    }
}
