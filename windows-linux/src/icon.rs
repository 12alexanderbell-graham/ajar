//! The Ajar mark, drawn in code so every size is crisp and there is no image file to ship or lose:
//! one thin bar (the base) and a translucent fan opening 35° from its left end (the lid, ajar).
//!
//! `tray(state, size)` gives the small status icon; `app(size)` the amber app icon used for the Windows
//! executable, the Linux .desktop entry and notifications.

/// Amber, the same family as the macOS icon.
pub const AMBER: [u8; 3] = [0xF2, 0xA1, 0x2C];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayState {
    /// Not holding: the machine will sleep normally.
    Idle,
    /// Holding: closing the lid keeps it working.
    Awake,
    /// Wanted to hold but something stopped it (battery limit, heat, setup).
    Blocked,
}

/// Geometry in unit coordinates (0..1, y down), shared by both icons.
struct Mark {
    bar_x0: f64,
    bar_x1: f64,
    bar_y: f64,
    bar_half: f64,
    hinge_x: f64,
    hinge_y: f64,
    radius: f64,
    angle: f64,
}

impl Mark {
    fn standard() -> Mark {
        let angle = 35f64.to_radians();
        let (bar_x0, bar_x1, bar_half) = (0.10, 0.90, 0.055);
        let radius = 0.74;
        // Vertically centre the whole mark (fan top to bar bottom).
        let fan_h = radius * angle.sin();
        let total = fan_h + 2.0 * bar_half;
        let top = (1.0 - total) / 2.0;
        let bar_y = top + fan_h + bar_half;
        Mark { bar_x0, bar_x1, bar_y, bar_half, hinge_x: bar_x0 + bar_half, hinge_y: bar_y - bar_half, radius, angle }
    }

    /// Coverage of the bar (rounded ends) and of the fan at a point.
    fn hit(&self, x: f64, y: f64) -> (bool, bool) {
        let r = self.bar_half;
        let cx = x.clamp(self.bar_x0 + r, self.bar_x1 - r);
        let bar = (x - cx).powi(2) + (y - self.bar_y).powi(2) <= r * r;
        let (dx, dy) = (x - self.hinge_x, self.hinge_y - y);
        let dist = (dx * dx + dy * dy).sqrt();
        let a = dy.atan2(dx);
        let fan = dist <= self.radius && dy >= 0.0 && a >= 0.0 && a <= self.angle;
        (bar, fan)
    }
}

fn blend(dst: &mut [f64; 4], rgb: [u8; 3], alpha: f64) {
    // Straight-alpha "over" in linear-ish space; good enough for flat shapes.
    let a = alpha + dst[3] * (1.0 - alpha);
    if a <= 0.0 {
        return;
    }
    for i in 0..3 {
        let c = rgb[i] as f64 / 255.0;
        dst[i] = (c * alpha + dst[i] * dst[3] * (1.0 - alpha)) / a;
    }
    dst[3] = a;
}

/// Renders with 4×4 supersampling. `paint(x, y, &mut px)` draws one sample in unit coordinates.
fn render(size: u32, paint: impl Fn(f64, f64, &mut [f64; 4])) -> Vec<u8> {
    let n = 4;
    let mut out = Vec::with_capacity((size * size * 4) as usize);
    for py in 0..size {
        for px in 0..size {
            let mut acc = [0.0f64; 4];
            for sy in 0..n {
                for sx in 0..n {
                    let x = (px as f64 + (sx as f64 + 0.5) / n as f64) / size as f64;
                    let y = (py as f64 + (sy as f64 + 0.5) / n as f64) / size as f64;
                    let mut s = [0.0f64; 4];
                    paint(x, y, &mut s);
                    // Premultiply while averaging so edges don't pick up dark fringes.
                    for i in 0..3 {
                        acc[i] += s[i] * s[3];
                    }
                    acc[3] += s[3];
                }
            }
            let samples = (n * n) as f64;
            let a = acc[3] / samples;
            for i in 0..3 {
                let c = if acc[3] > 0.0 { acc[i] / acc[3] } else { 0.0 };
                out.push((c * 255.0).round().clamp(0.0, 255.0) as u8);
            }
            out.push((a * 255.0).round().clamp(0.0, 255.0) as u8);
        }
    }
    out
}

/// Status icon, RGBA, `size`×`size`. Grey when idle (reads on light and dark taskbars), amber when awake,
/// and amber with a hollow fan when blocked.
pub fn tray(state: TrayState, size: u32) -> Vec<u8> {
    let m = Mark::standard();
    let (color, fan_alpha) = match state {
        TrayState::Idle => ([0x8E, 0x8E, 0x93], 0.40),
        TrayState::Awake => (AMBER, 0.55),
        TrayState::Blocked => (AMBER, 0.0),
    };
    render(size, |x, y, px| {
        let (bar, fan) = m.hit(x, y);
        if fan && fan_alpha > 0.0 {
            blend(px, color, fan_alpha);
        }
        if state == TrayState::Blocked && fan {
            // Just the fan's arc edge, so "wanted to stay awake but can't" is visible at a glance.
            let d = ((x - m.hinge_x).powi(2) + (m.hinge_y - y).powi(2)).sqrt();
            if d > m.radius - 0.09 {
                blend(px, color, 0.9);
            }
        }
        if bar {
            blend(px, color, 1.0);
        }
    })
}

