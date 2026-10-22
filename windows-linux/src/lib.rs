//! Nocturnal for Windows and Linux.
//!
//! The same product as the macOS app: keep a laptop awake with the lid closed while AI agents (or anything
//! the person picks) are working, save battery while it's shut, and let it sleep when the work is done.
//! The decision logic lives in `engine` and is platform-free (unit-tested with a mock platform); everything
//! that touches the OS lives behind the `platform::Platform` trait.

pub mod agents;
pub mod ai;
pub mod approve;
pub mod config;
pub mod engine;
pub mod format;
pub mod icon;
pub mod ipc;
pub mod mcp;
pub mod menu;
pub mod platform;
pub mod procs;
pub mod remote;
pub mod state;
pub mod wake;

/// Seconds since the Unix epoch. All stored times use this so files stay portable and easy to read.
pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
