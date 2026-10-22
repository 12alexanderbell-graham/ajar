#!/bin/sh
# Builds both release archives into dist/. Needs: rust, mingw-w64, cargo-zigbuild + zig, gtk3 dev headers.
set -eu
cd "$(dirname "$0")/.."
V=$(grep '^version' Cargo.toml | head -1 | cut -d'"' -f2)
cargo test --lib -q
PKG_CONFIG_ALLOW_CROSS=1 cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.31
cargo build --release --target x86_64-pc-windows-gnu
mkdir -p dist
L=dist/ajar-linux-x86_64; W=dist/Ajar-windows-x86_64
rm -rf "$L" "$W"
mkdir -p "$L/icons" "$W"
cp target/x86_64-unknown-linux-gnu/release/ajar target/x86_64-unknown-linux-gnu/release/ajar-app packaging/linux/install.sh packaging/linux/ajar-power README.md "$L/"
cargo run -q --example write_icons -- "$L/icons"
cp target/x86_64-pc-windows-gnu/release/ajar-app.exe target/x86_64-pc-windows-gnu/release/ajar.exe "$W/"
sed 's/$/\r/' README.md > "$W/README.txt"
chmod +x "$L/install.sh" "$L/ajar-power" "$L/ajar" "$L/ajar-app"
tar -C dist -czf "dist/ajar-$V-linux-x86_64.tar.gz" ajar-linux-x86_64
(cd dist && zip -qr "Ajar-$V-windows-x86_64.zip" Ajar-windows-x86_64)
(cd dist && sha256sum "ajar-$V-linux-x86_64.tar.gz" "Ajar-$V-windows-x86_64.zip" > SHA256SUMS)
ls -la dist
