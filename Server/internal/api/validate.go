package api

import (
	"math"
	"strconv"
	"strings"
)

// Input validation. Every path and query value is checked here before it is used in a cache
// key, a database query or an upstream URL.

func isHexDigit(c byte) bool   { return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' }
func isUpperAlnum(c byte) bool { return c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' }

// ValidHex returns the lowercase ICAO 24-bit address: exactly 6 hex digits. With allowNonICAO,
// a leading "~" (readsb's marker for non-ICAO/TIS-B addresses) is also accepted.
func ValidHex(raw string, allowNonICAO bool) (string, bool) {
	s := strings.ToLower(raw)
	body := s
	if allowNonICAO && strings.HasPrefix(s, "~") {
		body = s[1:]
	}
	if len(body) != 6 {
		return "", false
	}
	for i := 0; i < len(body); i++ {
		if !isHexDigit(body[i]) {
			return "", false
		}
	}
	return s, true
}

// ValidCallsign returns the uppercase callsign when it matches ^[A-Z0-9]{2,8}$.
func ValidCallsign(raw string) (string, bool) {
	s := strings.ToUpper(raw)
	if len(s) < 2 || len(s) > 8 {
		return "", false
	}
	for i := 0; i < len(s); i++ {
		if !isUpperAlnum(s[i]) {
			return "", false
		}
	}
	return s, true
}

// ValidICAO returns the uppercase 4-character airport code (^[A-Z0-9]{4}$).
func ValidICAO(raw string) (string, bool) {
	s := strings.ToUpper(raw)
	if len(s) != 4 {
		return "", false
	}
	for i := 0; i < len(s); i++ {
		if !isUpperAlnum(s[i]) {
			return "", false
		}
	}
	return s, true
}

// ValidReg returns the uppercase registration: 2-10 of [A-Z0-9-], with at least one letter or
// digit and no leading/trailing hyphen.
func ValidReg(raw string) (string, bool) {
	s := strings.ToUpper(raw)
	if len(s) < 2 || len(s) > 10 || s[0] == '-' || s[len(s)-1] == '-' {
		return "", false
	}
	for i := 0; i < len(s); i++ {
		if !isUpperAlnum(s[i]) && s[i] != '-' {
			return "", false
		}
	}
	return s, true
}

func parseFloat(raw string) (float64, bool) {
	if raw == "" || len(raw) > 32 {
		return 0, false
	}
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0, false
	}
	return f, true
}

// ValidLat parses a latitude in [-90, 90].
func ValidLat(raw string) (float64, bool) {
	f, ok := parseFloat(raw)
	return f, ok && f >= -90 && f <= 90
}

// ValidLon parses a longitude in [-180, 180].
func ValidLon(raw string) (float64, bool) {
	f, ok := parseFloat(raw)
	return f, ok && f >= -180 && f <= 180
}

// ValidRadius parses a radius in nautical miles in [1, 250].
func ValidRadius(raw string) (float64, bool) {
	f, ok := parseFloat(raw)
	return f, ok && f >= 1 && f <= 250
}

// parseInt parses an integer in [lo, hi]; empty gives def.
func parseInt(raw string, def, lo, hi int64) (int64, bool) {
	if raw == "" {
		return def, true
	}
	if len(raw) > 20 {
		return 0, false
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	return n, err == nil && n >= lo && n <= hi
}

// ParseICAOList parses "KMKE,KORD" into at most max unique valid codes.
func ParseICAOList(raw string, max int) ([]string, bool) {
	if raw == "" || len(raw) > max*5+5 {
		return nil, false
	}
	var out []string
	seen := map[string]bool{}
	for _, part := range strings.Split(raw, ",") {
		code, ok := ValidICAO(strings.TrimSpace(part))
		if !ok {
			return nil, false
		}
		if !seen[code] {
			seen[code] = true
			out = append(out, code)
		}
	}
	return out, len(out) > 0 && len(out) <= max
}
