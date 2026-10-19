#!/bin/sh
# Installs Ajar for the current user (no root needed): binaries in ~/.local/bin, a launcher entry, the icon,
# and the watchdog timer. Run again to update.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin="$HOME/.local/bin"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"

if ! command -v systemctl >/dev/null 2>&1 || ! busctl --system status org.freedesktop.login1 >/dev/null 2>&1; then
  echo "Ajar needs systemd-logind to keep the machine awake, and it isn't available here." >&2
  exit 1
fi
if ! ldconfig -p 2>/dev/null | grep -q -e libayatana-appindicator3 -e libappindicator3; then
  echo "Note: the tray icon needs the AppIndicator library:"
  echo "  Ubuntu/Debian/Mint:  sudo apt install libayatana-appindicator3-1"
  echo "  Fedora:              sudo dnf install libayatana-appindicator-gtk3"
  echo "  Arch:                sudo pacman -S libayatana-appindicator"
  echo "  GNOME also needs the 'AppIndicator and KStatusNotifierItem Support' extension to show tray icons."
fi

# Stop a running copy gracefully (it puts back anything it changed) before replacing the files.
if [ -x "$bin/ajar" ]; then "$bin/ajar" rescue >/dev/null 2>&1 || true; fi

mkdir -p "$bin" "$apps" "$icons/256x256/apps" "$icons/128x128/apps" "$icons/48x48/apps"
install -m 755 "$here/ajar" "$here/ajar-app" "$bin/"
install -m 644 "$here/icons/ajar-256.png" "$icons/256x256/apps/ajar.png"
install -m 644 "$here/icons/ajar-128.png" "$icons/128x128/apps/ajar.png"
install -m 644 "$here/icons/ajar-48.png" "$icons/48x48/apps/ajar.png"
cat > "$apps/ajar.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Ajar
Comment=Keep the laptop awake with the lid closed while AI agents work
Exec="$bin/ajar-app"
Icon=ajar
Terminal=false
Categories=Utility;
StartupNotify=false
EOF
"$bin/ajar" install || echo "Couldn't register the watchdog; run 'ajar install' later." >&2

case ":$PATH:" in *":$bin:"*) ;; *) echo "Add $bin to your PATH to use the 'ajar' command.";; esac
setsid -f "$bin/ajar-app" >/dev/null 2>&1 < /dev/null
echo "Ajar is installed and running in the tray. Turn on 'Open at login' in its Settings menu."
