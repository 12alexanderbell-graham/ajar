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

# Optional: let Ajar turn off turbo and switch on the kernel's power saving while the lid is closed. Needs root
# once, for a fixed helper and a sudoers entry for exactly its commands (also used for waking from sleep).
helper=/usr/local/libexec/ajar-power
if [ -t 0 ] && command -v sudo >/dev/null 2>&1 && [ ! -x "$helper" ]; then
  printf 'Save more battery with the lid closed (turbo off, kernel power saving) and allow waking from sleep for phone control? Asks for your password once. [y/N] '
  read -r answer || answer=n
  case "$answer" in
    y|Y|yes)
      user=$(id -un)
      tmp=$(mktemp)
      cmds="$helper apply, $helper restore, $helper wake off"
      for n in 60 300 900 1800 3600; do cmds="$cmds, $helper wake $n"; done
      printf '# Installed by Ajar: only these commands, nothing else.\n%s ALL=(root) NOPASSWD: %s\n' "$user" "$cmds" > "$tmp"
      if sudo sh -c "install -d -m 755 /usr/local/libexec && install -m 755 -o root -g root '$here/ajar-power' '$helper' \
          && install -m 440 -o root -g root '$tmp' /etc/sudoers.d/.ajar-power.new && visudo -cf /etc/sudoers.d/.ajar-power.new \
          && mv -f /etc/sudoers.d/.ajar-power.new /etc/sudoers.d/ajar-power"; then
        echo "Done. Ajar uses it while the lid is closed and puts everything back when it opens."
      else
        echo "Skipped: couldn't install the power helper." >&2
      fi
      rm -f "$tmp" ;;
  esac
fi

case ":$PATH:" in *":$bin:"*) ;; *) echo "Add $bin to your PATH to use the 'ajar' command.";; esac
setsid -f "$bin/ajar-app" >/dev/null 2>&1 < /dev/null
echo "Ajar is installed and running in the tray. Turn on 'Open at login' in its Settings menu."
