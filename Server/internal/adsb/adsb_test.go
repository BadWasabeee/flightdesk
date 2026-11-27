package adsb

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// A trimmed real adsb.fi area response (southeast Wisconsin).
const sampleFi = `{"now":1795790162.001,"resultCount":3,"ptime":0.024,"aircraft":[
{"hex":"a1cfb7","type":"adsr_icao","flight":"N2159Q  ","r":"N2159Q","t":"P28A","desc":"PIPER PA-28-140/150/160/180","ownOp":"WISCONSIN AVIATION-FOUR LAKES INC","year":"1979","alt_baro":1400,"alt_geom":1125,"gs":69.3,"track":315.0,"baro_rate":1216,"squawk":"1200","category":"A1","lat":43.146606,"lon":-89.339671,"seen_pos":0.22,"dst":47.385,"dir":275.2},
{"hex":"a4b2c1","flight":"SWA123  ","t":"B38M","alt_baro":"ground","gs":3.1,"true_heading":91.5,"lat":42.95,"lon":-87.9,"seen_pos":1.5},
{"hex":"~2a0001","alt_baro":5000,"lat":43.0,"lon":-88.0,"seen_pos":120},
{"hex":"zzzzzz","alt_baro":5000,"lat":43.0,"lon":-88.0},
{"hex":"a00001","alt_baro":5000}
]}`

func TestParseAdsbFi(t *testing.T) {
	r, err := Parse([]byte(sampleFi))
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1795790162, 0)
	fl := Flights(r, now)
	if len(fl) != 2 {
		t.Fatalf("got %d flights, want 2 (stale, bad hex and position-less dropped)", len(fl))
	}
	a := fl[0]
	if a.ID != "a1cfb7" || a.Callsign != "N2159Q" || a.TypeCode != "P28A" || a.Altitude != 1400 ||
		a.VerticalRate != 1216 || a.Speed != 69.3 || a.Track == nil || *a.Track != 315 || a.Year != 1979 || a.OnGround {
		t.Fatalf("unexpected %+v", a)
	}
	b := fl[1]
	if !b.OnGround || b.Altitude != 0 || b.Reg != "A4B2C1" || b.Track == nil || *b.Track != 91.5 {
		t.Fatalf("unexpected ground record %+v", b)
	}
	if got := r.Time(now.Add(time.Second)); got.Unix() != 1795790162 {
		t.Fatalf("Time = %v", got)
	}
}

func TestParseAdsbLolKeyAndMillis(t *testing.T) {
	r, err := Parse([]byte(`{"now":1795790162001,"ac":[{"hex":"ABCDEF","alt_baro":3000,"lat":1,"lon":2}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(r.List()) != 1 {
		t.Fatal("ac list not read")
	}
	now := time.Unix(1795790162, 0)
	if r.Time(now).Unix() != 1795790162 {
		t.Fatal("millisecond now not handled")
	}
	if f := Flights(r, now); len(f) != 1 || f[0].ID != "abcdef" {
		t.Fatalf("hex not lowercased: %+v", f)
	}
}

func TestFlightJSONMatchesSwiftKeys(t *testing.T) {
	r, _ := Parse([]byte(sampleFi))
	f := Flights(r, time.Unix(1795790162, 0))[0].Locate(43.08, -88.26)
	b, _ := json.Marshal(f)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	for _, k := range []string{"id", "callsign", "reg", "typeCode", "altitude", "verticalRate", "speed", "track", "lat", "lon", "distance", "bearing", "squawk"} {
		if _, ok := m[k]; !ok {
			t.Errorf("missing Swift key %q in %s", k, b)
		}
	}
	if d := m["distance"].(float64); d < 47 || d > 48 {
		t.Errorf("distance %v, want ~47.4 (adsb.fi said 47.385)", d)
	}
	if !strings.Contains(string(b), `"bearing":275.`) {
		t.Errorf("bearing wrong: %s", b)
	}
}

func TestAltitudeOddValues(t *testing.T) {
	for _, in := range []string{`null`, `"unknown"`, `[1]`, `{}`} {
		var a Altitude
		if err := json.Unmarshal([]byte(in), &a); err != nil || a.Valid {
			t.Errorf("%s: %+v %v", in, a, err)
		}
	}
}
