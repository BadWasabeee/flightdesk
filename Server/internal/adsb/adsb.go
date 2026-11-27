// Package adsb parses readsb-style JSON (adsb.fi, adsb.lol) and produces the Flight shape the
// FlightDesk apps use.
package adsb

import (
	"bytes"
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/geo"
)

// Altitude is readsb's alt_baro: a number of feet or the string "ground".
type Altitude struct {
	Valid  bool
	Ground bool
	Feet   int
}

// UnmarshalJSON accepts a number or "ground"; anything else leaves the altitude invalid.
func (a *Altitude) UnmarshalJSON(b []byte) error {
	*a = Altitude{}
	b = bytes.TrimSpace(b)
	if len(b) == 0 || string(b) == "null" {
		return nil
	}
	if b[0] == '"' {
		var s string
		if json.Unmarshal(b, &s) == nil && s == "ground" {
			*a = Altitude{Valid: true, Ground: true}
		}
		return nil
	}
	f, err := strconv.ParseFloat(string(b), 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return nil
	}
	*a = Altitude{Valid: true, Feet: int(f)}
	return nil
}

// FlexInt decodes a number or a numeric string (readsb sends "year" as "2019").
type FlexInt int

// UnmarshalJSON never fails, so one odd field can't drop a record.
func (v *FlexInt) UnmarshalJSON(b []byte) error {
	*v = 0
	s := strings.Trim(strings.TrimSpace(string(b)), `"`)
	if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
		*v = FlexInt(n)
	}
	return nil
}

// Aircraft is one readsb record. Only the fields the server uses are decoded.
type Aircraft struct {
	Hex          string   `json:"hex"`
	Flight       string   `json:"flight"`
	R            string   `json:"r"`
	T            string   `json:"t"`
	Desc         string   `json:"desc"`
	OwnOp        string   `json:"ownOp"`
	Year         FlexInt  `json:"year"`
	AltBaro      Altitude `json:"alt_baro"`
	GS           *float64 `json:"gs"`
	Track        *float64 `json:"track"`
	TrueHeading  *float64 `json:"true_heading"`
	BaroRate     *float64 `json:"baro_rate"`
	GeomRate     *float64 `json:"geom_rate"`
	Squawk       string   `json:"squawk"`
	Category     string   `json:"category"`
	Lat          *float64 `json:"lat"`
	Lon          *float64 `json:"lon"`
	SeenPos      *float64 `json:"seen_pos"`
	NavQNH       *float64 `json:"nav_qnh"`
	LastPosition *struct {
		Lat     float64  `json:"lat"`
		Lon     float64  `json:"lon"`
		SeenPos *float64 `json:"seen_pos"`
	} `json:"lastPosition"`
}

// Response is a readsb response. adsb.fi's area query names the list "aircraft"; adsb.lol and
// adsb.fi's hex query name it "ac".
type Response struct {
	Now      float64    `json:"now"` // seconds (adsb.fi) or milliseconds (adsb.lol)
	Aircraft []Aircraft `json:"aircraft"`
	AC       []Aircraft `json:"ac"`
}

// List returns the aircraft whichever key carried them.
func (r *Response) List() []Aircraft {
	if len(r.Aircraft) > 0 {
		return r.Aircraft
	}
	return r.AC
}

// Time is the response's timestamp, or fallback when absent or implausible.
func (r *Response) Time(fallback time.Time) time.Time {
	now := r.Now
	if now > 1e12 { // milliseconds
		now /= 1000
	}
	if now < 1e9 {
		return fallback
	}
	t := time.Unix(0, int64(now*1e9))
	if d := t.Sub(fallback); d > 10*time.Minute || d < -10*time.Minute {
		return fallback
	}
	return t
}

