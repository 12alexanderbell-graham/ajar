#!/bin/sh
# Builds both release archives into dist/. Needs: rust, mingw-w64, cargo-zigbuild + zig, gtk3 dev headers.
set -eu
cd "$(dirname "$0")/.."
V=$(grep '^version' Cargo.toml | head -1 | cut -d'"' -f2)
cargo test --lib -q
PKG_CONFIG_ALLOW_CROSS=1 cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.31
cargo build --release --target x86_64-pc-windows-gnu
mkdir -p dist
L=dist/nocturnal-linux-x86_64; W=dist/Nocturnal-windows-x86_64
rm -rf "$L" "$W"
mkdir -p "$L/icons" "$W"
cp target/x86_64-unknown-linux-gnu/release/nocturnal target/x86_64-unknown-linux-gnu/release/nocturnal-app packaging/linux/install.sh packaging/linux/nocturnal-power README.md "$L/"
cargo run -q --example write_icons -- "$L/icons"
cp target/x86_64-pc-windows-gnu/release/nocturnal-app.exe target/x86_64-pc-windows-gnu/release/nocturnal.exe "$W/"
sed 's/$/\r/' README.md > "$W/README.txt"
chmod +x "$L/install.sh" "$L/nocturnal-power" "$L/nocturnal" "$L/nocturnal-app"
tar -C dist -czf "dist/nocturnal-$V-linux-x86_64.tar.gz" nocturnal-linux-x86_64
(cd dist && zip -qr "Nocturnal-$V-windows-x86_64.zip" Nocturnal-windows-x86_64)
(cd dist && sha256sum "nocturnal-$V-linux-x86_64.tar.gz" "Nocturnal-$V-windows-x86_64.zip" > SHA256SUMS)
ls -la dist
