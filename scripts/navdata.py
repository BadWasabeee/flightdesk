"""Builds FlightDesk's bundled navigation table (see update-navdata.sh).

Output: one header comment line naming the sources, then `ident,lat,lon,kind` rows sorted by
ident, with coordinates rounded to 4 decimals (about 11 m). Kinds: F named fix, V VHF navaid
(VOR, VOR-DME, VORTAC, TACAN, DME), N NDB.
"""

import argparse
import csv
import datetime
import math
import re

IDENT = re.compile(r"^[A-Z0-9]{2,5}$")
# NASR fix uses: everything an FMS route can name, except VFR-only waypoints.
SKIPPED_FIX_USES = {"VFR"}
NASR_NAVAIDS = {"VOR": "V", "VOR/DME": "V", "VORTAC": "V", "TACAN": "V", "DME": "V",
                "NDB": "N", "NDB/DME": "N"}
OURAIRPORTS_NAVAIDS = {"VOR": "V", "VOR-DME": "V", "VORTAC": "V", "TACAN": "V", "DME": "V",
                       "NDB": "N", "NDB-DME": "N"}
# Entries with the same ident closer than this are one facility (a VOR and its co-located NDB,
# or a US navaid listed by both sources).
SAME_FACILITY_NM = 3.0


def distance_nm(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 3440.065 * math.asin(min(1.0, math.sqrt(h)))


def coordinate(value, limit):
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) and abs(v) <= limit else None


def rows(path, encoding):
    with open(path, newline="", encoding=encoding) as f:
        yield from csv.DictReader(f)


def nasr_fixes(path):
    for r in rows(path, "latin-1"):
        ident = r["FIX_ID"].strip()
        lat, lon = coordinate(r["LAT_DECIMAL"], 90), coordinate(r["LONG_DECIMAL"], 180)
        if IDENT.match(ident) and lat is not None and lon is not None \
                and r["FIX_USE_CODE"].strip() not in SKIPPED_FIX_USES:
            yield ident, lat, lon, "F"


def nasr_navaids(path):
    for r in rows(path, "latin-1"):
        ident, kind = r["NAV_ID"].strip(), NASR_NAVAIDS.get(r["NAV_TYPE"].strip())
        lat, lon = coordinate(r["LAT_DECIMAL"], 90), coordinate(r["LONG_DECIMAL"], 180)
        if kind and IDENT.match(ident) and lat is not None and lon is not None \
                and r["NAV_STATUS"].strip() != "SHUTDOWN":
            yield ident, lat, lon, kind


def ourairports_navaids(path):
    for r in rows(path, "utf-8"):
        ident, kind = r["ident"].strip().upper(), OURAIRPORTS_NAVAIDS.get(r["type"].strip())
        lat, lon = coordinate(r["latitude_deg"], 90), coordinate(r["longitude_deg"], 180)
        if kind and IDENT.match(ident) and lat is not None and lon is not None:
            yield ident, lat, lon, kind


def merged_navaids(*sources):
    """Navaids in source order (NASR first), dropping later entries for the same facility.
    VHF navaids go before NDBs, so a co-located pair keeps the VOR."""
    kept = {}
    for source in sources:
        for e in sorted(source, key=lambda e: e[3] != "V"):
            same = kept.setdefault(e[0], [])
            if not any(distance_nm(e[1:3], k[1:3]) < SAME_FACILITY_NM for k in same):
                same.append(e)
    return [e for entries in kept.values() for e in entries]


def number(v):
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--edition", required=True, help="NASR effective date, YYYY-MM-DD")
    p.add_argument("--fixes", required=True, help="NASR FIX_BASE.csv")
    p.add_argument("--navaids", required=True, help="NASR NAV_BASE.csv")
    p.add_argument("--ourairports", required=True, help="OurAirports navaids.csv")
    p.add_argument("--out", required=True)
    a = p.parse_args()
    datetime.date.fromisoformat(a.edition)

    entries = list(nasr_fixes(a.fixes))
    entries += merged_navaids(nasr_navaids(a.navaids), ourairports_navaids(a.ourairports))
    unique = sorted({(i, number(lat), number(lon), k) for i, lat, lon, k in entries})
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    with open(a.out, "w", encoding="ascii", newline="\n") as f:
        f.write(f"# FAA NASR 28-day subscription effective {a.edition} (fixes, US navaids; public domain) + "
                f"OurAirports navaids.csv retrieved {today} (public domain). ident,lat,lon,kind (F fix, V VHF navaid, N NDB)\n")
        for row in unique:
            f.write(",".join(row) + "\n")
    print(f"Wrote {len(unique)} entries to {a.out}")


if __name__ == "__main__":
    main()
