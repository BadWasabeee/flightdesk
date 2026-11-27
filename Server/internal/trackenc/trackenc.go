// Package trackenc stores flight tracks compactly.
//
// A track is a sequence of Points belonging to one flight leg. Points are quantised (lat/lon to
// 1e-5 degree, about 1.1 m; altitude to 25 ft; speed to 1 kt; track to 1 degree) and then
// delta-encoded against the previous point as varints, so a typical stored point costs 5 to 10
// bytes instead of the 30+ of a row per point. Times are seconds from the leg's start time, which
// is kept outside the blob (in the legs table).
//
// Blob layout:
//
//	byte 0      format version (1)
//	then per point:
//	  uvarint   dt<<2 | noTrack<<1 | ground
//	                              dt: seconds since the previous point (first point: since the leg base)
//	  varint    Δlat              1e-5 degree units, zig-zag
//	  varint    Δlon              1e-5 degree units, zig-zag
//	  varint    Δalt              25 ft units, zig-zag
//	  varint    Δspeed            knots, zig-zag
//	  varint    Δtrack            degrees from the last known track, folded to [-180, 179];
//	                              omitted when noTrack is set
//
// Blobs are append-only: a later chunk produced by an Encoder resumed from the existing blob can
// simply be concatenated onto it.
package trackenc

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

// Version is the blob format version written as the first byte.
const Version = 1

// TrackUnknown marks a point without a reported track.
const TrackUnknown = 360

// Point is one track position.
type Point struct {
	T       int64   // Unix seconds
	Lat     float64 // degrees
	Lon     float64 // degrees
	AltFt   int     // barometric altitude in feet (0 on the ground)
	SpeedKt int     // ground speed in knots
	Track   int     // true track in whole degrees [0, 359], or TrackUnknown
	Ground  bool
}

// HasTrack reports whether the point carries a track.
func (p Point) HasTrack() bool { return p.Track >= 0 && p.Track < 360 }

// quantised is a Point as stored.
type quantised struct {
	t      int64
	lat    int64
	lon    int64
	alt    int64
	speed  int64
	track  int64
	ground bool
}

const (
	minAlt25 = math.MinInt16
	maxAlt25 = math.MaxInt16 // 819,175 ft; altitude fits an int16 in 25 ft steps
	maxSpeed = 4000
)

func quantise(p Point) quantised {
	alt := int64(math.Round(float64(p.AltFt) / 25))
	alt = min(max(alt, minAlt25), maxAlt25)
	speed := int64(min(max(p.SpeedKt, 0), maxSpeed))
	track := int64(TrackUnknown)
	if p.HasTrack() {
		track = int64(p.Track)
	}
	return quantised{
		t:      p.T,
		lat:    int64(math.Round(p.Lat * 1e5)),
		lon:    int64(math.Round(p.Lon * 1e5)),
		alt:    alt,
		speed:  speed,
		track:  track,
		ground: p.Ground,
	}
}

func (q quantised) point() Point {
	return Point{
		T:       q.t,
		Lat:     float64(q.lat) / 1e5,
		Lon:     float64(q.lon) / 1e5,
		AltFt:   int(q.alt * 25),
		SpeedKt: int(q.speed),
		Track:   int(q.track),
		Ground:  q.ground,
	}
}

// Quantise returns p as it will read back after a round trip through the encoding.
func Quantise(p Point) Point { return quantise(p).point() }

// trackDelta folds cur-prev modulo 360 into [-180, 179].
func trackDelta(prev, cur int64) int64 {
	d := ((cur-prev)%360 + 360) % 360
	if d >= 180 {
		d -= 360
	}
	return d
}

func trackApply(prev, d int64) int64 { return ((prev+d)%360 + 360) % 360 }

// ErrOutOfOrder is returned when a point is older than the previous one.
var ErrOutOfOrder = errors.New("trackenc: point older than previous point")

// ErrCorrupt is returned for a malformed blob.
var ErrCorrupt = errors.New("trackenc: corrupt track blob")

// Encoder appends points to a track blob. The zero value is not usable; use NewEncoder or Resume.
type Encoder struct {
	base int64
	prev quantised // prev.track is the last known track (0 before any)
	last quantised // the last point exactly as encoded
	n    int
}

// NewEncoder starts an empty track whose times are relative to base (Unix seconds).
func NewEncoder(base int64) *Encoder {
	return &Encoder{base: base, prev: quantised{t: base}}
}

