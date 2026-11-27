#!/bin/zsh
# Rebuilds Shared/Resources/navdata.csv, the bundled fix and navaid table used to draw routes
# decoded from ACARS, from public-domain sources:
#
#   - FAA NASR 28-day subscription (US government work): FIX_BASE.csv and NAV_BASE.csv
#   - OurAirports navaids.csv (worldwide VOR/DME/NDB)
#
#   scripts/update-navdata.sh               the NASR edition in effect today
#   scripts/update-navdata.sh 2026-11-26    a specific edition (its effective date)
#
# Downloads go to a temporary directory that is removed afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

INDEX="https://www.faa.gov/air_traffic/flight_info/aeronav/aero_data/NASR_Subscription/"
OURAIRPORTS="https://davidmegginson.github.io/ourairports-data/navaids.csv"
OUT="Shared/Resources/navdata.csv"

die() { print -u2 "error: $*"; exit 1; }

edition="${1:-}"
if [[ -z "$edition" ]]; then
  # The index lists the current edition and, late in a cycle, the next one: take the latest
  # that is already in effect.
  today=$(date -u +%Y-%m-%d)
  edition=$(curl -fsSL "$INDEX" | grep -oE 'NASR_Subscription/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
            | sed 's|.*/||' | sort -u | awk -v t="$today" '$0 <= t' | tail -1)
fi
[[ "$edition" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]] || die "no NASR edition found (pass one as YYYY-MM-DD)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The edition page links per-category CSV archives (".../extra/26_Nov_2026_FIX_CSV.zip").
page=$(curl -fsSL "${INDEX}${edition}")
for kind in FIX NAV; do
  url=$(print -r -- "$page" | grep -oE "https://nfdc\.faa\.gov/webContent/28DaySub/extra/[0-9]{2}_[A-Za-z]{3}_[0-9]{4}_${kind}_CSV\.zip" | head -1)
  [[ -n "$url" ]] || die "no ${kind} CSV archive on the ${edition} edition page"
  print "Downloading $url"
  curl -fsSL -o "$tmp/$kind.zip" "$url"
  mkdir -p "$tmp/$kind"
  unzip -q -j "$tmp/$kind.zip" "${kind}_BASE.csv" -d "$tmp/$kind"
done
print "Downloading $OURAIRPORTS"
curl -fsSL -o "$tmp/navaids.csv" "$OURAIRPORTS"

python3 -I scripts/navdata.py --edition "$edition" --fixes "$tmp/FIX/FIX_BASE.csv" \
  --navaids "$tmp/NAV/NAV_BASE.csv" --ourairports "$tmp/navaids.csv" --out "$OUT"
