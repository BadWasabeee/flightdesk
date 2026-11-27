package trackenc

import "github.com/BadWasabeee/flightdesk/Server/internal/geo"

// Simplifier decides which observed positions are worth storing (a dead-band filter): a point is
// kept only when it differs meaningfully from the last stored point for the same aircraft.
type Simplifier struct {
	// HeadingDeg: keep when the track has turned more than this since the last stored point.
	HeadingDeg float64
	// AltFt: keep when the altitude has changed more than this.
	AltFt int
	// MaxGap: airborne, keep at least one point every MaxGap seconds.
	MaxGap int64
	// GroundGap: on the ground and moving (taxiing), keep one point every GroundGap seconds.
	GroundGap int64
	// ParkedGap: on the ground and stationary, keep one point every ParkedGap seconds. Busy
	// airports report dozens of parked aircraft for hours; this keeps them from filling the disk.
	ParkedGap int64
}

// DefaultSimplifier is the policy from the server's storage design.
var DefaultSimplifier = Simplifier{HeadingDeg: 3, AltFt: 200, MaxGap: 60, GroundGap: 60, ParkedGap: 600}

// parkedSpeedKt and parkedMoveNM define "stationary on the ground".
const (
	parkedSpeedKt = 5
	parkedMoveNM  = 0.03 // about 55 m
)

// Keep reports whether p should be stored given the last stored point.
func (s Simplifier) Keep(last, p Point) bool {
	if p.T <= last.T {
		return false
	}
	if p.Ground != last.Ground {
		return true
	}
	dt := p.T - last.T
	if p.Ground {
		moved := geo.DistanceNM(last.Lat, last.Lon, p.Lat, p.Lon)
		if p.SpeedKt < parkedSpeedKt && moved < parkedMoveNM {
			return dt >= s.ParkedGap
		}
		if dt >= s.GroundGap {
			return true
		}
		return p.HasTrack() && last.HasTrack() && geo.AngleDiff(float64(p.Track), float64(last.Track)) > s.HeadingDeg*5
	}
	if dt >= s.MaxGap {
		return true
	}
	if abs(p.AltFt-last.AltFt) > s.AltFt {
		return true
	}
	if p.HasTrack() != last.HasTrack() {
		return true
	}
	if p.HasTrack() && geo.AngleDiff(float64(p.Track), float64(last.Track)) > s.HeadingDeg {
		return true
	}
	return false
}

// Simplify runs the dead-band filter over a whole sequence (oldest first). The first and last
// points are always kept so the track starts and ends where the aircraft was seen.
func (s Simplifier) Simplify(pts []Point) []Point {
	if len(pts) <= 2 {
		return append([]Point(nil), pts...)
	}
	out := []Point{pts[0]}
	for _, p := range pts[1 : len(pts)-1] {
		if s.Keep(out[len(out)-1], p) {
			out = append(out, p)
		}
	}
	if last := pts[len(pts)-1]; last.T > out[len(out)-1].T {
		out = append(out, last)
	}
	return out
}

// Downsample thins a track for the long-term tier: at most one point per interval seconds, plus
// the first and last points and every ground/air transition (take-off and landing).
func Downsample(pts []Point, interval int64) []Point {
	if len(pts) <= 2 {
		return append([]Point(nil), pts...)
	}
	out := []Point{pts[0]}
	for i := 1; i < len(pts)-1; i++ {
		p, last := pts[i], out[len(out)-1]
		if p.Ground != pts[i-1].Ground || p.T-last.T >= interval {
			out = append(out, p)
		}
	}
	return append(out, pts[len(pts)-1])
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
