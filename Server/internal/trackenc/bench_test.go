package trackenc

import (
	"encoding/binary"
	"testing"
)

func benchPoints() []Point {
	return DefaultSimplifier.Simplify(Simulate(Arrival, 1_790_000_000, 42, -88, 11))
}

func BenchmarkEncodeVarintDelta(b *testing.B) {
	pts := benchPoints()
	var size int
	b.ReportAllocs()
	for b.Loop() {
		blob, _ := Encode(pts[0].T, pts)
		size = len(blob)
	}
	b.ReportMetric(float64(size)/float64(len(pts)), "B/point")
}

func BenchmarkDecodeVarintDelta(b *testing.B) {
	pts := benchPoints()
	blob, _ := Encode(pts[0].T, pts)
	b.ReportAllocs()
	for b.Loop() {
		if _, err := Decode(pts[0].T, blob); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(len(blob))/float64(len(pts)), "B/point")
}

// BenchmarkEncodeFixedWidth is the comparison point: the same quantisation stored as fixed-width
// fields (int32 time offset, int32 lat, int32 lon, int16 alt, uint16 speed, uint16 track, flags).
func BenchmarkEncodeFixedWidth(b *testing.B) {
	pts := benchPoints()
	const width = 4 + 4 + 4 + 2 + 2 + 2 + 1
	var size int
	b.ReportAllocs()
	for b.Loop() {
		out := make([]byte, 0, len(pts)*width)
		for _, p := range pts {
			q := quantise(p)
			out = binary.LittleEndian.AppendUint32(out, uint32(q.t-pts[0].T))
			out = binary.LittleEndian.AppendUint32(out, uint32(int32(q.lat)))
			out = binary.LittleEndian.AppendUint32(out, uint32(int32(q.lon)))
			out = binary.LittleEndian.AppendUint16(out, uint16(int16(q.alt)))
			out = binary.LittleEndian.AppendUint16(out, uint16(q.speed))
			out = binary.LittleEndian.AppendUint16(out, uint16(q.track))
			flag := byte(0)
			if q.ground {
				flag = 1
			}
			out = append(out, flag)
		}
		size = len(out)
	}
	b.ReportMetric(float64(size)/float64(len(pts)), "B/point")
}

func BenchmarkSimplify(b *testing.B) {
	pts := Simulate(Arrival, 1_790_000_000, 42, -88, 11)
	b.ReportAllocs()
	for b.Loop() {
		DefaultSimplifier.Simplify(pts)
	}
}
