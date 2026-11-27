// Pure geometry for drawing a flight's route on a map: splitting the planned route at the
// aircraft, the short heading vector shown when the route is unknown, and antimeridian-safe
// polylines. Foundation only, so it compiles into every target and is unit-tested.

import Foundation

enum RouteGeometry {
    private static let earthRadiusNM = 3440.065

    /// The nearest point to `p` on the great-circle segment `a`→`b`: its distance from `p` (nm)
    /// and how far along the segment it lies (0 = `a`, 1 = `b`).
    static func nearest(on a: GeoPoint, _ b: GeoPoint, to p: GeoPoint) -> (distance: Double, fraction: Double) {
        let length = FlightService.gcDistance(a.lat, a.lon, b.lat, b.lon) / earthRadiusNM
        let toP = FlightService.gcDistance(a.lat, a.lon, p.lat, p.lon) / earthRadiusNM
        guard length > 1e-9 else { return (toP * earthRadiusNM, 0) }
        let angle = (FlightService.initialBearing(a.lat, a.lon, p.lat, p.lon)
                     - FlightService.initialBearing(a.lat, a.lon, b.lat, b.lon)) * .pi / 180
        // Behind `a`: the start is nearest.
        if cos(angle) < 0 { return (toP * earthRadiusNM, 0) }
        let crossTrack = asin(max(-1, min(1, sin(toP) * sin(angle))))
        let alongTrack = acos(max(-1, min(1, cos(toP) / cos(crossTrack))))
        if alongTrack > length { return (FlightService.gcDistance(b.lat, b.lon, p.lat, p.lon), 1) }
        return (abs(crossTrack) * earthRadiusNM, alongTrack / length)
    }

    /// The point `fraction` of the way along the great circle from `a` to `b`.
    static func intermediate(_ a: GeoPoint, _ b: GeoPoint, fraction f: Double) -> GeoPoint {
        let φ1 = a.lat * .pi / 180, λ1 = a.lon * .pi / 180
        let φ2 = b.lat * .pi / 180, λ2 = b.lon * .pi / 180
        let d = FlightService.gcDistance(a.lat, a.lon, b.lat, b.lon) / earthRadiusNM
        guard d > 1e-9 else { return a }
        let A = sin((1 - f) * d) / sin(d), B = sin(f * d) / sin(d)
        let x = A * cos(φ1) * cos(λ1) + B * cos(φ2) * cos(λ2)
        let y = A * cos(φ1) * sin(λ1) + B * cos(φ2) * sin(λ2)
        let z = A * sin(φ1) + B * sin(φ2)
        return GeoPoint(lat: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, lon: atan2(y, x) * 180 / .pi)
    }

    /// The segment of `path` (from `path[index]` to `path[index + 1]`) passing closest to `p`, how
    /// far along it the nearest point lies, and its distance (nm). Nil for fewer than two points.
    static func nearestSegment(_ path: [GeoPoint], to p: GeoPoint) -> (index: Int, fraction: Double, distance: Double)? {
        guard path.count > 1 else { return nil }
        var best = (index: 0, fraction: 0.0, distance: Double.infinity)
        for i in path.indices.dropLast() {
            let n = nearest(on: path[i], path[i + 1], to: p)
            if n.distance < best.distance { best = (i, n.fraction, n.distance) }
        }
        return best
    }

    /// Splits `path` where it passes closest to `aircraft`. `flown` runs from the start to that
    /// point on the path; `remaining` starts at the aircraft itself (so the line meets the marker
    /// even when it's off the planned route) and continues with the rest of the path.
    static func split(_ path: [GeoPoint], at aircraft: GeoPoint) -> (flown: [GeoPoint], remaining: [GeoPoint]) {
        guard let best = nearestSegment(path, to: aircraft) else { return ([], []) }
        let onPath = intermediate(path[best.index], path[best.index + 1], fraction: best.fraction)
        let flown = FlightMath.removingRepeats(Array(path[...best.index]) + [onPath])
        let remaining = FlightMath.removingRepeats([aircraft] + Array(path[(best.index + 1)...]))
        return (flown.count > 1 ? flown : [], remaining.count > 1 ? remaining : [])
    }

    /// Where the aircraft will be in `minutes` at its current track and ground speed, as a short
    /// great-circle line from its position; empty when it's too slow for a meaningful vector.
    static func headingVector(from p: GeoPoint, track: Double, speedKT: Double, minutes: Double = 10) -> [GeoPoint] {
        guard speedKT > 50, minutes > 0, track.isFinite else { return [] }
        let δ = speedKT * minutes / 60 / earthRadiusNM, θ = track * .pi / 180
        let φ1 = p.lat * .pi / 180, λ1 = p.lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        let end = GeoPoint(lat: φ2 * 180 / .pi, lon: (λ2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180)
        return FlightMath.removingRepeats(FlightMath.greatCircle(from: p, to: end, count: 8))
    }

    /// Breaks a line where it crosses the antimeridian (a longitude jump of more than 180°) into
    /// pieces that end and start exactly on ±180°, so the map never draws it the long way round.
    /// Pieces with fewer than two points are dropped.
    static func antimeridianSafe(_ points: [GeoPoint]) -> [[GeoPoint]] {
        var lines: [[GeoPoint]] = []
        var current: [GeoPoint] = []
        for p in points {
            if let last = current.last, abs(p.lon - last.lon) > 180 {
                let edge: Double = last.lon > 0 ? 180 : -180
                let unwrapped = p.lon + (last.lon > 0 ? 360 : -360)
                let t = (edge - last.lon) / (unwrapped - last.lon)
                let lat = last.lat + t * (p.lat - last.lat)
                current.append(GeoPoint(lat: lat, lon: edge))
                lines.append(current)
                current = [GeoPoint(lat: lat, lon: -edge)]
            }
            current.append(p)
        }
        lines.append(current)
        return lines.map(FlightMath.removingRepeats).filter { $0.count > 1 }
    }
}

/// Where the detail map's camera goes on its own. It opens on a local view around the aircraft
/// and never zooms out to fit a route or track (that's the explicit "Show Whole Flight" action).
enum DetailCamera {
    /// Width of the opening view: about the user's search area, kept between a close-up and a regional view.
    static func localSpanNM(radiusNM: Int) -> Double {
        min(400, max(60, Double(radiusNM) * 2.4))
    }

    /// The opening region, centred on `center` (the aircraft, or the user before its position arrives).
    static func localRegion(around center: GeoPoint, radiusNM: Int) -> DetailFormat.Framing {
        let latDelta = localSpanNM(radiusNM: radiusNM) / 60
        return DetailFormat.Framing(center: center, latitudeDelta: latDelta,
                                    longitudeDelta: min(360, latDelta / max(0.2, cos(center.lat * .pi / 180))))
    }
}
