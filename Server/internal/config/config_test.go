package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const goodToken = "3f9a1c7e5b2d4f6a8c0e1b3d5f7a9c2e4b6d8f0a1c3e5b7d9f2a4c6e8b0d1f3a"

func TestLoadFileAndEnvOverlay(t *testing.T) {
	path := filepath.Join(t.TempDir(), "flightdesk.env")
	content := `# comment
FLIGHTDESK_TOKEN="` + goodToken + `"
export FLIGHTDESK_CENTER_LAT=41.88
FLIGHTDESK_CENTER_LON=-87.63   # trailing comment
FLIGHTDESK_RADIUS_NM=100
FLIGHTDESK_POLL_INTERVAL=10s
FLIGHTDESK_WATCH_INTERVAL=60
`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path, []string{"FLIGHTDESK_RADIUS_NM=150", "HOME=/x"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Token != goodToken || c.CenterLat != 41.88 || c.CenterLon != -87.63 || c.RadiusNM != 150 ||
		c.PollInterval != 10*time.Second || c.WatchInterval != time.Minute || c.Listen != "127.0.0.1:8787" {
		t.Fatalf("%+v", c)
	}
	if !c.ListenIsLoopback() || c.DiskCapBytes() != 15<<30 {
		t.Fatal("defaults")
	}
}

func TestTokenRules(t *testing.T) {
	cases := []struct {
		token string
		ok    bool
	}{
		{"", false},
		{"short", false},
		{strings.Repeat("a", 31), false},
		{strings.Repeat("a", 40), false},
		{"change-me-change-me-change-me-change-me", false},
		{"0000000000000000000000000000000000000000", false},
		{"has space has space has space has space x", false},
		{goodToken, true},
		{"Zq8-v2_Lm9.Pw4~Rt7Kx3Ny6Bh1Jc5Gd0Fs", true},
	}
	for _, c := range cases {
		if err := ValidateToken(c.token); (err == nil) != c.ok {
			t.Errorf("%q: err=%v, want ok=%v", c.token, err, c.ok)
		}
	}
}

func TestRefusesToStartWithoutToken(t *testing.T) {
	if _, err := FromMap(map[string]string{}); err == nil || !strings.Contains(err.Error(), "FLIGHTDESK_TOKEN") {
		t.Fatalf("got %v", err)
	}
}

func TestRangeValidation(t *testing.T) {
	base := map[string]string{"FLIGHTDESK_TOKEN": goodToken}
	bad := []map[string]string{
		{"FLIGHTDESK_RADIUS_NM": "251", "FLIGHTDESK_CENTER_LAT": "43", "FLIGHTDESK_CENTER_LON": "-88"},
		{"FLIGHTDESK_RADIUS_NM": "50"}, // no centre
		{"FLIGHTDESK_RADIUS_NM": "50", "FLIGHTDESK_CENTER_LAT": "91", "FLIGHTDESK_CENTER_LON": "0"},
		{"FLIGHTDESK_POLL_INTERVAL": "1s"},
		{"FLIGHTDESK_WATCH_INTERVAL": "5s"},
		{"FLIGHTDESK_LISTEN": "nonsense"},
		{"FLIGHTDESK_RETAIN_DETAIL_DAYS": "100", "FLIGHTDESK_RETAIN_COARSE_DAYS": "50"},
		{"FLIGHTDESK_DISK_CAP_GB": "0"},
		{"FLIGHTDESK_RADIUS_NM": "abc"},
		{"FLIGHTDESK_CENTER_LAT": "NaN"},
	}
	for _, m := range bad {
		vals := map[string]string{}
		for k, v := range base {
			vals[k] = v
		}
		for k, v := range m {
			vals[k] = v
		}
		if _, err := FromMap(vals); err == nil {
			t.Errorf("%v accepted", m)
		}
	}
}

func TestNewToken(t *testing.T) {
	a, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := NewToken()
	if len(a) != 64 || a == b || ValidateToken(a) != nil {
		t.Fatalf("token %q", a)
	}
}
