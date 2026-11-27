#!/usr/bin/env bash
# Runs on the server as root, invoked by deploy.sh:  remote-install.sh DIR AREA DOMAIN
# DIR holds the uploaded files; AREA is "lat,lon,nm" or ""; DOMAIN is an nginx host name or "".
set -euo pipefail

dir="$1" area="${2:-}" domain="${3:-}"
bin=/usr/local/bin/flightdesk-server
unit=/etc/systemd/system/flightdesk-server.service
conf_dir=/etc/flightdesk
conf="$conf_dir/flightdesk.env"
site_name=flightdesk-server.conf
port=8787

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemd is required" >&2; exit 1; }

# 1. Binary (atomic replace; the running process keeps its old inode until restart).
install -m 0755 -o root -g root "$dir/flightdesk-server" "$bin.new"
mv -f "$bin.new" "$bin"
echo "installed $bin ($("$bin" version))"

# 2. Unit.
install -m 0644 -o root -g root "$dir/flightdesk-server.service" "$unit"

# 3. Config: created once, never overwritten.
install -d -m 0750 -o root -g root "$conf_dir"
new_token=""
if [[ -e "$conf" ]]; then
  echo "keeping existing $conf (token unchanged)"
else
  new_token="$("$bin" token)"
  umask 077
  sed "s/^FLIGHTDESK_TOKEN=.*/FLIGHTDESK_TOKEN=$new_token/" "$dir/flightdesk.env.example" > "$conf.tmp"
  if [[ -n "$area" ]]; then
    IFS=, read -r lat lon nm <<<"$area"
    sed -i -e "s/^FLIGHTDESK_CENTER_LAT=.*/FLIGHTDESK_CENTER_LAT=$lat/" \
           -e "s/^FLIGHTDESK_CENTER_LON=.*/FLIGHTDESK_CENTER_LON=$lon/" \
           -e "s/^FLIGHTDESK_RADIUS_NM=.*/FLIGHTDESK_RADIUS_NM=$nm/" "$conf.tmp"
  fi
  chown root:root "$conf.tmp"
  chmod 0600 "$conf.tmp"
  mv "$conf.tmp" "$conf"
  echo "created $conf"
fi
chmod 0600 "$conf"
if ! "$bin" check -config "$conf"; then
  echo "configuration is invalid; fix $conf and run: systemctl restart flightdesk-server" >&2
  systemctl daemon-reload
  exit 1
fi

# 4. Port check: refuse to fight another program for the port.
if command -v ss >/dev/null && ss -Hltnp "sport = :$port" 2>/dev/null | grep -q . ; then
  if ! ss -Hltnp "sport = :$port" | grep -q flightdesk; then
    echo "port $port is used by another program:" >&2
    ss -Hltnp "sport = :$port" >&2
    echo "set FLIGHTDESK_LISTEN in $conf to a free port (and the nginx upstream to match)" >&2
    exit 1
  fi
fi

# 5. Service.
systemctl daemon-reload
systemctl enable flightdesk-server >/dev/null
systemctl restart flightdesk-server
listen="$(sed -n 's/^FLIGHTDESK_LISTEN=//p' "$conf" | tail -1)"
listen="${listen:-127.0.0.1:$port}"
ok=0
for _ in $(seq 1 20); do
  if command -v curl >/dev/null; then
    curl -fsS "http://$listen/healthz" >/dev/null 2>&1 && { ok=1; break; }
  elif systemctl is-active --quiet flightdesk-server; then
    sleep 2; systemctl is-active --quiet flightdesk-server && { ok=1; break; }
  fi
  sleep 0.5
done
if [[ $ok -eq 1 ]]; then
  echo "flightdesk-server is running on $listen"
else
  echo "flightdesk-server did not answer on $listen; recent logs:" >&2
  journalctl -u flightdesk-server -n 30 --no-pager >&2 || true
  exit 1
fi

# 6. nginx site (optional): only ever our own file, never overwritten, rolled back if nginx -t fails.
if [[ -n "$domain" ]]; then
  if ! command -v nginx >/dev/null; then
    echo "nginx not installed; skipping the site" >&2
  else
    avail="/etc/nginx/sites-available/$site_name"
    enabled="/etc/nginx/sites-enabled/$site_name"
    created_avail=0 created_link=0
    if [[ -e "$avail" ]]; then
      echo "keeping existing $avail"
    else
      sed "s/__DOMAIN__/$domain/g" "$dir/nginx-flightdesk.conf" > "$avail"
      chmod 0644 "$avail"
      created_avail=1
      echo "created $avail"
    fi
    if [[ ! -e "$enabled" ]]; then
      ln -s "$avail" "$enabled"
      created_link=1
    fi
    if nginx -t 2>/tmp/flightdesk-nginx-test.log; then
      systemctl reload nginx
      echo "nginx reloaded"
      if ! grep -q "listen 443" "$avail"; then
        echo
        echo "Next, add TLS (certbot edits only this site):"
        echo "  sudo certbot --nginx -d $domain --redirect"
      fi
    else
      cat /tmp/flightdesk-nginx-test.log >&2
      [[ $created_link -eq 1 ]] && rm -f "$enabled"
      [[ $created_avail -eq 1 ]] && rm -f "$avail"
      echo "nginx -t failed; the FlightDesk site was not enabled (other sites untouched)" >&2
      exit 1
    fi
  fi
fi

echo
if [[ -n "$new_token" ]]; then
  echo "New bearer token (shown once; it is stored in $conf):"
  echo "  $new_token"
else
  echo "Token: sudo grep ^FLIGHTDESK_TOKEN $conf"
fi
if ! grep -Eq '^FLIGHTDESK_RADIUS_NM=[1-9]' "$conf"; then
  echo "No area configured: set FLIGHTDESK_CENTER_LAT/LON and FLIGHTDESK_RADIUS_NM in $conf, then"
  echo "  sudo systemctl restart flightdesk-server"
fi
