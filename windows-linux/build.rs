//! Windows builds: embed the app icon and version info in both executables. The icon is drawn by the same code
//! the tray uses (src/icon.rs), so there's no image file to keep in sync.

#[allow(dead_code)]
#[path = "src/icon.rs"]
mod icon;

fn main() {
    println!("cargo:rerun-if-changed=src/icon.rs");
    println!("cargo:rerun-if-changed=build.rs");
    let target = std::env::var("TARGET").unwrap_or_default();
    if !target.contains("windows") {
        return;
    }
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let ico = out.join("nocturnal.ico");
    std::fs::write(&ico, icon::ico(&[16, 20, 24, 32, 40, 48, 64, 256])).unwrap();
    let version = env!("CARGO_PKG_VERSION");
    let v: Vec<&str> = version.split('.').collect();
    let comma = format!(
        "{},{},{},0",
        v.first().unwrap_or(&"1"),
        v.get(1).unwrap_or(&"0"),
        v.get(2).unwrap_or(&"0")
    );
    let rc = format!(
        r#"1 ICON "{ico}"
1 VERSIONINFO
FILEVERSION {comma}
PRODUCTVERSION {comma}
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "CompanyName", "Nocturnal"
      VALUE "FileDescription", "Nocturnal: keeps the laptop awake with the lid closed while AI agents work"
      VALUE "FileVersion", "{version}"
      VALUE "ProductName", "Nocturnal"
      VALUE "ProductVersion", "{version}"
      VALUE "OriginalFilename", "nocturnal-app.exe"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#,
        ico = ico.display().to_string().replace('\\', "/")
    );
    let rc_path = out.join("nocturnal.rc");
    std::fs::write(&rc_path, rc).unwrap();
    let obj = out.join("nocturnal-res.o");
    let windres = if target.contains("gnu") {
        "x86_64-w64-mingw32-windres"
    } else {
        "windres"
    };
    let ok = std::process::Command::new(windres)
        .arg(&rc_path)
        .arg("-O")
        .arg("coff")
        .arg("-o")
        .arg(&obj)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        println!("cargo:rustc-link-arg-bins={}", obj.display());
    } else {
        println!("cargo:warning=windres not found: the Windows executables will have no icon");
    }
}
