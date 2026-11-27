// Package config loads the server configuration from an env file (KEY=VALUE lines, the same file
// systemd reads with EnvironmentFile=) overlaid with FLIGHTDESK_* environment variables.
package config

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// MinTokenLength is the shortest accepted bearer token.
const MinTokenLength = 32

// Config is the full server configuration.
type Config struct {
	Listen  string // FLIGHTDESK_LISTEN, default 127.0.0.1:8787
	Token   string // FLIGHTDESK_TOKEN (required, >= 32 chars)
	DataDir string // FLIGHTDESK_DATA_DIR, default /var/lib/flightdesk (systemd StateDirectory)

	CenterLat float64 // FLIGHTDESK_CENTER_LAT
	CenterLon float64 // FLIGHTDESK_CENTER_LON
	RadiusNM  int     // FLIGHTDESK_RADIUS_NM, 0 disables the area poller (max 250)

	PollInterval  time.Duration // FLIGHTDESK_POLL_INTERVAL, default 8s (5s-60s)
	WatchInterval time.Duration // FLIGHTDESK_WATCH_INTERVAL, default 45s (30s-300s)
	MaxWatches    int           // FLIGHTDESK_MAX_WATCHES, default 20

	RetainDetailDays int     // FLIGHTDESK_RETAIN_DETAIL_DAYS, default 90
	RetainCoarseDays int     // FLIGHTDESK_RETAIN_COARSE_DAYS, default 730
	RetainAcarsDays  int     // FLIGHTDESK_RETAIN_ACARS_DAYS, default 180
	DiskCapGB        float64 // FLIGHTDESK_DISK_CAP_GB, default 15
	MaintenanceHour  int     // FLIGHTDESK_MAINTENANCE_HOUR (server local time), default 3

	RateLimitPerMin int  // FLIGHTDESK_RATE_LIMIT_PER_MIN per client IP, default 240
	TrustProxy      bool // FLIGHTDESK_TRUST_PROXY: honour X-Real-IP/X-Forwarded-For from loopback, default true
	LogLevel        string
	LogFormat       string // "json" (default) or "text"
	UserAgent       string // FLIGHTDESK_USER_AGENT
}

// AreaEnabled reports whether an area is configured.
func (c Config) AreaEnabled() bool { return c.RadiusNM > 0 }

// DiskCapBytes is the cap in bytes.
func (c Config) DiskCapBytes() int64 { return int64(c.DiskCapGB * (1 << 30)) }

// Defaults returns the default configuration (without a token).
func Defaults() Config {
	return Config{
		Listen:           "127.0.0.1:8787",
		DataDir:          "/var/lib/flightdesk",
		PollInterval:     8 * time.Second,
		WatchInterval:    45 * time.Second,
		MaxWatches:       20,
		RetainDetailDays: 90,
		RetainCoarseDays: 730,
		RetainAcarsDays:  180,
		DiskCapGB:        15,
		MaintenanceHour:  3,
		RateLimitPerMin:  240,
		TrustProxy:       true,
		LogLevel:         "info",
		LogFormat:        "json",
		UserAgent:        "FlightDesk-Server/1 (+https://github.com/BadWasabeee/flightdesk)",
	}
}

// ParseEnvFile reads KEY=VALUE lines; blank lines and # comments are skipped, an optional
// "export " prefix is allowed, and values may be single- or double-quoted.
func ParseEnvFile(r io.Reader) (map[string]string, error) {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	n := 0
	for sc.Scan() {
		n++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("line %d: expected KEY=VALUE", n)
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' && v[len(v)-1] == '"' || v[0] == '\'' && v[len(v)-1] == '\'') {
			v = v[1 : len(v)-1]
		} else if i := strings.Index(v, " #"); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		out[k] = v
	}
	return out, sc.Err()
}

