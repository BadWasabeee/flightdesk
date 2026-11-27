package trackenc

import (
	"math"
	"math/rand/v2"
)

// Synthetic flight profiles, used by tests and by the storage benchmark that the README's
// storage estimate is based on. They are sampled every SampleEvery seconds (the poll interval)
// with realistic ADS-B jitter, so the simplifier sees what it would see from the live feed.

// SampleEvery is the simulated poll interval in seconds.
const SampleEvery = 8

// Segment is one phase of a simulated flight.
type Segment struct {
	Seconds   int     // duration
	SpeedKt   float64 // ground speed
	VRateFpm  float64 // vertical rate (negative = descending)
	TurnDegS  float64 // turn rate in degrees per second (0 = straight)
	Ground    bool
	FloorFt   float64 // descent stops here
	CeilingFt float64 // climb stops here (0 = none)
}

// Profile is a named sequence of segments.
type Profile struct {
	Name     string
	StartAlt float64
	Segments []Segment
}

// Profiles typical of a busy terminal area (e.g. Chicago/Milwaukee).
var (
	Arrival = Profile{Name: "arrival", StartAlt: 35000, Segments: []Segment{
		{Seconds: 240, SpeedKt: 460},
		{Seconds: 300, SpeedKt: 430, VRateFpm: -1800, FloorFt: 11000},
		{Seconds: 20, SpeedKt: 420, VRateFpm: -1800, TurnDegS: 1.5, FloorFt: 11000},
		{Seconds: 300, SpeedKt: 400, VRateFpm: -1800, FloorFt: 11000},
		{Seconds: 30, SpeedKt: 300, VRateFpm: -1500, TurnDegS: -3, FloorFt: 3000},
		{Seconds: 180, SpeedKt: 250, VRateFpm: -1300, FloorFt: 3000},
		{Seconds: 30, SpeedKt: 210, TurnDegS: 3, FloorFt: 3000},
		{Seconds: 120, SpeedKt: 200, FloorFt: 3000},
		{Seconds: 30, SpeedKt: 180, TurnDegS: 3, FloorFt: 3000},
		{Seconds: 260, SpeedKt: 145, VRateFpm: -700, FloorFt: 0},
		{Seconds: 60, SpeedKt: 40, Ground: true},
		{Seconds: 300, SpeedKt: 15, Ground: true, TurnDegS: 0.6},
		{Seconds: 1200, SpeedKt: 0, Ground: true},
	}}
	Departure = Profile{Name: "departure", StartAlt: 0, Segments: []Segment{
		{Seconds: 900, SpeedKt: 0, Ground: true},
		{Seconds: 480, SpeedKt: 14, Ground: true, TurnDegS: -0.5},
		{Seconds: 40, SpeedKt: 120, Ground: true},
		{Seconds: 90, SpeedKt: 180, VRateFpm: 2500, CeilingFt: 35000},
		{Seconds: 30, SpeedKt: 220, VRateFpm: 2500, TurnDegS: 3, CeilingFt: 35000},
		{Seconds: 400, SpeedKt: 300, VRateFpm: 2500, CeilingFt: 35000},
		{Seconds: 20, SpeedKt: 380, VRateFpm: 2000, TurnDegS: -1.5, CeilingFt: 35000},
		{Seconds: 600, SpeedKt: 440, VRateFpm: 1500, CeilingFt: 35000},
	}}
	Overflight = Profile{Name: "overflight", StartAlt: 37000, Segments: []Segment{
		{Seconds: 700, SpeedKt: 470},
		{Seconds: 15, SpeedKt: 470, TurnDegS: 1},
		{Seconds: 800, SpeedKt: 470},
	}}
)

// Simulate samples a profile every SampleEvery seconds starting at Unix time start near
// (lat, lon). The same seed gives the same track.
func Simulate(p Profile, start int64, lat, lon float64, seed uint64) []Point {
	r := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
	alt := p.StartAlt
	hdg := r.Float64() * 360
	t := start
	var out []Point
	for _, s := range p.Segments {
		for el := 0; el < s.Seconds; el += SampleEvery {
			dt := float64(SampleEvery)
			hdg = math.Mod(hdg+s.TurnDegS*dt+360, 360)
			alt += s.VRateFpm * dt / 60
			if s.VRateFpm < 0 && alt < s.FloorFt {
				alt = s.FloorFt
			}
			if s.CeilingFt > 0 && alt > s.CeilingFt {
				alt = s.CeilingFt
			}
			if s.Ground {
				alt = 0
			}
			d := s.SpeedKt * dt / 3600 / 60 // degrees of latitude
			lat += d * math.Cos(hdg*math.Pi/180)
			lon += d * math.Sin(hdg*math.Pi/180) / math.Cos(lat*math.Pi/180)
			t += SampleEvery
			// Feed jitter: about ±0.4° track, ±25 ft altitude, ±1 kt speed, a few metres position.
			jt := hdg + r.NormFloat64()*0.4
			pt := Point{
				T:       t,
				Lat:     lat + r.NormFloat64()*0.00002,
				Lon:     lon + r.NormFloat64()*0.00002,
				AltFt:   int(math.Round((alt+r.NormFloat64()*12)/25) * 25),
				SpeedKt: int(math.Round(s.SpeedKt + r.NormFloat64())),
				Track:   int(math.Mod(math.Round(jt)+360, 360)),
				Ground:  s.Ground,
			}
			if s.Ground {
				pt.AltFt = 0
				if s.SpeedKt == 0 {
					pt.SpeedKt = 0
					pt.Lat, pt.Lon = lat, lon
				}
			}
			out = append(out, pt)
		}
	}
	return out
}
