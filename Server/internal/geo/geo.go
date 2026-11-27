// Package geo has the small amount of spherical geometry the server needs. The formulas and the
// Earth radius match the Swift app's FlightService.gcDistance / initialBearing exactly, so
// distances computed here agree with what the apps show.
package geo

import "math"

// EarthRadiusNM is the mean Earth radius in nautical miles.
const EarthRadiusNM = 3440.065

func rad(d float64) float64 { return d * math.Pi / 180 }

// DistanceNM is the great-circle (haversine) distance between two points in nautical miles.
func DistanceNM(lat1, lon1, lat2, lon2 float64) float64 {
	dLat, dLon := rad(lat2-lat1), rad(lon2-lon1)
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(rad(lat1))*math.Cos(rad(lat2))*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * EarthRadiusNM * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// BearingDeg is the initial true bearing from point 1 to point 2, in degrees [0, 360).
func BearingDeg(lat1, lon1, lat2, lon2 float64) float64 {
	y := math.Sin(rad(lon2-lon1)) * math.Cos(rad(lat2))
	x := math.Cos(rad(lat1))*math.Sin(rad(lat2)) - math.Sin(rad(lat1))*math.Cos(rad(lat2))*math.Cos(rad(lon2-lon1))
	return math.Mod(math.Atan2(y, x)*180/math.Pi+360, 360)
}

// AngleDiff is the smaller angle between two directions in degrees, in [0, 180].
func AngleDiff(a, b float64) float64 {
	return math.Abs(math.Mod(a-b+540, 360) - 180)
}

// CircleInside reports whether the circle (lat, lon, r) lies entirely inside the circle
// (clat, clon, cr). Radii are in nautical miles.
func CircleInside(lat, lon, r, clat, clon, cr float64) bool {
	return DistanceNM(clat, clon, lat, lon)+r <= cr
}
