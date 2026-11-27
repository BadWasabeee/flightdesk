#!/bin/zsh
# Build, sign and install FlightDesk (menu-bar app + desktop widget).
#
#   ./build.sh              build Release, install to ~/Applications and launch
#   ./build.sh --no-open    build and install only
#   ./build.sh --test       run the unit tests and check the iPhone app builds (simulator, unsigned)
#   ./build.sh --ios        build the iPhone app for the simulator, install it on a booted iPhone
#                           simulator (booting one if needed) and launch it
set -euo pipefail
cd "$(dirname "$0")"

die() { print -u2 "error: $*"; exit 1; }

command -v xcodegen >/dev/null || die "xcodegen not found — install it with: brew install xcodegen"

# WidgetKit and App Intents need full Xcode 26+, not just the Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app ~/Downloads/Xcode-beta.app; do
    [[ -d "$x" ]] && export DEVELOPER_DIR="$x/Contents/Developer" && break
  done
  xcodebuild -version >/dev/null 2>&1 || die "Xcode not found. Install Xcode 26 or later."
fi

# Widgets must be signed with a real team. Create Config/Local.xcconfig from your
# Apple Development certificate on first run.
if [[ ! -f Config/Local.xcconfig && "${1:-}" != "--test" && "${1:-}" != "--ios" ]]; then
  team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
         | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
  [[ -n "$team" ]] || die "No Apple Development certificate found. Sign in to Xcode › Settings › Accounts, create one, then re-run (or create Config/Local.xcconfig with DEVELOPMENT_TEAM = <TeamID>)."
  print "DEVELOPMENT_TEAM = $team" > Config/Local.xcconfig
  print "Created Config/Local.xcconfig for team $team"
fi

xcodegen generate --quiet

if [[ "${1:-}" == "--test" ]]; then
  xcodebuild -project FlightDesk.xcodeproj -scheme FlightDesk -destination 'platform=macOS' \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO test -quiet
  print "Tests passed"
  xcodebuild -project FlightDesk.xcodeproj -scheme FlightDeskiOS -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build -quiet
  print "iPhone app builds"
  exit 0
fi

if [[ "${1:-}" == "--ios" ]]; then
  IOS_ID="$(sed -n 's/^BUNDLE_ID_PREFIX *= *//p' Config/Local.xcconfig 2>/dev/null | tail -1)"
  [[ -n "$IOS_ID" ]] || IOS_ID="$(sed -n 's/^BUNDLE_ID_PREFIX *= *//p' Config/Base.xcconfig | tail -1)"
  IOS_ID="$IOS_ID.flightdesk.ios"
  # A booted iPhone simulator, else boot one (prefer iPhone 17 Pro on the newest iOS).
  udid=$(xcrun simctl list devices booted | sed -n 's/^ *iPhone[^(]*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)
  if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl list devices available | awk '/^-- iOS/{os=$0} /iPhone 17 Pro \(/{print os "|" $0}' \
           | sort -t'|' -k1,1V | tail -1 | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')
    [[ -n "$udid" ]] || udid=$(xcrun simctl list devices available | sed -n 's/^ *iPhone[^(]*(\([0-9A-F-]\{36\}\)).*/\1/p' | tail -1)
    [[ -n "$udid" ]] || die "No iPhone simulator found. Add one in Xcode › Settings › Components."
    xcrun simctl boot "$udid"
    open "${DEVELOPER_DIR:-$(xcode-select -p)}/Applications/Simulator.app" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
  fi
  xcodebuild -project FlightDesk.xcodeproj -scheme FlightDeskiOS -configuration Debug \
    -destination "id=$udid" -derivedDataPath build build -quiet
  xcrun simctl install "$udid" build/Build/Products/Debug-iphonesimulator/FlightDesk.app
  xcrun simctl launch --terminate-running-process "$udid" "$IOS_ID" >/dev/null
  print "Running FlightDesk on the simulator ($udid)"
  exit 0
fi

xcodebuild -project FlightDesk.xcodeproj -scheme FlightDesk -configuration Release \
  -derivedDataPath build -destination 'platform=macOS' build -quiet

APP="build/Build/Products/Release/FlightDesk.app"
mkdir -p ~/Applications
pkill -x FlightDesk 2>/dev/null || true
rm -rf ~/Applications/FlightDesk.app
cp -R "$APP" ~/Applications/
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Forget the copies in build/ so Finder, Spotlight and the widget gallery use the installed app (and its icon).
for c in Debug Release; do [[ -d "build/Build/Products/$c/FlightDesk.app" ]] && "$LSR" -u "build/Build/Products/$c/FlightDesk.app" 2>/dev/null || true; done
touch ~/Applications/FlightDesk.app
"$LSR" -f ~/Applications/FlightDesk.app
print "Installed ~/Applications/FlightDesk.app"
[[ "${1:-}" == "--no-open" ]] || open ~/Applications/FlightDesk.app