/// App icon: amber rounded tile with the mark in white. RGBA.
pub fn app(size: u32) -> Vec<u8> {
    let m = Mark::standard();
    let (inset, corner) = (0.04, 0.2);
    let scale = 0.62;
    render(size, |x, y, px| {
        // Rounded-square tile.
        let (lo, hi) = (inset + corner, 1.0 - inset - corner);
        let (cx, cy) = (x.clamp(lo, hi), y.clamp(lo, hi));
        if (x - cx).powi(2) + (y - cy).powi(2) > corner * corner {
            return;
        }
        blend(px, AMBER, 1.0);
        let (ux, uy) = ((x - 0.5) / scale + 0.5, (y - 0.5) / scale + 0.5);
        let (bar, fan) = m.hit(ux, uy);
        if fan {
            blend(px, [255, 255, 255], 0.55);
        }
        if bar {
            blend(px, [255, 255, 255], 1.0);
        }
    })
}

/// A minimal PNG encoder (stored deflate blocks), so writing an icon file needs no image crate.
pub fn png(size: u32, rgba: &[u8]) -> Vec<u8> {
    fn crc32(data: &[u8]) -> u32 {
        let mut c = 0xFFFF_FFFFu32;
        for &b in data {
            c ^= b as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            }
        }
        !c
    }
    fn adler(data: &[u8]) -> u32 {
        let (mut a, mut b) = (1u32, 0u32);
        for &x in data {
            a = (a + x as u32) % 65521;
            b = (b + a) % 65521;
        }
        (b << 16) | a
    }
    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend((data.len() as u32).to_be_bytes());
        let mut body = kind.to_vec();
        body.extend_from_slice(data);
        out.extend_from_slice(&body);
        out.extend(crc32(&body).to_be_bytes());
    }
    let mut raw = Vec::with_capacity(rgba.len() + size as usize);
    for row in rgba.chunks((size * 4) as usize) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    let mut z = vec![0x78, 0x01];
    let mut blocks = raw.chunks(65535).peekable();
    while let Some(b) = blocks.next() {
        z.push(if blocks.peek().is_none() { 1 } else { 0 });
        z.extend((b.len() as u16).to_le_bytes());
        z.extend((!(b.len() as u16)).to_le_bytes());
        z.extend_from_slice(b);
    }
    z.extend(adler(&raw).to_be_bytes());
    let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    let mut ihdr = vec![];
    ihdr.extend(size.to_be_bytes());
    ihdr.extend(size.to_be_bytes());
    ihdr.extend([8, 6, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}

/// A Windows .ico holding PNG-compressed images at the given sizes.
pub fn ico(sizes: &[u32]) -> Vec<u8> {
    let images: Vec<(u32, Vec<u8>)> = sizes.iter().map(|&s| (s, png(s, &app(s)))).collect();
    let mut out = vec![0, 0, 1, 0];
    out.extend((images.len() as u16).to_le_bytes());
    let mut offset = 6 + 16 * images.len() as u32;
    for (s, data) in &images {
        let d = if *s >= 256 { 0 } else { *s as u8 };
        out.extend([d, d, 0, 0]);
        out.extend(1u16.to_le_bytes());
        out.extend(32u16.to_le_bytes());
        out.extend((data.len() as u32).to_le_bytes());
        out.extend(offset.to_le_bytes());
        offset += data.len() as u32;
    }
    for (_, data) in images {
        out.extend(data);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mark_is_centred_and_inside_the_canvas() {
        let m = Mark::standard();
        let top = m.hinge_y - m.radius * m.angle.sin();
        let bottom = m.bar_y + m.bar_half;
        assert!((top - (1.0 - bottom)).abs() < 1e-9, "top {top} bottom {bottom}");
        let right = m.hinge_x + m.radius * m.angle.cos();
        assert!(right <= m.bar_x1 + 1e-9, "fan must not overhang the bar");
    }

    #[test]
    fn icons_have_the_right_size_and_some_ink() {
        for s in [16, 22, 32] {
            for st in [TrayState::Idle, TrayState::Awake, TrayState::Blocked] {
                let px = tray(st, s);
                assert_eq!(px.len(), (s * s * 4) as usize);
                assert!(px.chunks(4).any(|p| p[3] > 200), "{st:?} at {s}px has no solid pixels");
                // Corners stay transparent.
                assert_eq!(px[3], 0);
            }
        }
        let a = app(64);
        assert_eq!(&a[(32 * 64 + 32) * 4 + 3], &255);
    }

    #[test]
    fn png_and_ico_are_well_formed() {
        let p = png(16, &tray(TrayState::Awake, 16));
        assert_eq!(&p[1..4], b"PNG");
        assert_eq!(&p[p.len() - 8..p.len() - 4], b"IEND");
        let i = ico(&[16, 32, 256]);
        assert_eq!(u16::from_le_bytes([i[4], i[5]]), 3);
        assert_eq!(i[6 + 32], 0, "256 px is written as 0 in the directory");
    }
}