// Parse decodes a readsb body.
func Parse(body []byte) (*Response, error) {
	var r Response
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Flight mirrors the Swift app's `Flight` (Shared/FlightCore.swift) field for field, so the apps
// can decode it with their existing Codable model (unknown keys are ignored by JSONDecoder). The
// fields after Squawk are server extras the Swift model may adopt later.
type Flight struct {
	ID           string   `json:"id"`       // lowercase ICAO hex ("~" prefix for non-ICAO addresses)
	Callsign     string   `json:"callsign"` // trimmed; may be empty
	Reg          string   `json:"reg"`      // registration, else the hex uppercased
	TypeCode     string   `json:"typeCode"` // ICAO type designator; may be empty
	Altitude     int      `json:"altitude"` // barometric feet; 0 on the ground
	VerticalRate float64  `json:"verticalRate"`
	Speed        float64  `json:"speed"`           // ground speed, knots
	Track        *float64 `json:"track,omitempty"` // degrees true
	Lat          float64  `json:"lat"`
	Lon          float64  `json:"lon"`
	Distance     float64  `json:"distance"` // nm from the request's lat/lon
	Bearing      float64  `json:"bearing"`  // degrees from the request's lat/lon to the aircraft
	Squawk       string   `json:"squawk,omitempty"`

	OnGround     bool    `json:"onGround"`
	PositionTime float64 `json:"positionTime"` // Unix seconds the position was received
	Desc         string  `json:"desc,omitempty"`
	OwnOp        string  `json:"ownOp,omitempty"`
	Year         int     `json:"year,omitempty"`
	NavQNH       float64 `json:"navQnh,omitempty"`
	Category     string  `json:"category,omitempty"`
}

// HasPosition is a guard used throughout: a usable, finite position.
func validLatLon(lat, lon float64) bool {
	return !math.IsNaN(lat) && !math.IsNaN(lon) && math.Abs(lat) <= 90 && math.Abs(lon) <= 180
}

// MaxPositionAge drops records whose position is older than this (readsb keeps aircraft for a
// minute after their last position).
const MaxPositionAge = 60.0

// ToFlight converts a record, or returns false when it has no recent position. Distance and
// bearing are left zero; see Flight.Locate.
func (a *Aircraft) ToFlight(now time.Time) (Flight, bool) {
	hex := strings.ToLower(strings.TrimSpace(a.Hex))
	if !ValidFeedHex(hex) {
		return Flight{}, false
	}
	var lat, lon, age float64
	switch {
	case a.Lat != nil && a.Lon != nil:
		lat, lon = *a.Lat, *a.Lon
		if a.SeenPos != nil {
			age = *a.SeenPos
		}
	case a.LastPosition != nil:
		lat, lon = a.LastPosition.Lat, a.LastPosition.Lon
		if a.LastPosition.SeenPos != nil {
			age = *a.LastPosition.SeenPos
		}
	default:
		return Flight{}, false
	}
	if !validLatLon(lat, lon) || age > MaxPositionAge || age < 0 {
		return Flight{}, false
	}
	f := Flight{
		ID:           hex,
		Callsign:     strings.TrimSpace(a.Flight),
		Reg:          strings.TrimSpace(a.R),
		TypeCode:     strings.TrimSpace(a.T),
		Lat:          lat,
		Lon:          lon,
		Squawk:       strings.TrimSpace(a.Squawk),
		PositionTime: round(float64(now.UnixMilli())/1000-age, 3),
		Desc:         strings.TrimSpace(a.Desc),
		OwnOp:        strings.TrimSpace(a.OwnOp),
		Category:     strings.TrimSpace(a.Category),
	}
	if f.Reg == "" {
		f.Reg = strings.ToUpper(strings.TrimPrefix(hex, "~"))
	}
	if a.AltBaro.Valid {
		f.OnGround = a.AltBaro.Ground
		f.Altitude = a.AltBaro.Feet
	}
	switch {
	case a.BaroRate != nil:
		f.VerticalRate = *a.BaroRate
	case a.GeomRate != nil:
		f.VerticalRate = *a.GeomRate
	}
	if a.GS != nil {
		f.Speed = *a.GS
	}
	switch {
	case a.Track != nil:
		t := *a.Track
		f.Track = &t
	case a.TrueHeading != nil:
		t := *a.TrueHeading
		f.Track = &t
	}
	if y := int(a.Year); y >= 1900 && y <= 2100 {
		f.Year = y
	}
	if a.NavQNH != nil && *a.NavQNH >= 900 && *a.NavQNH <= 1100 {
		f.NavQNH = *a.NavQNH
	}
	return f, true
}

// Flights converts every usable record in a response.
func Flights(r *Response, now time.Time) []Flight {
	list := r.List()
	out := make([]Flight, 0, len(list))
	seen := make(map[string]bool, len(list))
	for i := range list {
		if f, ok := list[i].ToFlight(now); ok && !seen[f.ID] {
			seen[f.ID] = true
			out = append(out, f)
		}
	}
	return out
}

// Locate returns f with distance and bearing from (lat, lon).
func (f Flight) Locate(lat, lon float64) Flight {
	f.Distance = round(geo.DistanceNM(lat, lon, f.Lat, f.Lon), 3)
	f.Bearing = round(geo.BearingDeg(lat, lon, f.Lat, f.Lon), 1)
	return f
}

// ValidFeedHex accepts a 24-bit address as feeds report it: six hex digits, lowercase, with an
// optional "~" prefix marking a non-ICAO (TIS-B) address.
func ValidFeedHex(s string) bool {
	s = strings.TrimPrefix(s, "~")
	if len(s) != 6 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func round(v float64, places int) float64 {
	p := math.Pow10(places)
	return math.Round(v*p) / p
}