// Load reads the env file at path (optional: "" skips it), overlays FLIGHTDESK_* variables from
// environ, and validates the result.
func Load(path string, environ []string) (Config, error) {
	vals := map[string]string{}
	if path != "" {
		f, err := os.Open(path)
		if err != nil {
			return Config{}, fmt.Errorf("config: %w", err)
		}
		vals, err = ParseEnvFile(f)
		f.Close()
		if err != nil {
			return Config{}, fmt.Errorf("config %s: %w", path, err)
		}
	}
	for _, kv := range environ {
		if k, v, ok := strings.Cut(kv, "="); ok && strings.HasPrefix(k, "FLIGHTDESK_") {
			vals[k] = v
		}
	}
	return FromMap(vals)
}

// FromMap builds and validates a Config from FLIGHTDESK_* keys.
func FromMap(vals map[string]string) (Config, error) {
	c := Defaults()
	var errs []error
	str := func(key string, dst *string) {
		if v, ok := vals[key]; ok && v != "" {
			*dst = v
		}
	}
	integer := func(key string, dst *int) {
		if v, ok := vals[key]; ok && v != "" {
			n, err := strconv.Atoi(v)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s: not an integer: %q", key, v))
				return
			}
			*dst = n
		}
	}
	float := func(key string, dst *float64) {
		if v, ok := vals[key]; ok && v != "" {
			f, err := strconv.ParseFloat(v, 64)
			if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
				errs = append(errs, fmt.Errorf("%s: not a number: %q", key, v))
				return
			}
			*dst = f
		}
	}
	duration := func(key string, dst *time.Duration) {
		if v, ok := vals[key]; ok && v != "" {
			d, err := time.ParseDuration(v)
			if err != nil {
				if n, err2 := strconv.Atoi(v); err2 == nil { // bare seconds
					d, err = time.Duration(n)*time.Second, nil
				}
			}
			if err != nil {
				errs = append(errs, fmt.Errorf("%s: not a duration: %q", key, v))
				return
			}
			*dst = d
		}
	}
	boolean := func(key string, dst *bool) {
		if v, ok := vals[key]; ok && v != "" {
			b, err := strconv.ParseBool(v)
			if err != nil {
				errs = append(errs, fmt.Errorf("%s: not a boolean: %q", key, v))
				return
			}
			*dst = b
		}
	}
	str("FLIGHTDESK_LISTEN", &c.Listen)
	str("FLIGHTDESK_TOKEN", &c.Token)
	str("FLIGHTDESK_DATA_DIR", &c.DataDir)
	float("FLIGHTDESK_CENTER_LAT", &c.CenterLat)
	float("FLIGHTDESK_CENTER_LON", &c.CenterLon)
	integer("FLIGHTDESK_RADIUS_NM", &c.RadiusNM)
	duration("FLIGHTDESK_POLL_INTERVAL", &c.PollInterval)
	duration("FLIGHTDESK_WATCH_INTERVAL", &c.WatchInterval)
	integer("FLIGHTDESK_MAX_WATCHES", &c.MaxWatches)
	integer("FLIGHTDESK_RETAIN_DETAIL_DAYS", &c.RetainDetailDays)
	integer("FLIGHTDESK_RETAIN_COARSE_DAYS", &c.RetainCoarseDays)
	integer("FLIGHTDESK_RETAIN_ACARS_DAYS", &c.RetainAcarsDays)
	float("FLIGHTDESK_DISK_CAP_GB", &c.DiskCapGB)
	integer("FLIGHTDESK_MAINTENANCE_HOUR", &c.MaintenanceHour)
	integer("FLIGHTDESK_RATE_LIMIT_PER_MIN", &c.RateLimitPerMin)
	boolean("FLIGHTDESK_TRUST_PROXY", &c.TrustProxy)
	str("FLIGHTDESK_LOG_LEVEL", &c.LogLevel)
	str("FLIGHTDESK_LOG_FORMAT", &c.LogFormat)
	str("FLIGHTDESK_USER_AGENT", &c.UserAgent)
	if len(errs) > 0 {
		return c, errors.Join(errs...)
	}
	return c, c.Validate()
}

// placeholderTokens are refused even when long enough.
var placeholderTokens = []string{"change", "replace", "example", "your-token", "xxxxxxxx", "00000000"}

