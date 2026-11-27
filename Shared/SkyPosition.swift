// Where an aircraft appears in the observer's sky.
// Pure geodesy (Foundation only), shared by every target.

import Foundation

/// An aircraft's position in the observer's sky: elevation above the horizon, azimuth and
/// line-of-sight distance. Computed on the WGS-84 ellipsoid via ECEF and local
/// east-north-up coordinates, so Earth curvature is accounted for. Atmospheric refraction
/// is ignored (it lifts objects near the horizon by about half a degree at most).
struct SkyPosition: Equatable, Sendable {
    /// Degrees above the local horizon (negative: below it, hidden by Earth's curvature).
    let elevation: Double
    /// Degrees clockwise from true north, 0..<360.
    let azimuth: Double
    /// Straight-line distance from the observer to the aircraft, in nautical miles.
    let slantRangeNM: Double

    /// True when the aircraft is geometrically above the observer's horizon.
    var isAboveHorizon: Bool { elevation > 0 }

    /// 16-point compass name for the azimuth ("N", "NNE", …).
    var compassPoint: String { FlightMath.compassPoint(azimuth) }

    /// - Parameters:
    ///   - observer: Observer's latitude and longitude.
    ///   - observerHeightM: Observer's height above the ellipsoid in metres (0 = sea level).
    ///   - aircraft: Aircraft's latitude and longitude.
    ///   - altitudeFt: Aircraft altitude in feet (barometric is close enough for pointing).
    init(observer: GeoPoint, observerHeightM: Double = 0, aircraft: GeoPoint, altitudeFt: Double) {
        let o = Self.ecef(observer, heightM: observerHeightM)
        let a = Self.ecef(aircraft, heightM: altitudeFt * 0.3048)
        let d = (x: a.x - o.x, y: a.y - o.y, z: a.z - o.z)

        let φ = observer.lat * .pi / 180, λ = observer.lon * .pi / 180
        let east = -sin(λ) * d.x + cos(λ) * d.y
        let north = -sin(φ) * cos(λ) * d.x - sin(φ) * sin(λ) * d.y + cos(φ) * d.z
        let up = cos(φ) * cos(λ) * d.x + cos(φ) * sin(λ) * d.y + sin(φ) * d.z

        let horizontal = (east * east + north * north).squareRoot()
        elevation = atan2(up, horizontal) * 180 / .pi
        let az = atan2(east, north) * 180 / .pi
        azimuth = horizontal < 1e-6 ? 0 : (az + 360).truncatingRemainder(dividingBy: 360)
        slantRangeNM = (horizontal * horizontal + up * up).squareRoot() / 1852
    }

    // WGS-84 ellipsoid.
    private static let a = 6_378_137.0
    private static let e2 = 6.694_379_990_14e-3

    /// Earth-centred, Earth-fixed coordinates in metres.
    private static func ecef(_ p: GeoPoint, heightM h: Double) -> (x: Double, y: Double, z: Double) {
        let φ = p.lat * .pi / 180, λ = p.lon * .pi / 180
        let n = a / (1 - e2 * sin(φ) * sin(φ)).squareRoot()
        return ((n + h) * cos(φ) * cos(λ), (n + h) * cos(φ) * sin(λ), (n * (1 - e2) + h) * sin(φ))
    }
}
