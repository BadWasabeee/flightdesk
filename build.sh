#!/bin/zsh
# Build, sign and install FlightDesk (menu-bar app + desktop widget).
#
#   ./build.sh              build Release, install to ~/Applications and launch
#   ./build.sh --no-open    build and install only
#   ./build.sh --test       run the unit tests
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
if [[ ! -f Config/Local.xcconfig && "${1:-}" != "--test" ]]; then
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