// ValidateToken enforces the token rules: at least MinTokenLength printable ASCII characters with
// no whitespace, not a placeholder, and not a single repeated character.
func ValidateToken(t string) error {
	if t == "" {
		return errors.New("FLIGHTDESK_TOKEN is not set; generate one with `flightdesk-server token`")
	}
	if len(t) < MinTokenLength {
		return fmt.Errorf("FLIGHTDESK_TOKEN must be at least %d characters (got %d); generate one with `flightdesk-server token`", MinTokenLength, len(t))
	}
	for i := 0; i < len(t); i++ {
		if t[i] <= ' ' || t[i] > '~' {
			return errors.New("FLIGHTDESK_TOKEN must be printable ASCII without spaces")
		}
	}
	lower := strings.ToLower(t)
	for _, p := range placeholderTokens {
		if strings.Contains(lower, p) {
			return errors.New("FLIGHTDESK_TOKEN looks like a placeholder; generate one with `flightdesk-server token`")
		}
	}
	if strings.Count(t, t[:1]) == len(t) {
		return errors.New("FLIGHTDESK_TOKEN is a repeated character")
	}
	return nil
}

// Validate checks every field's range.
func (c Config) Validate() error {
	var errs []error
	if err := ValidateToken(c.Token); err != nil {
		errs = append(errs, err)
	}
	if _, _, err := net.SplitHostPort(c.Listen); err != nil {
		errs = append(errs, fmt.Errorf("FLIGHTDESK_LISTEN: %w", err))
	}
	if c.DataDir == "" {
		errs = append(errs, errors.New("FLIGHTDESK_DATA_DIR is empty"))
	}
	if c.RadiusNM < 0 || c.RadiusNM > 250 {
		errs = append(errs, errors.New("FLIGHTDESK_RADIUS_NM must be 0 (off) to 250"))
	}
	if c.RadiusNM > 0 && (math.Abs(c.CenterLat) > 90 || math.Abs(c.CenterLon) > 180 || c.CenterLat == 0 && c.CenterLon == 0) {
		errs = append(errs, errors.New("FLIGHTDESK_CENTER_LAT/LON must be set to a valid position when RADIUS_NM > 0"))
	}
	if c.PollInterval < 5*time.Second || c.PollInterval > time.Minute {
		errs = append(errs, errors.New("FLIGHTDESK_POLL_INTERVAL must be between 5s and 60s"))
	}
	if c.WatchInterval < 30*time.Second || c.WatchInterval > 5*time.Minute {
		errs = append(errs, errors.New("FLIGHTDESK_WATCH_INTERVAL must be between 30s and 5m"))
	}
	if c.MaxWatches < 0 || c.MaxWatches > 100 {
		errs = append(errs, errors.New("FLIGHTDESK_MAX_WATCHES must be 0 to 100"))
	}
	if c.RetainDetailDays < 1 || c.RetainCoarseDays < c.RetainDetailDays || c.RetainAcarsDays < 1 {
		errs = append(errs, errors.New("retention: DETAIL_DAYS >= 1, COARSE_DAYS >= DETAIL_DAYS, ACARS_DAYS >= 1"))
	}
	if c.DiskCapGB < 0.1 {
		errs = append(errs, errors.New("FLIGHTDESK_DISK_CAP_GB must be at least 0.1"))
	}
	if c.MaintenanceHour < 0 || c.MaintenanceHour > 23 {
		errs = append(errs, errors.New("FLIGHTDESK_MAINTENANCE_HOUR must be 0-23"))
	}
	if c.RateLimitPerMin < 10 || c.RateLimitPerMin > 100000 {
		errs = append(errs, errors.New("FLIGHTDESK_RATE_LIMIT_PER_MIN must be 10-100000"))
	}
	switch c.LogFormat {
	case "json", "text":
	default:
		errs = append(errs, errors.New("FLIGHTDESK_LOG_FORMAT must be json or text"))
	}
	return errors.Join(errs...)
}

// NewToken returns a random 256-bit token as 64 hex characters.
func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// ListenIsLoopback reports whether the listen address is loopback-only.
func (c Config) ListenIsLoopback() bool {
	host, _, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
