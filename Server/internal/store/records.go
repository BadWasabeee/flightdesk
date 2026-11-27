package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
)

// Sighting is one airframe in the spotting log. Its JSON mirrors the Swift app's LogEntry
// (Shared/SpottingLog.swift); times are Unix seconds and closestNM is from the area centre.
type Sighting struct {
	Hex          string   `json:"hex"`
	Registration string   `json:"registration"`
	TypeCode     string   `json:"typeCode"`
	OperatorName string   `json:"operatorName"`
	AirlineICAO  string   `json:"airlineICAO,omitempty"`
	FirstSeen    int64    `json:"firstSeen"`
	LastSeen     int64    `json:"lastSeen"`
	Sightings    int      `json:"sightings"`
	Callsigns    []string `json:"callsigns"`
	ClosestNM    float64  `json:"closestNM"`
	ClosestAt    int64    `json:"closestAt"`
	MaxAltitude  int      `json:"maxAltitude"`
	Routes       []string `json:"routes"`
}

func splitList(s string) []string {
	if s == "" {
		return []string{}
	}
	return strings.Split(s, ",")
}

func upsertSighting(ctx context.Context, tx *sql.Tx, sg *Sighting) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO sightings(hex, registration, type_code, operator, airline_icao, first_seen, last_seen, visits, callsigns, closest_nm, closest_at, max_alt, routes)
		VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(hex) DO UPDATE SET registration=excluded.registration, type_code=excluded.type_code, operator=excluded.operator,
			airline_icao=excluded.airline_icao, first_seen=min(first_seen, excluded.first_seen), last_seen=max(last_seen, excluded.last_seen),
			visits=excluded.visits, callsigns=excluded.callsigns, closest_nm=excluded.closest_nm, closest_at=excluded.closest_at,
			max_alt=excluded.max_alt, routes=excluded.routes`,
		sg.Hex, sg.Registration, sg.TypeCode, sg.OperatorName, sg.AirlineICAO, sg.FirstSeen, sg.LastSeen, sg.Sightings,
		strings.Join(sg.Callsigns, ","), sg.ClosestNM, sg.ClosestAt, sg.MaxAltitude, strings.Join(sg.Routes, ","))
	return err
}

const sightingCols = "hex, registration, type_code, operator, airline_icao, first_seen, last_seen, visits, callsigns, closest_nm, closest_at, max_alt, routes"

func scanSighting(sc interface{ Scan(...any) error }) (*Sighting, error) {
	var sg Sighting
	var cs, routes string
	if err := sc.Scan(&sg.Hex, &sg.Registration, &sg.TypeCode, &sg.OperatorName, &sg.AirlineICAO, &sg.FirstSeen, &sg.LastSeen,
		&sg.Sightings, &cs, &sg.ClosestNM, &sg.ClosestAt, &sg.MaxAltitude, &routes); err != nil {
		return nil, err
	}
	sg.Callsigns, sg.Routes = splitList(cs), splitList(routes)
	return &sg, nil
}

// Sighting returns one log entry (nil if absent).
func (s *Store) Sighting(ctx context.Context, hex string) (*Sighting, error) {
	sg, err := scanSighting(s.r.QueryRowContext(ctx, "SELECT "+sightingCols+" FROM sightings WHERE hex = ?", hex))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return sg, err
}

// SightingsSince pages through entries changed since a cursor, oldest change first: entries with
// (last_seen, hex) after (since, afterHex).
func (s *Store) SightingsSince(ctx context.Context, since int64, afterHex string, limit int) ([]*Sighting, error) {
	rows, err := s.r.QueryContext(ctx, "SELECT "+sightingCols+` FROM sightings
		WHERE last_seen > ? OR (last_seen = ? AND hex > ?) ORDER BY last_seen, hex LIMIT ?`, since, since, afterHex, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*Sighting{}
	for rows.Next() {
		sg, err := scanSighting(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sg)
	}
	return out, rows.Err()
}

// Lookup is a persisted upstream answer.
type Lookup struct {
	Status    int
	Body      []byte
	FetchedAt int64
	ExpiresAt int64
}

// GetLookup returns a stored lookup, expired or not (nil if absent).
func (s *Store) GetLookup(ctx context.Context, kind, key string) (*Lookup, error) {
	var l Lookup
	err := s.r.QueryRowContext(ctx, "SELECT status, body, fetched_at, expires_at FROM lookups WHERE kind = ? AND key = ?", kind, key).
		Scan(&l.Status, &l.Body, &l.FetchedAt, &l.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return &l, err
}

// PutLookup stores a lookup.
func (s *Store) PutLookup(ctx context.Context, kind, key string, l Lookup) error {
	_, err := s.w.ExecContext(ctx, `INSERT INTO lookups(kind, key, status, body, fetched_at, expires_at) VALUES(?,?,?,?,?,?)
		ON CONFLICT(kind, key) DO UPDATE SET status=excluded.status, body=excluded.body, fetched_at=excluded.fetched_at, expires_at=excluded.expires_at`,
		kind, key, l.Status, l.Body, l.FetchedAt, l.ExpiresAt)
	return err
}

// AcarsMessage is a stored ACARS message.
type AcarsMessage struct {
	ID       int64           `json:"id"`
	Hex      string          `json:"hex"`
	FlightID int64           `json:"flightId"`
	Time     int64           `json:"time"`
	Label    string          `json:"label,omitempty"`
	Message  json.RawMessage `json:"message"` // as Airframes sent it
}

// InsertAcars stores messages, ignoring ones already stored.
func (s *Store) InsertAcars(ctx context.Context, msgs []AcarsMessage) (int, error) {
	if len(msgs) == 0 {
		return 0, nil
	}
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	n := 0
	for _, m := range msgs {
		res, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO acars(id, hex, flight_id, ts, label, body) VALUES(?,?,?,?,?,?)",
			m.ID, m.Hex, m.FlightID, m.Time, m.Label, []byte(m.Message))
		if err != nil {
			return 0, err
		}
		if k, _ := res.RowsAffected(); k > 0 {
			n++
		}
	}
	return n, tx.Commit()
}

// AcarsSince returns stored messages for hex at or after since, oldest first.
func (s *Store) AcarsSince(ctx context.Context, hex string, since int64, limit int) ([]AcarsMessage, error) {
	rows, err := s.r.QueryContext(ctx, "SELECT id, hex, flight_id, ts, label, body FROM acars WHERE hex = ? AND ts >= ? ORDER BY ts, id LIMIT ?", hex, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AcarsMessage{}
	for rows.Next() {
		var m AcarsMessage
		var body []byte
		if err := rows.Scan(&m.ID, &m.Hex, &m.FlightID, &m.Time, &m.Label, &body); err != nil {
			return nil, err
		}
		m.Message = body
		out = append(out, m)
	}
	return out, rows.Err()
}
