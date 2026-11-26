#![deny(clippy::unwrap_used, clippy::expect_used)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

use femtovg::Canvas;
use femtovg::renderer::OpenGl;
use playfin_core::{ClientIdentity, JellyfinClient, probe_https_status};
use playfin_webos::app::{AppCommand, Gate1Diagnostics, SimulatorApp};
use playfin_webos::gl_config::{GlSurfaceSpec, clear_transparent};
use playfin_webos::input::{NavAction, map_key_input};
use playfin_webos::platform::{LaunchContext, resolve_persistent_data_dir};
use playfin_webos::sdl::{SdlContext, SdlEvent, set_hint};
use playfin_webos::spike_config::{SpikeConfig, load_spike_config};
use playfin_webos::starfish::{StarfishController, StreamKind};
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

/// On the TV nobody sees stderr, so every `eprintln!` goes to `<data_dir>/playfin.log`.
/// The dev tooling reads that file over SSH (`scripts/webos-dev.sh logs`).
/// The previous launch is kept as `playfin.prev.log`.
fn redirect_stderr_to_log(data_dir: &std::path::Path) {
    use std::os::fd::AsRawFd;

    let log_path = data_dir.join("playfin.log");
    let _ = std::fs::rename(&log_path, data_dir.join("playfin.prev.log"));
    let Ok(file) = std::fs::File::create(&log_path) else {
        return;
    };
    // SAFETY: dup2 only swaps file descriptor 2 for our open log file; `file` stays valid during the call.
    unsafe {
        libc::dup2(file.as_raw_fd(), libc::STDERR_FILENO);
    }
}

fn init_context_and_config() -> (Gate1Diagnostics, SpikeConfig, String) {
    let raw_args: Vec<String> = std::env::args().collect();
    let ctx = LaunchContext::from_env(raw_args.clone());
    let storage = resolve_persistent_data_dir(&ctx);
    if cfg!(feature = "webos") {
        redirect_stderr_to_log(&storage.data_dir);
    }
    let (spike_cfg, cfg_source) =
        load_spike_config(&storage.data_dir, raw_args.get(1).map(String::as_str));

    let app_id = spike_cfg
        .app_id
        .clone()
        .or_else(|| std::env::var("APPID").ok().filter(|v| !v.trim().is_empty()))
        .unwrap_or_else(|| "com.playfin.webos".to_string());

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
        config_source: cfg_source,
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
    (diag, spike_cfg, app_id)
}

fn handle_spike_trigger(
    idx: usize,
    app: &mut SimulatorApp,
    cfg: &SpikeConfig,
    starfish: &mut StarfishController,
    dts_toggle: &mut bool,
) {
    eprintln!("[playfin_webos] trigger action #{}", idx + 1);
    let key = cfg.api_key.as_deref();
    let mode = app.diagnostics.auth_mode;
    match idx {
        0 => starfish.refresh_probe(),
        1 => {
            if let Some(url) = cfg.mkv_url.as_deref() {
                starfish.load_stream(url, StreamKind::MkvDirect, key, mode);
            } else {
                starfish.status.last_event =
                    format!("No mkv_url in {}", app.diagnostics.config_source);
            }
        }
        2 => {
            if let Some(url) = cfg.hls_url.as_deref() {
                starfish.load_stream(url, StreamKind::HlsRemux, key, mode);
            } else {
                starfish.status.last_event =
                    format!("No hls_url in {}", app.diagnostics.config_source);
            }
        }
        3 => {
            app.diagnostics.auth_mode = mode.toggle();
            starfish.status.last_event = format!("Auth -> {}", app.diagnostics.auth_mode.label());
        }
        4 => starfish.toggle_play_pause(),
        5 => starfish.seek_by_ms(30_000),
        6 => starfish.cycle_audio_track(),
        7 => {
            let pick_truehd = *dts_toggle && cfg.truehd_url.is_some();
            *dts_toggle = !*dts_toggle;
            let chosen = if pick_truehd {
                cfg.truehd_url.as_deref()
            } else {
                cfg.dts_url.as_deref().or(cfg.truehd_url.as_deref())
            };
            if let Some(url) = chosen {
                starfish.load_stream(url, StreamKind::AudioCodecTest, key, mode);
            } else {
                starfish.status.last_event =
                    format!("No dts_url/truehd_url in {}", app.diagnostics.config_source);
            }
        }
        _ => {}
    }
}

fn run() -> Result<(), WebosError> {
    let (diagnostics, spike_cfg, app_id) = init_context_and_config();
    let (_rt, https_rx) = spawn_https_probe()?;

    if cfg!(feature = "webos") {
        set_hint("SDL_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
    }

    // Declare `sdl` strictly before `starfish` so `StarfishController` (owning `ExportedVideoWindow`)
    // drops before `SdlContext::drop` calls `SDL_Quit()`.
    let sdl = SdlContext::init_video().map_err(WebosError::Sdl)?;
    let mut starfish = StarfishController::new(app_id);
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
    app.diagnostics.starfish = starfish.status.clone();
    let mut last_frame = Instant::now();
    let mut fps_window_start = Instant::now();
    let mut fps_frames: u32 = 0;
    let mut dts_toggle = false;
    let mut last_logged_event = String::new();

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

        starfish.poll_events();

        while let Some(event) = sdl.poll_event() {
            match event {
                SdlEvent::Quit => break 'running,
                SdlEvent::KeyDown { keycode, scancode } => {
                    if let Some(action) = map_key_input(keycode, scancode) {
                        if action == NavAction::Back
                            && (starfish.status.media_id.is_some()
                                || starfish.status.playback_state.starts_with("Loading"))
                        {
                            starfish.unload();
                            continue;
                        }
                        match app.handle_action(action) {
                            AppCommand::Quit => break 'running,
                            AppCommand::TriggerAction(idx) => {
                                handle_spike_trigger(
                                    idx,
                                    &mut app,
                                    &spike_cfg,
                                    &mut starfish,
                                    &mut dts_toggle,
                                );
                            }
                            AppCommand::None => {}
                        }
                    } else {
                        app.diagnostics.last_input =
                            format!("RawKey: sym={keycode} scancode={scancode}");
                    }
                }
                SdlEvent::MouseMotion { x, y } => {
                    let (ww, wh) = window.window_size();
                    app.record_pointer("Pointer", x, y, ww, wh);
                }
                SdlEvent::MouseButtonDown { x, y } => {
                    let (ww, wh) = window.window_size();
                    if let AppCommand::TriggerAction(idx) = app.handle_click(x, y, ww, wh) {
                        handle_spike_trigger(
                            idx,
                            &mut app,
                            &spike_cfg,
                            &mut starfish,
                            &mut dts_toggle,
                        );
                    }
                }
            }
        }

        if starfish.status.last_event != last_logged_event {
            last_logged_event = starfish.status.last_event.clone();
            eprintln!(
                "[playfin_webos] starfish: {} | state={} pos={}/{} ms video={} audio={} track={}/{}",
                last_logged_event,
                starfish.status.playback_state,
                starfish.status.position_ms,
                starfish.status.duration_ms,
                starfish.status.video_info,
                starfish.status.audio_info,
                starfish.status.current_audio_track,
                starfish.status.audio_track_count,
            );
        }
        app.diagnostics.starfish = starfish.status.clone();
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

    starfish.unload();
    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("playfin_webos fatal error: {err}");
        std::process::exit(1);
    }
}
