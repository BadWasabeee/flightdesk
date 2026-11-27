package api

import (
	"compress/gzip"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"log/slog"
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- responses ----

var gzipPool = sync.Pool{New: func() any { w, _ := gzip.NewWriterLevel(nil, gzip.DefaultCompression); return w }}

// gzipMin is the smallest body worth compressing.
const gzipMin = 512

// writeBody writes body with the given status and content type, gzip-compressed when the client
// accepts it and the body is big enough.
func writeBody(w http.ResponseWriter, r *http.Request, status int, contentType string, body []byte) {
	h := w.Header()
	h.Set("Content-Type", contentType)
	h.Add("Vary", "Accept-Encoding")
	if len(body) >= gzipMin && acceptsGzip(r) {
		h.Set("Content-Encoding", "gzip")
		h.Del("Content-Length")
		w.WriteHeader(status)
		gz := gzipPool.Get().(*gzip.Writer)
		gz.Reset(w)
		_, _ = gz.Write(body)
		_ = gz.Close()
		gzipPool.Put(gz)
		return
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func acceptsGzip(r *http.Request) bool {
	for _, part := range strings.Split(r.Header.Get("Accept-Encoding"), ",") {
		enc, params, _ := strings.Cut(strings.TrimSpace(part), ";")
		if !strings.EqualFold(strings.TrimSpace(enc), "gzip") {
			continue
		}
		params = strings.ReplaceAll(params, " ", "")
		if v, ok := strings.CutPrefix(params, "q="); ok {
			if q, err := strconv.ParseFloat(v, 64); err == nil && q == 0 {
				return false
			}
		}
		return true
	}
	return false
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, `{"error":"encoding failed"}`, http.StatusInternalServerError)
		return
	}
	writeBody(w, r, status, "application/json", b)
}

func writeRawJSON(w http.ResponseWriter, r *http.Request, status int, body []byte) {
	writeBody(w, r, status, "application/json", body)
}

type apiError struct {
	Error string `json:"error"`
}

func writeError(w http.ResponseWriter, r *http.Request, status int, msg string) {
	writeJSON(w, r, status, apiError{Error: msg})
}

// ---- client identity ----

// clientIP is the caller's address: the TCP peer, or, behind a trusted local reverse proxy, the
// address the proxy reports.
func clientIP(r *http.Request, trustProxy bool) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer := net.ParseIP(host)
	if trustProxy && peer != nil && peer.IsLoopback() {
		if ip := net.ParseIP(strings.TrimSpace(r.Header.Get("X-Real-IP"))); ip != nil {
			return ip.String()
		}
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if ip := net.ParseIP(strings.TrimSpace(parts[len(parts)-1])); ip != nil {
				return ip.String()
			}
		}
	}
	if peer != nil {
		return peer.String()
	}
	return host
}

// ---- rate limiting ----

type bucket struct {
	tokens float64
	last   time.Time
}

// limiter is a per-key token bucket.
type limiter struct {
	mu        sync.Mutex
	rate      float64 // tokens per second
	burst     float64
	buckets   map[string]*bucket
	now       func() time.Time
	lastSweep time.Time
}

func newLimiter(perMinute, burst float64) *limiter {
	return &limiter{rate: perMinute / 60, burst: burst, buckets: map[string]*bucket{}, now: time.Now}
}

// take spends one token for key, or reports how long until one is available.
func (l *limiter) take(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if now.Sub(l.lastSweep) > time.Minute {
		for k, b := range l.buckets {
			if now.Sub(b.last) > 10*time.Minute {
				delete(l.buckets, k)
			}
		}
		l.lastSweep = now
	}
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	b.tokens = math.Min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.rate)
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	return false, time.Duration((1 - b.tokens) / l.rate * float64(time.Second))
}

// blocked reports whether key has no tokens left, without spending one.
func (l *limiter) blocked(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	if !ok {
		return false, 0
	}
	tokens := math.Min(l.burst, b.tokens+l.now().Sub(b.last).Seconds()*l.rate)
	if tokens >= 1 {
		return false, 0
	}
	return true, time.Duration((1 - tokens) / l.rate * float64(time.Second))
}

func retryAfter(w http.ResponseWriter, d time.Duration) {
	w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(max(d.Seconds(), 1)))))
}

// ---- middleware chain ----

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) { s.status = code; s.ResponseWriter.WriteHeader(code) }
func (s *statusWriter) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// common applies to every request: security headers, a tiny body limit, panic recovery and a
// log line (path only: queries carry the device's location and are never logged).
func (s *Server) common(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		sw := &statusWriter{ResponseWriter: w}
		defer func() {
			if p := recover(); p != nil {
				s.log.Error("panic serving request", "path", r.URL.Path, "panic", p)
				if sw.status == 0 {
					writeError(sw, r, http.StatusInternalServerError, "internal error")
				}
			}
			lvl := slog.LevelDebug
			if sw.status >= 500 {
				lvl = slog.LevelWarn
			}
			s.log.Log(r.Context(), lvl, "request", "method", r.Method, "path", r.URL.Path, "status", sw.status,
				"ms", time.Since(start).Milliseconds())
		}()
		next.ServeHTTP(sw, r)
	})
}

// protect enforces the per-IP failed-auth lockout, the bearer token (constant-time) and the
// per-IP request rate.
func (s *Server) protect(next http.Handler) http.Handler {
	want := sha256.Sum256([]byte(s.cfg.Token))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r, s.cfg.TrustProxy)
		if blocked, d := s.authFails.blocked(ip); blocked {
			retryAfter(w, d)
			writeError(w, r, http.StatusTooManyRequests, "too many failed authentication attempts")
			return
		}
		got := ""
		if v := r.Header.Get("Authorization"); len(v) > 7 && strings.EqualFold(v[:7], "bearer ") {
			got = strings.TrimSpace(v[7:])
		}
		sum := sha256.Sum256([]byte(got))
		if got == "" || subtle.ConstantTimeCompare(sum[:], want[:]) != 1 {
			s.authFails.take(ip)
			w.Header().Set("WWW-Authenticate", `Bearer realm="flightdesk"`)
			writeError(w, r, http.StatusUnauthorized, "missing or invalid bearer token")
			return
		}
		if ok, d := s.rate.take(ip); !ok {
			retryAfter(w, d)
			writeError(w, r, http.StatusTooManyRequests, "rate limit exceeded")
			return
		}
		next.ServeHTTP(w, r)
	})
}
