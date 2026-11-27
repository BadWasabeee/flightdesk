package upstream

// Endpoints are the upstream base URLs (overridable for tests and self-hosted mirrors).
type Endpoints struct {
	AdsbFi          string // readsb API: {base}/v2/lat/../lon/../dist/.., {base}/v2/hex/..
	AdsbLol         string // {base}/v2/point/{lat}/{lon}/{nm}
	OpenSky         string // {base}/tracks/all?icao24=..&time=0
	Adsbdb          string // {base}/callsign/{cs}, {base}/aircraft/{hex}
	Airframes       string // {base}/airframes/icao/{HEX}, /airframes/tail/{reg}, /airframes/{id}, /flights/{id}
	AviationWeather string // {base}/metar?ids=..&format=json, {base}/taf?...
}

// DefaultEndpoints are the public services FlightDesk uses. None needs a key.
var DefaultEndpoints = Endpoints{
	AdsbFi:          "https://opendata.adsb.fi/api",
	AdsbLol:         "https://api.adsb.lol",
	OpenSky:         "https://opensky-network.org/api",
	Adsbdb:          "https://api.adsbdb.com/v0",
	Airframes:       "https://api.airframes.io/v1",
	AviationWeather: "https://aviationweather.gov/api/data",
}
