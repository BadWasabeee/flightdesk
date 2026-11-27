# FlightDesk server

A small, self-hosted Go service that your FlightDesk apps (macOS, iPhone, widgets) can use instead of each calling the public flight-data APIs themselves. It:

- **polls the live ADS-B feed for one area** (adsb.fi, with adsb.lol as a fallback) every few seconds and serves that snapshot to all your devices;
- **proxies and caches** the other free APIs the apps use (adsbdb, OpenSky, Airframes.io, aviationweather.gov), so each answer is fetched once for all devices;
- **keeps a compact flight history**: tracks for every flight in your area, plus the flights you open elsewhere, along with a sightings logbook your devices can sync.

The result is one well-behaved poller instead of several, fewer upstream requests in total, and history that builds up while your devices are asleep.

It's a single static binary (Go standard library plus the pure-Go SQLite driver `modernc.org/sqlite`, no cgo) that uses about 10 MB of RAM and a few hundred MB of disk per year for a busy area.

No paid APIs or keys are used, ever.

---

## Contents

- [Privacy](#privacy)
- [Setup](#setup)
- [Configuration](#configuration)
- [Storage](#storage)
- [Upstream requests and rate limits](#upstream-requests-and-rate-limits)
- [API reference](#api-reference)
- [How the apps use it](#how-the-apps-use-it)
- [Development](#development)

---

## Privacy

- **It's your server.** Nothing is sent to the FlightDesk project or to any third party other than the public APIs listed below, which the apps would otherwise call directly.
- **Your devices send their location to it.** `/v1/nearby` takes your latitude and longitude, like the apps' direct requests to adsb.fi do. Inside your configured area, the server answers from its own snapshot and your position goes nowhere else. Outside it, the server makes one upstream request with the position rounded to 2 decimals (about 1 km), exactly as the apps do.
- **Positions aren't logged.** Request logs record the method, path, status and duration, never the query string. The nginx template logs paths without queries too.
- **What upstreams see:**
  - adsb.fi and adsb.lol see your area's centre and radius (or a device's rounded position for out-of-area requests) and the hexes you watch.
  - OpenSky, adsbdb and Airframes.io see aircraft hexes, callsigns and registrations.
  - aviationweather.gov sees airport codes.
  - All of them see your server's IP address instead of your devices'.
- **The token** is checked in constant time. The server refuses to start without one of at least 32 characters, and limits failed attempts per IP. Use TLS (below), because the token travels in every request.
- **Stored data** (flight tracks, the sightings log, ACARS messages from flights you opened) is public broadcast data, but which flights you looked at is personal. The database lives in `/var/lib/flightdesk/`, readable only by the service.

---

## Setup

You need a Debian or Ubuntu host with systemd, and Go 1.25+ on the machine you deploy from.

### 1. Deploy

```sh
cd Server
./deploy.sh you@your-vps --area 42.95,-87.90,100 --nginx flightdesk.example.com
```

`deploy.sh` does the following:

1. Runs the tests.
2. Cross-compiles a static `linux/amd64` binary (`--arch arm64` for ARM hosts).
3. Copies the binary over SSH and installs:
   - `/usr/local/bin/flightdesk-server`
   - the hardened systemd unit
   - `/etc/flightdesk/flightdesk.env` (root-only, `0600`)
4. Enables and starts the service, then checks `/healthz`.

It is idempotent, so run it again for every update:

- **An existing config and token are never overwritten.** `--area` only fills in a newly created config.
- **On first install it prints a new token once.** To read it later, run `sudo grep ^FLIGHTDESK_TOKEN /etc/flightdesk/flightdesk.env`.
- **It refuses to start if port 8787 is used by another program.** In that case, change `FLIGHTDESK_LISTEN` and the nginx upstream to match.

### 2. TLS

The server listens on `127.0.0.1:8787` by default and should sit behind TLS. Pick one of these options.

**nginx** (if it already fronts other sites): `--nginx DOMAIN` installs [`deploy/nginx-flightdesk.conf`](deploy/nginx-flightdesk.conf) as `/etc/nginx/sites-available/flightdesk-server.conf`.

- It only writes this file if it doesn't already exist, enables it, and runs `nginx -t` before reloading. If the test fails, it rolls back its own file.
- It never touches any other site.

Then add a certificate (certbot edits only this site):

```sh
sudo certbot --nginx -d flightdesk.example.com --redirect
```

The template passes the server's gzip responses through, caps request bodies at 4 KB, sets proxy timeouts, and logs paths without query strings. `sslip.io`-style hostnames work fine with certbot.

**Caddy** (automatic HTTPS), as in [`deploy/Caddyfile.example`](deploy/Caddyfile.example):

```
flightdesk.example.com {
	reverse_proxy 127.0.0.1:8787
}
```

**Tailscale or WireGuard**: don't expose the server publicly at all. Set `FLIGHTDESK_LISTEN` to the VPN address (for example `100.x.y.z:8787`) and point the apps at `http://100.x.y.z:8787`. The VPN encrypts the traffic, and the server warns at startup when listening on a non-loopback address.

Don't enter the token in the apps until `https://` works.

### 3. Check

```sh
curl https://flightdesk.example.com/healthz                       # {"ok":true}
curl -H "Authorization: Bearer $TOKEN" https://flightdesk.example.com/v1/stats
journalctl -u flightdesk-server -f                                # structured JSON logs
systemd-analyze security flightdesk-server                        # sandbox score
```

### Manual install

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o flightdesk-server ./cmd/flightdesk-server
sudo install -m 0755 flightdesk-server /usr/local/bin/
sudo install -m 0644 deploy/flightdesk-server.service /etc/systemd/system/
sudo install -d -m 0750 /etc/flightdesk
sudo install -m 0600 deploy/flightdesk.env.example /etc/flightdesk/flightdesk.env
flightdesk-server token          # paste into FLIGHTDESK_TOKEN, then set the area
sudo flightdesk-server check -config /etc/flightdesk/flightdesk.env
sudo systemctl daemon-reload && sudo systemctl enable --now flightdesk-server
```

### Commands

| Command | |
|---|---|
| `flightdesk-server [serve] [-config FILE]` | Run the server. |
| `flightdesk-server token` | Print a new random 256-bit token (64 hex characters). |
| `flightdesk-server check -config FILE` | Validate a configuration. |
| `flightdesk-server version` | Print the version. |

---

## Configuration

Configuration lives in one env file, `/etc/flightdesk/flightdesk.env`, as `KEY=VALUE` lines. systemd reads it as root before dropping privileges, so it can stay `root:root 0600`. Variables in the process environment override the file.

| Variable | Default | |
|---|---|---|
| `FLIGHTDESK_TOKEN` | *(required)* | Bearer token, at least 32 printable characters. Placeholders are refused. |
| `FLIGHTDESK_LISTEN` | `127.0.0.1:8787` | Listen address. |
| `FLIGHTDESK_DATA_DIR` | `/var/lib/flightdesk` | Database directory. This is systemd's `StateDirectory`. |
| `FLIGHTDESK_CENTER_LAT`, `FLIGHTDESK_CENTER_LON` | | Area centre. |
| `FLIGHTDESK_RADIUS_NM` | `0` | Area radius, 1–250 nm. `0` turns the area poller off. |
| `FLIGHTDESK_POLL_INTERVAL` | `8s` | Area poll interval (5s–60s). |
| `FLIGHTDESK_WATCH_INTERVAL` | `45s` | Poll interval for watched flights (30s–5m). |
| `FLIGHTDESK_MAX_WATCHES` | `20` | Concurrent watches. |
| `FLIGHTDESK_RETAIN_DETAIL_DAYS` | `90` | How long full-detail tracks are kept. |
| `FLIGHTDESK_RETAIN_COARSE_DAYS` | `730` | How long downsampled tracks (1 point every 5 min) are kept. |
| `FLIGHTDESK_RETAIN_ACARS_DAYS` | `180` | How long stored ACARS messages are kept. |
| `FLIGHTDESK_DISK_CAP_GB` | `15` | Hard cap on the database size. |
| `FLIGHTDESK_MAINTENANCE_HOUR` | `3` | Hour (server local time) for the nightly retention run. |
| `FLIGHTDESK_RATE_LIMIT_PER_MIN` | `240` | Requests per minute per client IP. The burst is a quarter of this. |
| `FLIGHTDESK_TRUST_PROXY` | `true` | Use `X-Real-IP` / `X-Forwarded-For`, but only from a proxy on loopback. |
| `FLIGHTDESK_LOG_LEVEL` / `FLIGHTDESK_LOG_FORMAT` | `info` / `json` | |
| `FLIGHTDESK_USER_AGENT` | `FlightDesk-Server/1 (+repo URL)` | User-Agent sent upstream. |

---

## Storage

Disk use matters most on a small VPS, so storage is designed around four things.

**1. A dead-band filter.** A position is stored only when it differs meaningfully from the last point stored for that aircraft:

- the heading has changed by more than 3°;
- the altitude has changed by more than 200 ft;
- the ground/air state has changed;
- otherwise, at least one point every 60 s while airborne.

On the ground, taxiing aircraft get a point every 60 s. Parked aircraft get one every 10 minutes, because busy airports report dozens of parked transponders for hours. A leg's last observed position is always stored when it ends.

**2. A compact encoding.** Points are quantised as follows:

| Field | Stored as |
|---|---|
| Latitude/longitude | Integers in units of 1e-5° (about 1.1 m) |
| Altitude | 25 ft steps (fits an int16) |
| Speed and track | Whole knots and whole degrees |
| Time | Seconds from the leg start |

Each point is then delta-encoded as zig-zag varints against the previous point, with a flag bit for "no track". Points are appended in chunks to a single BLOB per leg (`tracks.data`), not stored as one row per point. The format is documented in [`internal/trackenc/trackenc.go`](internal/trackenc/trackenc.go).

**3. Retention tiers:**

| Age | What's kept |
|---|---|
| ≤ 90 days | Full-detail tracks. |
| 90 days – 2 years | Tracks downsampled to about 1 point per 5 min, keeping take-off and landing points. These are moved to `tracks_coarse` so that whole pages are freed. |
| Forever | Leg metadata (hex, callsign, registration, type, first/last seen, origin/destination when known, minimum distance to the centre, maximum altitude) and the sightings log. |
| ≤ 180 days | ACARS messages. |

**4. A hard cap** (`FLIGHTDESK_DISK_CAP_GB`, default 15 GB). The cap is checked shortly after startup and then hourly; retention also runs nightly. When the database is over the cap, the server prunes the oldest detail first, in this order, until it is back under the cap:

1. Downsample the oldest full-detail tracks, leaving the newest 7 days alone.
2. Drop the oldest downsampled tracks.
3. Delete the oldest ACARS messages.
4. Downsample even the last 7 days.

Leg rows and sightings are never pruned. Every prune is logged with what was removed and the date range affected.

SQLite runs in WAL mode with `auto_vacuum=INCREMENTAL`, and `PRAGMA incremental_vacuum` plus a WAL checkpoint run after every prune, so freed space really goes back to the filesystem. (The tests check that the file shrinks.)

### Encoding benchmark

These numbers come from `go test ./internal/trackenc -bench . -v`, using simulated flights sampled every 8 s with realistic feed jitter (±0.4° track, ±25 ft):

| Profile | Observed points/leg | Stored after dead-band | Bytes/point | Bytes/leg | Same points as JSON |
|---|---:|---:|---:|---:|---:|
| Arrival (cruise → descent → vectors → landing → taxi → 20 min parked) | 388 | 126 | 8.2 | ~1.0 KB | ~15 KB |
| Departure (15 min parked → taxi → climb-out) | 322 | 121 | 8.1 | ~1.0 KB | ~14 KB |
| Overflight (25 min at cruise) | 190 | 26 | 10.4 | ~0.27 KB | ~3 KB |

The same points in fixed-width binary (int32 time/lat/lon, int16 alt, uint16 speed/track, flags) take 19 B each. Delta varints take about 8 B. Encoding a 126-point leg takes about 3 µs, and decoding it takes about 3 µs (Apple M-series).

### Expected storage for a busy area

These figures come from an end-to-end simulation through the real tracker and SQLite (`FLIGHTDESK_STORAGE_ESTIMATE=1 go test ./internal/tracker -run StorageEstimate -v`). It models about 1,000 legs/day from about 810 unique aircraft (35% arrivals, 35% departures, 30% overflights), interleaved, polled every 8 s and flushed every minute. That's roughly a 100 nm area around Chicago/Milwaukee.

| | Per day | Kept for | Total |
|---|---:|---:|---:|
| Full-detail tracks + legs + sightings (≈95 points/leg × 8.3 B) | **≈1.1 MB** | 90 days | ≈100 MB |
| After downsampling (tracks ≈8 points/leg; mostly leg rows) | ≈0.34 MB | days 91–730 | ≈220 MB |
| Leg metadata + sightings after 2 years | ≈0.25 MB | forever | ≈90 MB/year |
| ACARS (only flights you open: ≈0.4 KB/message, ~100–200 per flight; say 10 flights/day) | ≈0.6 MB | 180 days | ≈110 MB |
| adsbdb/Airframes lookup cache | | expires | a few MB |

That comes to **about 0.45 GB after two years**, then about 90 MB a year after that. Real feeds are noisier than the simulation, so allow up to 2× (about 1 GB at two years). Even a full 250 nm radius (roughly 3–4× the traffic) stays well under the 15 GB default cap, so the cap is a safety net, not something you should expect to hit.

---

## Upstream requests and rate limits

Every outgoing request goes through one client that enforces each service's published limit. Each service has:

- a minimum spacing between requests;
- a daily allowance with a reserve, where the service publishes one;
- a pause after a 429, or when rate-limit headers say the allowance is nearly spent (the same rules as the apps' `ApiBudget`).

Daily counts survive restarts.

| Service | Used for | Server's limit |
|---|---|---|
| adsb.fi open data | Area poll, out-of-area nearby, watches | ≤ 1 request/1.1 s (published: 1/s) |
| adsb.lol | Fallback when adsb.fi fails | 500/day with 60 in reserve, and at most one every 90 s |
| OpenSky (anonymous) | Departure of a flight the server picked up mid-air | 400/day with 40 in reserve; **once per leg**, stored |
| adsbdb | Routes, aircraft | 2/s; routes cached 1 day, aircraft 30 days (misses 6 h / 7 days), in SQLite |
| Airframes.io | ACARS | 40/min (published: 60/min); airframe ids cached 1 day (misses 6 h), flight list 115 s, messages 100 s |
| aviationweather.gov | METAR / TAF | 60/min (published: <100/min); cached per station 10 min (METAR) / 30 min (TAF) |

At the default 8 s interval, the area poller makes **10,800 adsb.fi requests a day** in total, for all devices together. That's one per 8 s against a published allowance of one per second.

Each app polling directly does about that much on its own while open, and every widget timeline, every device, and every route, aircraft and track lookup adds more. With the server, out-of-area requests are coalesced, and each route, aircraft and OpenSky track is fetched once for all devices. Concurrent identical requests share one fetch, and a stale cached answer is served if an upstream is down.

Watches don't multiply requests: all watched hexes not already in the area snapshot are fetched in **one** batched `adsb.fi /v2/hex/a,b,c` request per watch interval (adsb.fi accepts comma-separated hexes). A flight inside the area costs nothing extra.

adsb.fi caps the radius at 250 nm: it returns HTTP 400 above that, which was checked against the live API. So any configured area is a single request, and no tiling is needed.

---

## API reference

All endpoints except `/healthz` require the bearer token:

```
Authorization: Bearer <token>
```

**General behaviour:**

- Responses are JSON. Bodies of 512 bytes or more are gzipped when the request sends `Accept-Encoding: gzip`. (`URLSession` does this automatically.)
- Responses carry `Cache-Control: no-store`.
- Times are **Unix seconds**, unless noted otherwise.

**Errors** use this shape:

```json
{"error": "human-readable message"}
```

| Status | Meaning |
|---|---|
| 400 | Invalid input: the parameter rules are below. Invalid input never reaches an upstream. |
| 401 | Missing or wrong token (`WWW-Authenticate: Bearer`). |
| 404 | Nothing known, or no such route or aircraft (cached, definitive). |
| 429 | Rate limited: per IP, after too many failed tokens (10, then 1/min), or watch limit reached. Comes with `Retry-After`. |
| 502 | Upstream unavailable and nothing cached. |
| 503 | Upstream paused or out of budget (`Retry-After`). Treat like 502. |

**Validation rules:**

| Parameter | Rule |
|---|---|
| hex | Exactly 6 hex digits, case-insensitive; returned lowercase. `/v1/track` and `/v1/history/legs` also accept readsb's `~` prefix for non-ICAO addresses. |
| callsign | `[A-Z0-9]{2,8}`, case-insensitive. |
| ICAO airport | 4 characters `[A-Z0-9]`. |
| registration | `[A-Z0-9-]{2,10}`. |
| lat | −90…90. |
| lon | −180…180. |
| radius | 1…250 nm. |
| numbers | Finite. |

### `GET /healthz`

No auth. Returns `200 {"ok":true}`.

### `GET /v1/nearby?lat=&lon=&radius=[&ground=1][&limit=]`

Aircraft within `radius` nm (default 25) of `lat`/`lon`, nearest first.

- **Inside the area:** when the request circle lies entirely inside the configured area and the snapshot is fresh, the answer comes from the in-memory snapshot (`source: "area"`, no upstream request).
- **Outside it:** one upstream fetch per ~1 km cell and radius, cached for 5 s, shared by concurrent callers, and served stale for up to 60 s if the feed fails (`source: "proxy"`).
- **Ground traffic** is excluded unless `ground=1`, matching the apps' `Flight(adsb:)`.
- **limit** is 1–2000 (default: all).

```json
{
  "source": "area",          // "area" | "proxy"
  "feed": "adsb.fi",         // "adsb.fi" | "adsb.lol"
  "time": 1795792248.1,      // feed timestamp (Unix s, fractional)
  "age": 3.9,                // seconds since `time`
  "cache": "",               // proxy only: "hit" | "miss" | "stale"
  "flights": [ Flight, ... ]
}
```

**`Flight`** has the exact keys of the Swift `Flight` model (`Shared/FlightCore.swift`), so `JSONDecoder().decode([Flight].self, …)` works unchanged:

| Key | Type | Swift field | Notes |
|---|---|---|---|
| `id` | string | `id` | Lowercase hex; `~` prefix for non-ICAO addresses. |
| `callsign` | string | `callsign` | Trimmed; may be `""`. |
| `reg` | string | `reg` | Registration, or the hex uppercased (as the app does). |
| `typeCode` | string | `typeCode` | ICAO type; may be `""`. |
| `altitude` | int | `altitude` | Barometric feet; `0` on the ground. |
| `verticalRate` | number | `verticalRate` | ft/min (`baro_rate` ?? `geom_rate` ?? 0). |
| `speed` | number | `speed` | Ground speed, knots. |
| `track` | number? | `track` | Degrees true (`track` ?? `true_heading`); omitted when unknown. |
| `lat`, `lon` | number | `lat`, `lon` | |
| `distance` | number | `distance` | nm from the **request's** lat/lon (same haversine as the app). |
| `bearing` | number | `bearing` | Degrees from the request's position to the aircraft. |
| `squawk` | string? | `squawk` | Omitted when not reported. |
| `onGround` | bool | *(extra)* | |
| `positionTime` | number | *(extra)* | Unix s when the position was received. |
| `desc`, `ownOp` | string? | *(extra)* | Aircraft description and operator, as the feed reports them. This is what `AircraftReport` turns into `AircraftInfo(model:owner:)` with `.capitalized`. |
| `year` | int? | *(extra)* | Build year. |
| `navQnh` | number? | *(extra)* | Selected altimeter setting, hPa. |
| `category` | string? | *(extra)* | ADS-B emitter category (`A1`…). |

`route`, `aircraft` and `pathSituation` are not sent. The app keeps enriching flights, now through `/v1/route` and `/v1/aircraft`.

### `GET /v1/track/{hex}[?leg=ID][&opensky=0]`

The track of the aircraft's current or most recent leg (last seen within 20 h), built from the server's own history. When the server's track starts in the air (above 3,000 ft, meaning it missed the departure), the leg is recent, and OpenSky has budget, the server merges in OpenSky's track for the earlier part. OpenSky is fetched **at most once per leg** and stored with the leg.

- `leg=ID` returns a specific past leg (see `/v1/history/legs`), without OpenSky.
- `opensky=0` returns only the server's own history.

The body mirrors **OpenSky's `/tracks/all`**, so the app's `FlightTrack(data:current:)` parses it unchanged. Extra keys are ignored.

```json
{
  "icao24": "abc123",
  "callsign": "UAL1",
  "startTime": 1795788648,
  "endTime": 1795792248,
  "path": [[1795788648, 41.97, -87.9, 0, 90, true],          // [time, lat, lon, baro altitude in METRES, true track | null, onGround]
           [1795792248, 41.88061, -87.52207, 11574.8, 291, false]],
  "source": "merged",        // "server" | "opensky" | "merged"
  "active": true,            // the server is following this leg right now (includes unflushed points and the latest position)
  "leg": Leg                 // see /v1/history/legs; omitted when the track is OpenSky-only
}
```

Altitude is always a number (`0` on the ground), because the app's `RouteResolver.departure` needs the first point's altitude. The response is `404` when there is no track from either source.

### `GET /v1/route/{callsign}` and `GET /v1/aircraft/{hex}`

Proxies for adsbdb `/v0/callsign/{callsign}` and `/v0/aircraft/{hex}`. **The body and status are adsbdb's own** (`200` with the route or aircraft, `404` when unknown), so the app's existing adsbdb decoding applies as-is.

- Routes are cached for 1 day (misses 6 h); aircraft for 30 days (misses 7 days). The cache lives in SQLite and survives restarts.
- The `X-Cache` header is `hit`, `miss` or `stale` (served after an upstream failure).
- Fetched routes also fill in the origin and destination of matching legs and sightings.

### `GET /v1/acars/{hex-or-registration}[?flight=ID]`

ACARS from Airframes.io for one aircraft.

```json
{
  "airframeId": 555,         // null: Airframes has never heard of this aircraft
  "airframe": { ... },       // Airframes /v1/airframes/{id} exactly (id, icao, tail, flights[...])
  "flightId": 9001,          // null: no current flight
  "flight": { ... }          // Airframes /v1/flights/{id} exactly (latest ≤200 messages, newest first)
}
```

- `airframe` decodes with the app's `AirframesAPI.Airframe`, and `flight` with `AirframesAPI.Flight`. Use `AirframesAPI.decoder()` for the ISO 8601 dates.
- **Which flight:** the server picks the most recently updated flight in the airframe's list (within 18 h). For the app's exact matching (`AcarsFlightMatcher`, which uses callsign and flight number), run the matcher on `airframe.flights` and call again with `?flight=ID`. The ID must belong to that airframe.
- **Caching:** airframe IDs are cached in SQLite for 1 day (misses 6 h), the airframe for 115 s, and the flight for 100 s.
- **Storage:** every message seen is stored (see `/v1/history/acars`).

### `GET /v1/metar?ids=KMKE,KORD` and `GET /v1/taf?ids=…`

Up to 20 ICAO codes. **The body is aviationweather.gov's `format=json` array** (one record per station that has a report, in request order), so the app's existing decoders apply.

- Reports are cached per station: METAR 10 min, TAF 30 min. Stations without a report are cached too.
- A request for `KORD,KMDW` after `KMKE,KORD` fetches only `KMDW`.
- The `X-Cache` header is `hit`, `miss` or `stale`.

### `POST /v1/watch/{hex}`, `DELETE /v1/watch/{hex}` and `GET /v1/watch`

Follow a flight outside the area so its history is recorded. The app calls `POST` when the user opens a flight that isn't in the area snapshot.

The server polls the hex every watch interval (batched with all other watches) until one of these happens:

- the flight **lands**: seen on the ground after being airborne;
- it **disappears for 30 minutes**;
- **18 hours** pass;
- it **never leaves the ground within an hour**.

Re-posting an active watch is a no-op. Watches survive restarts.

`POST` returns `202`:

```json
{"watch": {"hex": "400001", "added": "2026-11-27T15:00:00Z", "seenAirborne": false, "onGround": false},
 "active": 3, "max": 20}
```

- `429` means the watch cap has been reached.
- `DELETE` returns `204`, or `404` if the hex isn't being watched.
- `GET` returns `{"watches": [...], "active": n, "max": 20}`.

### `GET /v1/history/sightings?since=&after=&limit=`

The spotting log for the area, for syncing the app's logbook. Entries are ordered by `(lastSeen, hex)`. Pass `since` = 0 the first time, then page with the returned cursor. `limit` is 1–5000 (default 1000).

```json
{
  "sightings": [{
    "hex": "a1cfb7", "registration": "N2159Q", "typeCode": "P28A",
    "operatorName": "WISCONSIN AVIATION-FOUR LAKES INC",
    // "airlineICAO": "UAL" appears when a callsign looked like an airline's (3 letters + digit)
    "firstSeen": 1795790162, "lastSeen": 1795792248,
    "sightings": 2,                // separate visits (a new one after 30 min unseen)
    "callsigns": ["N2159Q"],       // most recent last, at most 8
    "closestNM": 4.73, "closestAt": 1795790200,   // from the AREA CENTRE, not from a device
    "maxAltitude": 1400,
    "routes": ["ORD-DEN"]          // most recent last, at most 12 (when a route was looked up)
  }],
  "next": {"since": 1795792248, "after": "a1cfb7"},   // null on the last page
  "serverTime": 1795792300
}
```

The keys mirror the Swift `LogEntry`. Note that the dates are Unix seconds, so decode with `.secondsSince1970`. Only aircraft seen by the area poller are logged; watched flights outside the area are not.

### `GET /v1/history/legs?hex=&callsign=&since=&before=&limit=`

Flight legs, newest first, filtered by `last_seen` (`since` ≤ `lastSeen` < `before`). `limit` is 1–1000 (default 200).

```json
{"legs": [{"id": 42, "hex": "abc123", "callsign": "UAL1", "reg": "N12345", "typeCode": "B739",
           "firstSeen": 1795788648, "lastSeen": 1795792248, "origin": "ORD", "dest": "DEN",
           "minDistanceNM": 4.73, "maxAltitude": 37000,
           "source": 1,      // bit 0: area poller, bit 1: watch
           "tier": 0,        // 0 full detail, 1 downsampled, 2 track pruned (metadata only)
           "points": 126}]}
```

An active leg reports `id: 0` until its first flush (within a minute).

### `GET /v1/history/acars?hex=&since=&limit=`

Stored ACARS messages for an aircraft, oldest first: `{"messages": [{"id", "hex", "flightId", "time", "label", "message": <Airframes message JSON>}]}`.

### `GET /v1/stats`

Server health and usage:

- database file, WAL, used and free bytes, the disk cap, and row counts (legs per tier, track bytes and points, sightings, ACARS, lookups);
- **upstream requests per service today** (UTC), with errors, daily limits and pauses;
- area poller health (last success, error, feed, aircraft count, poll duration, consecutive failures);
- active watches, tracker counters, cache sizes, memory, retention settings, and the last maintenance and prune reports.

---

## How the apps use it

The apps implement this contract in `Shared/FlightDeskServer.swift` (see "Your own FlightDesk server" in the main README).

**Settings › Sources › "FlightDesk server"** takes a URL (for example `https://flightdesk.example.com`) and the token. Store the token in the Keychain, not in shared defaults.

**Fallback:** if the server is unset, unreachable, times out (about 5 s), or answers `401`, `5xx` or a transport error, use the direct APIs exactly as today. Mark the server unhealthy for a couple of minutes (as `FeedHealth` does for feeds) and retry it after that. A `503` means the upstream is paused or out of budget. Going direct may hit the same limit, so respect `Retry-After`.

**Mapping:**

| App today | With the server | Decoding |
|---|---|---|
| `LiveFeed` point query (`FlightService.allNearby`) | `GET /v1/nearby?lat&lon&radius` | `{flights:[Flight]}`, default `JSONDecoder`, unchanged model |
| `FlightDetailService.report(hex:)` | `/v1/nearby` from the area snapshot, else the direct hex query | `Flight` (+ `onGround`, `positionTime`, `desc`, `ownOp`, `year`, `navQnh` for `AircraftReport`) |
| `FlightDetailService.track` (OpenSky) | `GET /v1/track/{hex}` | `FlightTrack(data:current:)` unchanged (OpenSky shape, metres) |
| `FlightService.fetchRoute` / `fetchAircraft` (adsbdb) | `GET /v1/route/{cs}`, `GET /v1/aircraft/{hex}` | Unchanged adsbdb decoders; `200` or `404` are definitive |
| `AcarsService` (Airframes) | `GET /v1/acars/{hex}[?flight=]` | `AirframesAPI.Airframe` / `.Flight` with `AirframesAPI.decoder()` |
| `AirportWeather` (aviationweather) | `GET /v1/metar?ids=`, `/v1/taf?ids=` | Unchanged `format=json` decoders |
| Detail view opened outside the area | Also `POST /v1/watch/{hex}` (fire and forget) | |
| Spotting log | `GET /v1/history/sightings` (incremental; keep the cursor) | `LogEntry`-like; `.secondsSince1970` |

**Notes for the client:**

- Requests to the server can be counted under their own `ApiService` case, so they don't use up the per-service budgets meant for direct calls.
- Keep the apps' local caches (`NearbyCache`, `LookupCache`, `TrackCache`). The server makes misses cheap; it doesn't replace them.
- Widgets use the server too: the URL through the app group, the token through the shared Keychain, so a widget refresh costs no upstream request.

---

## Development

```sh
go test ./...                       # all tests; fake upstreams via httptest, no network
go test -race ./...
go test ./internal/trackenc -bench . -run XXX
FLIGHTDESK_STORAGE_ESTIMATE=1 go test ./internal/tracker -run StorageEstimate -v
```

Run it locally:

```sh
go run ./cmd/flightdesk-server token
FLIGHTDESK_TOKEN=... FLIGHTDESK_DATA_DIR=./data FLIGHTDESK_LOG_FORMAT=text \
FLIGHTDESK_CENTER_LAT=42.95 FLIGHTDESK_CENTER_LON=-87.90 FLIGHTDESK_RADIUS_NM=50 \
  go run ./cmd/flightdesk-server
```

Layout:

```
cmd/flightdesk-server   main: subcommands, wiring, maintenance scheduler, graceful shutdown
internal/config         env-file config and validation, token rules
internal/upstream       the only HTTP client: per-service spacing, daily budgets, 429 pauses, counts
internal/cache          in-memory TTL cache with request coalescing and stale-on-error
internal/adsb           readsb (adsb.fi / adsb.lol) parsing → Swift-compatible Flight
internal/poller         feeds with fallback, area poller, batched watches
internal/tracker        legs, dead-band simplification, sightings; batched flushes
internal/trackenc       compact track encoding, simplifier, downsampling, synthetic profiles
internal/store          SQLite schema, legs/tracks/sightings/lookups/ACARS, retention, disk cap
internal/api            HTTP API: auth, rate limits, validation, gzip, handlers
deploy/                 systemd unit, env example, nginx site, Caddyfile, remote installer
deploy.sh               build + install over SSH
```
