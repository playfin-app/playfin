#![deny(clippy::unwrap_used, clippy::expect_used)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

//! Playfin pure-Rust frontend for LG webOS (and macOS desktop SDL2 simulator).

pub mod app;
pub mod gl_config;
pub mod input;
pub mod platform;
pub mod sdl;
