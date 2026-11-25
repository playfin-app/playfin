#![deny(clippy::unwrap_used, clippy::expect_used)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

use femtovg::Canvas;
use femtovg::renderer::OpenGl;
use playfin_webos::app::SimulatorApp;
use playfin_webos::gl_config::{GlSurfaceSpec, apply_sdl_gl_attributes, clear_transparent};
use playfin_webos::input::map_keycode;
use sdl2::event::Event;
use sdl2::video::SwapInterval;
use std::ffi::c_void;
use std::time::Instant;
use thiserror::Error;

const DEFAULT_FONT: &[u8] = include_bytes!("../assets/fonts/NotoSans-Regular.ttf");

#[derive(Debug, Error)]
enum WebosError {
    #[error("SDL initialization failed: {0}")]
    Sdl(String),
    #[error("OpenGL renderer initialization failed: {0}")]
    Renderer(String),
    #[error("font load failed: {0}")]
    Font(String),
}

fn run() -> Result<(), WebosError> {
    let sdl = sdl2::init().map_err(WebosError::Sdl)?;
    let video = sdl.video().map_err(WebosError::Sdl)?;

    let gl_spec = GlSurfaceSpec::default();
    apply_sdl_gl_attributes(&video.gl_attr(), &gl_spec);

    let window = video
        .window("Playfin webOS Simulator", 1280, 720)
        .position_centered()
        .resizable()
        .opengl()
        .allow_highdpi()
        .build()
        .map_err(|e| WebosError::Sdl(e.to_string()))?;

    let _gl_ctx = window.gl_create_context().map_err(WebosError::Sdl)?;
    let _ = video.gl_set_swap_interval(SwapInterval::VSync);

    // SAFETY: GL context is current on this thread and remains live for the duration of the loop.
    let gl = unsafe {
        glow::Context::from_loader_function(|s| video.gl_get_proc_address(s) as *const c_void)
    };
    // SAFETY: GL context is current on this thread.
    let renderer = unsafe {
        OpenGl::new_from_function(|s| video.gl_get_proc_address(s) as *const c_void)
            .map_err(|e| WebosError::Renderer(e.to_string()))?
    };

    let mut canvas = Canvas::new(renderer).map_err(|e| WebosError::Renderer(e.to_string()))?;
    let font = canvas
        .add_font_mem(DEFAULT_FONT)
        .map_err(|e| WebosError::Font(e.to_string()))?;

    let mut event_pump = sdl.event_pump().map_err(WebosError::Sdl)?;
    let mut app = SimulatorApp::default();
    let mut last_frame = Instant::now();
    let max_frames = std::env::var("PLAYFIN_WEBOS_SMOKE_FRAMES")
        .ok()
        .and_then(|v| v.parse::<u64>().ok());
    let mut rendered_frames: u64 = 0;

    'running: loop {
        let now = Instant::now();
        let dt = now.saturating_duration_since(last_frame).as_secs_f32();
        last_frame = now;

        for event in event_pump.poll_iter() {
            match event {
                Event::Quit { .. } => break 'running,
                Event::KeyDown {
                    keycode: Some(code),
                    ..
                } => {
                    if let Some(action) = map_keycode(code)
                        && !app.handle_action(action)
                    {
                        break 'running;
                    }
                }
                _ => {}
            }
        }

        app.tick(dt);
        let (w, h) = window.drawable_size();
        clear_transparent(&gl, &gl_spec);
        app.render(&mut canvas, font, w, h);
        window.gl_swap_window();

        rendered_frames += 1;
        if let Some(limit) = max_frames
            && rendered_frames >= limit
        {
            break 'running;
        }
    }

    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("playfin_webos fatal error: {err}");
        std::process::exit(1);
    }
}
