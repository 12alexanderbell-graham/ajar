//! Writes the app icon files for packaging: `cargo run --example write_icons -- <dir>`.
fn main() {
    let dir = std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| "dist".into()));
    std::fs::create_dir_all(&dir).unwrap();
    for s in [48u32, 128, 256, 512] {
        std::fs::write(dir.join(format!("ajar-{s}.png")), ajar::icon::png(s, &ajar::icon::app(s))).unwrap();
    }
    std::fs::write(dir.join("ajar.ico"), ajar::icon::ico(&[16, 24, 32, 48, 64, 256])).unwrap();
    for (name, st) in [("tray-idle", ajar::icon::TrayState::Idle), ("tray-awake", ajar::icon::TrayState::Awake), ("tray-blocked", ajar::icon::TrayState::Blocked)] {
        std::fs::write(dir.join(format!("{name}.png")), ajar::icon::png(64, &ajar::icon::tray(st, 64))).unwrap();
    }
}
