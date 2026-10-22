//! Test harness (Linux): a stand-in for systemd-logind and power-profiles-daemon on a private D-Bus, so the
//! real Linux platform code can be exercised end to end in a container without a real lid.
//!
//!   dbus-daemon --session --print-address   →  DBUS_SYSTEM_BUS_ADDRESS=<that> cargo run --example fake_logind
//!
//! Control and inspect it with `busctl --address=... call test.Fake /test test.Fake SetLid b true` etc.

use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::{Arc, Mutex};
use zbus::interface;
use zbus::zvariant::OwnedFd as ZFd;

#[derive(Default)]
struct World {
    lid_closed: bool,
    suspends: u32,
    inhibitors: Vec<(String, String, std::fs::File)>, // (what, who, read end)
    profile: String,
}

impl World {
    fn live_inhibitors(&mut self) -> usize {
        // A lock is released when its holder closes its end of the pipe (read returns 0 = EOF).
        self.inhibitors.retain_mut(|(_, _, f)| {
            let fd = f.as_raw_fd();
            let mut pfd = libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            };
            let r = unsafe { libc::poll(&mut pfd, 1, 0) };
            if r > 0 && pfd.revents & (libc::POLLIN | libc::POLLHUP) != 0 {
                let mut b = [0u8; 1];
                !matches!(f.read(&mut b), Ok(0))
            } else {
                true
            }
        });
        self.inhibitors.len()
    }
}

struct Manager(Arc<Mutex<World>>);

#[interface(name = "org.freedesktop.login1.Manager")]
impl Manager {
    fn inhibit(&self, what: &str, who: &str, _why: &str, _mode: &str) -> ZFd {
        let mut fds = [0; 2];
        unsafe { libc::pipe(fds.as_mut_ptr()) };
        let read = unsafe { std::fs::File::from_raw_fd(fds[0]) };
        self.0
            .lock()
            .unwrap()
            .inhibitors
            .push((what.into(), who.into(), read));
        ZFd::from(unsafe { OwnedFd::from_raw_fd(fds[1]) })
    }
    fn suspend(&self, _interactive: bool) {
        let mut w = self.0.lock().unwrap();
        w.suspends += 1;
        let (n, live) = (w.suspends, w.live_inhibitors());
        eprintln!("fake-logind: Suspend (#{n}) with {live} inhibitors");
    }
    #[zbus(property)]
    fn lid_closed(&self) -> bool {
        self.0.lock().unwrap().lid_closed
    }
}

struct Profiles(Arc<Mutex<World>>);

#[interface(name = "org.freedesktop.UPower.PowerProfiles")]
impl Profiles {
    #[zbus(property)]
    fn active_profile(&self) -> String {
        self.0.lock().unwrap().profile.clone()
    }
    #[zbus(property)]
    fn set_active_profile(&mut self, p: String) {
        eprintln!("fake-ppd: profile {p}");
        self.0.lock().unwrap().profile = p;
    }
}

struct Fake(Arc<Mutex<World>>);

#[interface(name = "test.Fake")]
impl Fake {
    fn set_lid(&self, closed: bool) {
        self.0.lock().unwrap().lid_closed = closed;
    }
    /// (lid closed, live inhibitors, suspends, profile)
    fn state(&self) -> (bool, u32, u32, String) {
        let mut w = self.0.lock().unwrap();
        let n = w.live_inhibitors() as u32;
        (w.lid_closed, n, w.suspends, w.profile.clone())
    }
}

fn main() -> zbus::Result<()> {
    let world = Arc::new(Mutex::new(World {
        profile: "balanced".into(),
        ..Default::default()
    }));
    let addr = std::env::var("DBUS_SYSTEM_BUS_ADDRESS")
        .expect("set DBUS_SYSTEM_BUS_ADDRESS to the private bus");
    let _conn = zbus::blocking::connection::Builder::address(addr.as_str())?
        .name("org.freedesktop.login1")?
        .name("org.freedesktop.UPower.PowerProfiles")?
        .name("test.Fake")?
        .serve_at("/org/freedesktop/login1", Manager(world.clone()))?
        .serve_at(
            "/org/freedesktop/UPower/PowerProfiles",
            Profiles(world.clone()),
        )?
        .serve_at("/test", Fake(world.clone()))?
        .build()?;
    eprintln!("fake-logind: ready");
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
