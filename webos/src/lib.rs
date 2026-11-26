#![deny(clippy::unwrap_used, clippy::expect_used)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

//! Playfin pure-Rust frontend for LG webOS (and macOS desktop SDL2 simulator).

pub mod app;
pub mod exported_window;
pub mod gl_config;
pub mod input;
pub mod luna;
pub mod platform;
pub mod sdl;
pub mod spike_config;
pub mod starfish;
