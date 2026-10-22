//! Writes the app icon files for packaging: `cargo run --example write_icons -- <dir>`.
fn main() {
    let dir = std::path::PathBuf::from(std::env::args().nth(1).unwrap_or_else(|| "dist".into()));
    std::fs::create_dir_all(&dir).unwrap();
    for s in [48u32, 128, 256, 512] {
        std::fs::write(
            dir.join(format!("nocturnal-{s}.png")),
            nocturnal::icon::png(s, &nocturnal::icon::app(s)),
        )
        .unwrap();
    }
    std::fs::write(
        dir.join("nocturnal.ico"),
        nocturnal::icon::ico(&[16, 24, 32, 48, 64, 256]),
    )
    .unwrap();
    for (name, st) in [
        ("tray-idle", nocturnal::icon::TrayState::Idle),
        ("tray-awake", nocturnal::icon::TrayState::Awake),
        ("tray-blocked", nocturnal::icon::TrayState::Blocked),
    ] {
        std::fs::write(
            dir.join(format!("{name}.png")),
            nocturnal::icon::png(64, &nocturnal::icon::tray(st, 64)),
        )
        .unwrap();
    }
}
