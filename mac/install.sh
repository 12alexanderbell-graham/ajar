#!/bin/sh
# Builds Ajar (Release, universal) and swaps it into /Applications without losing anything:
#  1. build into a temp folder; stop here if the build fails
#  2. ask the running Ajar to quit normally (it puts back every app and setting it changed as it quits)
#  3. copy the new app next to the old one, then swap them with two renames
#  4. move the old copy to _to_delete/ next to this script (nothing is deleted), and open the new one
# Also leaves the build as dist/Ajar-<version>-mac.zip.
# Log: install.log next to this file.
cd "$(dirname "$0")"
exec > install.log 2>&1
set -e
echo "start $(date)"
DD="${TMPDIR:-/tmp}/ajar-release"
/usr/bin/xcodebuild -project Ajar.xcodeproj -scheme Ajar -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY=- build | tail -3
NEW="$DD/Build/Products/Release/Ajar.app"
[ -x "$NEW/Contents/MacOS/Ajar" ] || { echo "build produced no app"; exit 1; }
# The same build as a zip for the website and Homebrew (ad-hoc signed; release.sh makes the notarized one).
V=$(/usr/bin/defaults read "$NEW/Contents/Info" CFBundleShortVersionString)
mkdir -p dist
/usr/bin/ditto -c -k --keepParent "$NEW" "dist/Ajar-$V-mac.zip"
/usr/bin/shasum -a 256 "dist/Ajar-$V-mac.zip"

# Graceful quit through Ajar's own command channel (no Automation permission needed); the app restores
# everything as it quits. Note: with the lid closed, quitting Ajar lets the Mac sleep.
running() { /usr/bin/pgrep -qf "Ajar.app/Contents/MacOS/Ajar$"; }
if running; then
  /Applications/Ajar.app/Contents/MacOS/Ajar cli rescue || true
  for i in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 1; done
  # Still there: an idle second copy, or a version that can't be asked to quit. Rescue has already put every
  # setting back, so stopping the process is safe.
  if running; then /usr/bin/pkill -TERM -f "/Applications/Ajar.app/Contents/MacOS/Ajar$"; sleep 3; fi
  if running; then /usr/bin/pkill -KILL -f "/Applications/Ajar.app/Contents/MacOS/Ajar$"; sleep 1; fi
fi

rm -rf /Applications/Ajar.app.new
cp -R "$NEW" /Applications/Ajar.app.new
mkdir -p _to_delete
STAMP=$(date +%Y%m%d-%H%M%S)
if [ -d /Applications/Ajar.app ]; then mv /Applications/Ajar.app "_to_delete/Ajar-$STAMP.app"; fi
mv /Applications/Ajar.app.new /Applications/Ajar.app
sleep 2   # let macOS forget the old process, or the new copy would see it and wait
if running; then
  echo "NOTE: the old Ajar is still running. Quit it from its menu and open Ajar again to start the new version."
else
  /usr/bin/env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open /Applications/Ajar.app   # clean environment
fi
echo "done $(date) (previous version kept in _to_delete/Ajar-$STAMP.app)"
