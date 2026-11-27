#!/usr/bin/env bash
# Build the FlightDesk server and install it on a Debian/Ubuntu host over SSH.
#
#   ./deploy.sh user@host [--arch amd64|arm64] [--area LAT,LON,NM] [--nginx DOMAIN] [--skip-tests]
#
# Idempotent: safe to run again for every update. It
#   - cross-compiles a static binary locally (CGO_ENABLED=0),
#   - copies it, the systemd unit and templates to the host,
#   - installs /usr/local/bin/flightdesk-server and the flightdesk-server.service unit,
#   - creates /etc/flightdesk/flightdesk.env with a fresh token ONLY if it doesn't exist
#     (an existing config and token are never overwritten; --area only fills a new config),
#   - with --nginx DOMAIN, adds /etc/nginx/sites-available/flightdesk-server.conf only if it
#     doesn't exist, enables it, and reloads nginx after `nginx -t` (no other site is touched),
#   - enables and (re)starts the service and checks /healthz.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="" arch="amd64" area="" domain="" skip_tests=0

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch="${2:?}"; shift 2 ;;
    --area) area="${2:?}"; shift 2 ;;
    --nginx) domain="${2:?}"; shift 2 ;;
    --skip-tests) skip_tests=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option $1" >&2; usage 2 ;;
    *) [[ -z "$target" ]] || usage 2; target="$1"; shift ;;
  esac
done
[[ -n "$target" ]] || usage 2
[[ "$arch" == amd64 || "$arch" == arm64 ]] || { echo "--arch must be amd64 or arm64" >&2; exit 2; }
if [[ -n "$area" && ! "$area" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,[0-9]+$ ]]; then
  echo "--area must look like 41.88,-87.63,100" >&2; exit 2
fi
if [[ -n "$domain" && ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
  echo "--nginx needs a plain host name" >&2; exit 2
fi

cd "$here"
version="$(git describe --tags --always --dirty 2>/dev/null || echo dev)-$(date -u +%Y%m%d%H%M)"
if [[ $skip_tests -eq 0 ]]; then
  echo "==> go test ./..."
  GOTOOLCHAIN=local go test ./...
fi
echo "==> building linux/$arch ($version)"
mkdir -p build
bin="build/flightdesk-server-linux-$arch"
CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOTOOLCHAIN=local \
  go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$bin" ./cmd/flightdesk-server

echo "==> copying to $target"
remote_dir="$(ssh "$target" 'mktemp -d /tmp/flightdesk-deploy.XXXXXX')"
trap 'ssh "$target" "rm -rf -- \"$remote_dir\"" >/dev/null 2>&1 || true' EXIT
scp -q "$bin" "$target:$remote_dir/flightdesk-server"
scp -q deploy/flightdesk-server.service deploy/flightdesk.env.example deploy/nginx-flightdesk.conf \
  deploy/remote-install.sh "$target:$remote_dir/"

echo "==> installing (sudo may ask for your password)"
ssh -t "$target" "sudo bash '$remote_dir/remote-install.sh' '$remote_dir' '$area' '$domain'"
