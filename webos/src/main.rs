#![deny(clippy::unwrap_used, clippy::expect_used)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

use femtovg::Canvas;
use femtovg::renderer::OpenGl;
use playfin_core::{ClientIdentity, JellyfinClient, probe_https_status};
use playfin_webos::app::{Gate1Diagnostics, SimulatorApp};
use playfin_webos::gl_config::{GlSurfaceSpec, clear_transparent};
use playfin_webos::input::map_key_input;
use playfin_webos::platform::{LaunchContext, resolve_persistent_data_dir};
use playfin_webos::sdl::{SdlContext, SdlEvent, set_hint};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use thiserror::Error;

const DEFAULT_FONT: &[u8] = include_bytes!("../assets/fonts/NotoSans-Regular.ttf");
const TLS_PROBE_URL: &str = "https://jellyfin.org";

#[derive(Debug, Error)]
enum WebosError {
    #[error("SDL initialization failed: {0}")]
    Sdl(String),
    #[error("OpenGL renderer initialization failed: {0}")]
    Renderer(String),
    #[error("font load failed: {0}")]
    Font(String),
    #[error("Tokio runtime failed: {0}")]
    Runtime(String),
}

fn spawn_https_probe() -> Result<(tokio::runtime::Runtime, mpsc::Receiver<String>), WebosError> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| WebosError::Runtime(e.to_string()))?;

    let (tx, rx) = mpsc::channel();
    rt.spawn(async move {
        let status = match probe_https_status(TLS_PROBE_URL).await {
            Ok(code) => format!("OK (HTTP {code})"),
            Err(err) => format!("FAIL: {err}"),
        };
        let _ = tx.send(status);
    });
    Ok((rt, rx))
}

fn build_initial_diagnostics() -> Gate1Diagnostics {
    let ctx = LaunchContext::from_env(std::env::args());
    let storage = resolve_persistent_data_dir(&ctx);
    let data_dir_str = storage.data_dir.to_string_lossy().to_string();
    let client = JellyfinClient::new_with_identity(
        "http://localhost:8096",
        &data_dir_str,
        ClientIdentity::new("Playfin", "LG webOS"),
    );

    let diag = Gate1Diagnostics {
        device_id: client.device_id().to_string(),
        data_dir: data_dir_str,
        storage_note: storage.note,
        survives_reinstall: storage.survives_reinstall,
        home_env: ctx.home_env.unwrap_or_else(|| "unset".to_string()),
        xdg_data_env: ctx.xdg_data_env.unwrap_or_else(|| "unset".to_string()),
        argv1_preview: ctx.argv1_preview,
        ..Gate1Diagnostics::default()
    };

    eprintln!(
        "[playfin_webos] gate1 init: device_id={} data_dir={} ({}, persistent={}) HOME={} XDG_DATA_HOME={} argv1={}",
        diag.device_id,
        diag.data_dir,
        diag.storage_note,
        diag.survives_reinstall,
        diag.home_env,
        diag.xdg_data_env,
        diag.argv1_preview
    );
    diag
}

fn run() -> Result<(), WebosError> {
    let diagnostics = build_initial_diagnostics();
    let (_rt, https_rx) = spawn_https_probe()?;

    if cfg!(feature = "webos") {
        set_hint("SDL_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
    }

    let sdl = SdlContext::init_video().map_err(WebosError::Sdl)?;
    let gl_spec = GlSurfaceSpec::default();
    let (init_w, init_h) = if cfg!(feature = "webos") {
        (1920, 1080)
    } else {
        (1280, 720)
    };
    let window = sdl
        .create_gl_window("Playfin webOS", init_w, init_h, &gl_spec)
        .map_err(WebosError::Sdl)?;
    window.set_vsync(true);

    // SAFETY: GL context is current on this thread and remains live for the duration of the loop.
    let gl = unsafe { glow::Context::from_loader_function(|s| window.gl_get_proc_address(s)) };
    // SAFETY: GL context is current on this thread.
    let renderer = unsafe {
        OpenGl::new_from_function(|s| window.gl_get_proc_address(s))
            .map_err(|e| WebosError::Renderer(e.to_string()))?
    };

    let mut canvas = Canvas::new(renderer).map_err(|e| WebosError::Renderer(e.to_string()))?;
    let font = canvas
        .add_font_mem(DEFAULT_FONT)
        .map_err(|e| WebosError::Font(e.to_string()))?;

    let mut app = SimulatorApp::new(playfin_core::core_version(), diagnostics);
    let mut last_frame = Instant::now();
    let mut fps_window_start = Instant::now();
    let mut fps_frames: u32 = 0;

    let max_frames = std::env::var("PLAYFIN_WEBOS_SMOKE_FRAMES")
        .ok()
        .and_then(|v| v.parse::<u64>().ok());
    let mut rendered_frames: u64 = 0;

    'running: loop {
        let now = Instant::now();
        let dt = now.saturating_duration_since(last_frame).as_secs_f32();
        last_frame = now;

        if let Ok(https_result) = https_rx.try_recv() {
            eprintln!("[playfin_webos] gate1 https: {https_result}");
            app.diagnostics.https_status = https_result;
        }

        while let Some(event) = sdl.poll_event() {
            match event {
                SdlEvent::Quit => break 'running,
                SdlEvent::KeyDown { keycode, scancode } => {
                    if let Some(action) = map_key_input(keycode, scancode) {
                        if !app.handle_action(action) {
                            break 'running;
                        }
                    } else {
                        app.diagnostics.last_input =
                            format!("RawKey: sym={keycode} scancode={scancode}");
                    }
                }
                SdlEvent::MouseMotion { x, y } => app.record_pointer("Pointer", x, y),
                SdlEvent::MouseButtonDown { x, y } => app.record_pointer("Click", x, y),
            }
        }

        app.tick(dt);
        let (w, h) = window.drawable_size();
        clear_transparent(&gl, &gl_spec);
        app.render(&mut canvas, font, w, h);
        window.swap_window();

        fps_frames += 1;
        let elapsed = fps_window_start.elapsed();
        if elapsed >= Duration::from_millis(500) {
            app.diagnostics.fps = (fps_frames as f32) / elapsed.as_secs_f32();
            fps_frames = 0;
            fps_window_start = Instant::now();
        }

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