// Resume returns an Encoder positioned after the last point of an existing blob, so new chunks
// can be appended to it, together with the blob's last point (ok false for an empty blob).
func Resume(base int64, blob []byte) (enc *Encoder, last Point, ok bool, err error) {
	enc = NewEncoder(base)
	err = walk(base, blob, func(q quantised) { enc.observe(q); enc.n++ })
	if err != nil {
		return nil, Point{}, false, err
	}
	if enc.n == 0 {
		return enc, Point{}, false, nil
	}
	return enc, enc.last.point(), true, nil
}

// Len is the number of points encoded so far (including any resumed ones).
func (e *Encoder) Len() int { return e.n }

// Base is the leg start time the encoder's offsets are relative to.
func (e *Encoder) Base() int64 { return e.base }

// Append encodes p onto dst and returns the extended slice. The first point ever encoded also
// writes the version byte, so dst for the first call should be the (empty) start of the blob.
func (e *Encoder) Append(dst []byte, p Point) ([]byte, error) {
	q := quantise(p)
	if q.t < e.prev.t {
		return dst, ErrOutOfOrder
	}
	if q.t-e.base > math.MaxInt32 {
		return dst, fmt.Errorf("trackenc: point %ds after leg start exceeds int32 range", q.t-e.base)
	}
	if e.n == 0 {
		dst = append(dst, Version)
	}
	head := uint64(q.t-e.prev.t) << 2
	if q.track == TrackUnknown {
		head |= 2
	}
	if q.ground {
		head |= 1
	}
	dst = binary.AppendUvarint(dst, head)
	dst = binary.AppendVarint(dst, q.lat-e.prev.lat)
	dst = binary.AppendVarint(dst, q.lon-e.prev.lon)
	dst = binary.AppendVarint(dst, q.alt-e.prev.alt)
	dst = binary.AppendVarint(dst, q.speed-e.prev.speed)
	if q.track != TrackUnknown {
		dst = binary.AppendVarint(dst, trackDelta(e.prev.track, q.track))
	}
	e.observe(q)
	e.n++
	return dst, nil
}

// observe advances the delta state past q.
func (e *Encoder) observe(q quantised) {
	e.last = q
	known := e.prev.track
	e.prev = q
	if q.track == TrackUnknown {
		e.prev.track = known
	}
}

// Encode is a convenience that encodes a whole track.
func Encode(base int64, pts []Point) ([]byte, error) {
	enc := NewEncoder(base)
	out := make([]byte, 0, 1+len(pts)*8)
	var err error
	for _, p := range pts {
		if out, err = enc.Append(out, p); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// Decode returns every point in blob.
func Decode(base int64, blob []byte) ([]Point, error) {
	out := make([]Point, 0, len(blob)/6)
	err := walk(base, blob, func(q quantised) { out = append(out, q.point()) })
	return out, err
}

// Count returns the number of points in blob without allocating them.
func Count(blob []byte) (int, error) {
	n := 0
	err := walk(0, blob, func(quantised) { n++ })
	return n, err
}

func walk(base int64, blob []byte, fn func(quantised)) error {
	if len(blob) == 0 {
		return nil
	}
	if blob[0] != Version {
		return fmt.Errorf("%w: unknown version %d", ErrCorrupt, blob[0])
	}
	b := blob[1:]
	prev := quantised{t: base} // prev.track: last known track
	for len(b) > 0 {
		head, n := binary.Uvarint(b)
		if n <= 0 {
			return ErrCorrupt
		}
		b = b[n:]
		noTrack := head&2 != 0
		fields := 5
		if noTrack {
			fields = 4
		}
		var d [5]int64
		for i := range fields {
			v, n := binary.Varint(b)
			if n <= 0 {
				return ErrCorrupt
			}
			d[i] = v
			b = b[n:]
		}
		q := quantised{
			t:      prev.t + int64(head>>2),
			ground: head&1 == 1,
			lat:    prev.lat + d[0],
			lon:    prev.lon + d[1],
			alt:    prev.alt + d[2],
			speed:  prev.speed + d[3],
			track:  TrackUnknown,
		}
		if !noTrack {
			q.track = trackApply(prev.track, d[4])
		}
		fn(q)
		known := prev.track
		prev = q
		if noTrack {
			prev.track = known
		}
	}
	return nil
}
