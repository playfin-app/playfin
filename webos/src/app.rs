//! Gate 1 + Spike 0.4 interactive UI scene proving femtovg rendering, focus, and Starfish telemetry.

use crate::gl_config::{VIRTUAL_HEIGHT, VIRTUAL_WIDTH, virtual_transform};
use crate::input::NavAction;
use crate::spike_config::AuthTransportMode;
use crate::starfish::StarfishStatus;
use femtovg::renderer::OpenGl;
use femtovg::{Align, Baseline, Canvas, Color, FontId, Paint, Path};

pub const SPIKE_ACTIONS: [&str; 8] = [
    "1.Probe",
    "2.MKV",
    "3.HLS",
    "4.Auth",
    "5.Play/Pause",
    "6.Seek+30s",
    "7.Audio+1",
    "8.DTS/THD",
];

const BAR_X_MARGIN: f32 = 80.0;
const BAR_GAP: f32 = 16.0;
const BAR_Y: f32 = 164.0;
const BAR_H: f32 = 96.0;

/// UI commands emitted back to the main event loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppCommand {
    None,
    Quit,
    TriggerAction(usize),
}

/// On-screen Gate 1 & Spike 0.4 telemetry for verifying LG C1 execution without SSH.
#[derive(Debug, Clone)]
pub struct Gate1Diagnostics {
    pub device_id: String,
    pub data_dir: String,
    pub storage_note: String,
    pub survives_reinstall: bool,
    pub home_env: String,
    pub xdg_data_env: String,
    pub argv1_preview: String,
    pub https_status: String,
    pub config_source: String,
    pub auth_mode: AuthTransportMode,
    pub starfish: StarfishStatus,
    pub last_input: String,
    pub fps: f32,
}

impl Default for Gate1Diagnostics {
    fn default() -> Self {
        Self {
            device_id: "pending".to_string(),
            data_dir: "pending".to_string(),
            storage_note: String::new(),
            survives_reinstall: false,
            home_env: "unset".to_string(),
            xdg_data_env: "unset".to_string(),
            argv1_preview: "none".to_string(),
            https_status: "Checking TLS (https://jellyfin.org)...".to_string(),
            config_source: "none".to_string(),
            auth_mode: AuthTransportMode::HttpHeader,
            starfish: StarfishStatus::default(),
            last_input: "none".to_string(),
            fps: 0.0,
        }
    }
}

/// Interactive Phase 0 scene covering Gate 1 verification and the Task 0.4 Starfish test matrix.
#[derive(Debug, Clone)]
pub struct SimulatorApp {
    pub focused_index: usize,
    pub selected_index: Option<usize>,
    pub punch_through_demo: bool,
    pub focus_anim_pos: f32,
    pub core_version: String,
    pub diagnostics: Gate1Diagnostics,
}

impl Default for SimulatorApp {
    fn default() -> Self {
        Self::new(playfin_core::core_version(), Gate1Diagnostics::default())
    }
}

fn button_width() -> f32 {
    let count = SPIKE_ACTIONS.len() as f32;
    let total_w = VIRTUAL_WIDTH - 2.0 * BAR_X_MARGIN;
    (total_w - (count - 1.0) * BAR_GAP) / count
}

fn button_x(index: usize) -> f32 {
    BAR_X_MARGIN + (index as f32) * (button_width() + BAR_GAP)
}

impl SimulatorApp {
    pub fn new(core_version: String, diagnostics: Gate1Diagnostics) -> Self {
        Self {
            focused_index: 0,
            selected_index: None,
            punch_through_demo: false,
            focus_anim_pos: 0.0,
            core_version,
            diagnostics,
        }
    }

    /// Processes a navigation action and returns an `AppCommand` for the platform driver.
    pub fn handle_action(&mut self, action: NavAction) -> AppCommand {
        self.diagnostics.last_input = format!("Key: {action:?}");
        match action {
            NavAction::MoveLeft => {
                self.focused_index = self.focused_index.saturating_sub(1);
            }
            NavAction::MoveRight => {
                if self.focused_index + 1 < SPIKE_ACTIONS.len() {
                    self.focused_index += 1;
                }
            }
            NavAction::Select => {
                self.selected_index = Some(self.focused_index);
                return AppCommand::TriggerAction(self.focused_index);
            }
            NavAction::Back => {
                if self.punch_through_demo {
                    self.punch_through_demo = false;
                } else if self.selected_index.is_some() {
                    self.selected_index = None;
                } else {
                    return AppCommand::Quit;
                }
            }
            NavAction::TogglePunchThrough => {
                self.punch_through_demo = !self.punch_through_demo;
            }
            NavAction::Quit => return AppCommand::Quit,
            NavAction::MoveUp | NavAction::MoveDown => {}
        }
        AppCommand::None
    }

    /// Updates pointer coordinates and focuses any hovered Spike action button.
    pub fn record_pointer(&mut self, kind: &str, x: i32, y: i32, win_w: u32, win_h: u32) {
        self.diagnostics.last_input = format!("{kind}: ({x}, {y})");
        if let Some(idx) = self.hit_test_action(x, y, win_w, win_h) {
            self.focused_index = idx;
        }
    }

    /// Checks whether pointer coordinates land on an action button and returns `TriggerAction(idx)`.
    pub fn handle_click(&mut self, x: i32, y: i32, win_w: u32, win_h: u32) -> AppCommand {
        self.diagnostics.last_input = format!("Click: ({x}, {y})");
        if let Some(idx) = self.hit_test_action(x, y, win_w, win_h) {
            self.focused_index = idx;
            self.selected_index = Some(idx);
            return AppCommand::TriggerAction(idx);
        }
        AppCommand::None
    }

    fn hit_test_action(&self, x: i32, y: i32, win_w: u32, win_h: u32) -> Option<usize> {
        let vp = virtual_transform(win_w, win_h);
        if vp.scale <= 0.0 {
            return None;
        }
        let vx = (x as f32 - vp.offset_x) / vp.scale;
        let vy = (y as f32 - vp.offset_y) / vp.scale;
        if vy < BAR_Y || vy > BAR_Y + BAR_H {
            return None;
        }
        let btn_w = button_width();
        (0..SPIKE_ACTIONS.len()).find(|&idx| {
            let bx = button_x(idx);
            vx >= bx && vx <= bx + btn_w
        })
    }

    /// Advances smooth focus indicator interpolation toward `focused_index`.
    pub fn tick(&mut self, dt_secs: f32) {
        let target = self.focused_index as f32;
        let alpha = (dt_secs * 14.0).clamp(0.0, 1.0);
        self.focus_anim_pos += (target - self.focus_anim_pos) * alpha;
    }

    fn has_active_video(&self) -> bool {
        self.diagnostics.starfish.media_id.is_some()
    }

    /// Renders the 1920x1080 scene onto `canvas` inside a physical `(width, height)` surface.
    pub fn render(&self, canvas: &mut Canvas<OpenGl>, font: FontId, width: u32, height: u32) {
        canvas.set_size(width, height, 1.0);
        canvas.reset();

        let vp = virtual_transform(width, height);
        canvas.translate(vp.offset_x, vp.offset_y);
        canvas.scale(vp.scale, vp.scale);

        let transparent_center = self.punch_through_demo || self.has_active_video();
        if !transparent_center {
            let mut bg = Path::new();
            bg.rect(0.0, 0.0, VIRTUAL_WIDTH, VIRTUAL_HEIGHT);
            let bg_paint = Paint::linear_gradient(
                0.0,
                0.0,
                0.0,
                VIRTUAL_HEIGHT,
                Color::rgb(14, 17, 23),
                Color::rgb(22, 27, 38),
            );
            canvas.fill_path(&bg, &bg_paint);
        }

        // Top header bar
        let mut header_bg = Path::new();
        header_bg.rounded_rect(80.0, 44.0, VIRTUAL_WIDTH - 160.0, 88.0, 18.0);
        canvas.fill_path(&header_bg, &Paint::color(Color::rgba(16, 20, 28, 220)));

        let mut title_paint = Paint::color(Color::rgb(245, 247, 250));
        title_paint.set_font(&[font]);
        title_paint.set_font_size(30.0);
        title_paint.set_text_baseline(Baseline::Middle);
        let _ = canvas.fill_text(
            116.0,
            88.0,
            format!(
                "Playfin webOS  |  core v{}  |  {:.0} FPS  |  Auth: {}",
                self.core_version,
                self.diagnostics.fps,
                self.diagnostics.auth_mode.label()
            ),
            &title_paint,
        );

        let mut hint_paint = Paint::color(Color::rgb(164, 177, 198));
        hint_paint.set_font(&[font]);
        hint_paint.set_font_size(20.0);
        hint_paint.set_text_align(Align::Right);
        hint_paint.set_text_baseline(Baseline::Middle);
        let mode_label = if transparent_center {
            "Transparent punch-through ON (T toggle, Back stops/returns)"
        } else {
            "D-pad/Pointer: Select | T: Alpha hole | Back/Q: Exit"
        };
        let _ = canvas.fill_text(VIRTUAL_WIDTH - 116.0, 88.0, mode_label, &hint_paint);

        self.render_action_bar(canvas, font);

        if transparent_center {
            self.render_video_hud_footer(canvas, font);
            canvas.flush();
            return;
        }

        self.render_diagnostics_panel(canvas, font);
        canvas.flush();
    }

    fn render_action_bar(&self, canvas: &mut Canvas<OpenGl>, font: FontId) {
        let btn_w = button_width();
        for (idx, label) in SPIKE_ACTIONS.iter().enumerate() {
            let x = button_x(idx);
            let is_focused = idx == self.focused_index;
            let is_selected = self.selected_index == Some(idx);

            let mut btn = Path::new();
            btn.rounded_rect(x, BAR_Y, btn_w, BAR_H, 16.0);
            let fill = if is_selected {
                Color::rgba(44, 96, 176, 235)
            } else {
                Color::rgba(28, 34, 48, 225)
            };
            canvas.fill_path(&btn, &Paint::color(fill));

            let mut text = Paint::color(if is_focused {
                Color::rgb(255, 255, 255)
            } else {
                Color::rgb(190, 200, 216)
            });
            text.set_font(&[font]);
            text.set_font_size(22.0);
            text.set_text_align(Align::Center);
            text.set_text_baseline(Baseline::Middle);
            let _ = canvas.fill_text(x + btn_w * 0.5, BAR_Y + BAR_H * 0.5, label, &text);
        }

        let ring_x = BAR_X_MARGIN + self.focus_anim_pos * (btn_w + BAR_GAP);
        let mut ring = Path::new();
        ring.rounded_rect(ring_x - 4.0, BAR_Y - 4.0, btn_w + 8.0, BAR_H + 8.0, 20.0);
        let mut stroke = Paint::color(Color::rgb(98, 174, 255));
        stroke.set_line_width(5.0);
        canvas.stroke_path(&ring, &stroke);
    }

    fn render_video_hud_footer(&self, canvas: &mut Canvas<OpenGl>, font: FontId) {
        let mut badge = Path::new();
        badge.rounded_rect(
            80.0,
            VIRTUAL_HEIGHT - 146.0,
            VIRTUAL_WIDTH - 160.0,
            96.0,
            16.0,
        );
        canvas.fill_path(&badge, &Paint::color(Color::rgba(16, 20, 28, 205)));
        let mut osd = Paint::color(Color::rgb(240, 245, 252));
        osd.set_font(&[font]);
        osd.set_font_size(24.0);
        osd.set_text_baseline(Baseline::Middle);
        let s = &self.diagnostics.starfish;
        let line1 = format!(
            "Starfish: {}  |  pos={}ms / {}ms  |  video={}  |  audio={}",
            s.playback_state, s.position_ms, s.duration_ms, s.video_info, s.audio_info
        );
        let line2 = format!(
            "Window: {}  |  MediaID: {}  |  Event: {}",
            s.window_id.as_deref().unwrap_or("none"),
            s.media_id.as_deref().unwrap_or("none"),
            s.last_event
        );
        let _ = canvas.fill_text(112.0, VIRTUAL_HEIGHT - 114.0, line1, &osd);
        let _ = canvas.fill_text(112.0, VIRTUAL_HEIGHT - 78.0, line2, &osd);
    }

    fn render_diagnostics_panel(&self, canvas: &mut Canvas<OpenGl>, font: FontId) {
        let panel_y = 290.0;
        let panel_h = 720.0;
        let mut panel = Path::new();
        panel.rounded_rect(80.0, panel_y, VIRTUAL_WIDTH - 160.0, panel_h, 20.0);
        canvas.fill_path(&panel, &Paint::color(Color::rgba(16, 20, 28, 225)));

        let mut heading = Paint::color(Color::rgb(130, 196, 255));
        heading.set_font(&[font]);
        heading.set_font_size(26.0);
        heading.set_text_baseline(Baseline::Middle);
        let _ = canvas.fill_text(
            116.0,
            panel_y + 42.0,
            "Gate 1 & Spike 0.4 Diagnostics (Non-Root LG Dev Mode)",
            &heading,
        );

        let persistence_line = if self.diagnostics.survives_reinstall {
            format!(
                "Data Dir ({}, persistent=true): {}",
                self.diagnostics.storage_note, self.diagnostics.data_dir
            )
        } else {
            format!(
                "WARNING NOT PERSISTENT ({}, fails Gate 1 reinstall): {}",
                self.diagnostics.storage_note, self.diagnostics.data_dir
            )
        };

        let s = &self.diagnostics.starfish;
        let lines = [
            (
                format!("Device ID (reinstall test): {}", self.diagnostics.device_id),
                Color::rgb(224, 232, 244),
            ),
            (
                persistence_line,
                if self.diagnostics.survives_reinstall {
                    Color::rgb(138, 232, 168)
                } else {
                    Color::rgb(255, 196, 92)
                },
            ),
            (
                format!(
                    "Env HOME={}  |  XDG_DATA_HOME={}",
                    self.diagnostics.home_env, self.diagnostics.xdg_data_env
                ),
                Color::rgb(224, 232, 244),
            ),
            (
                format!(
                    "HTTPS / TLS (bundled-roots + ring): {}",
                    self.diagnostics.https_status
                ),
                Color::rgb(224, 232, 244),
            ),
            (
                format!("argv[1]: {}", self.diagnostics.argv1_preview),
                Color::rgb(224, 232, 244),
            ),
            (
                format!("Spike Config: {}", self.diagnostics.config_source),
                Color::rgb(200, 214, 236),
            ),
            (
                format!("Runtime Probe: {}", s.runtime_probe),
                Color::rgb(156, 224, 255),
            ),
            (
                format!(
                    "Playback: {}  |  video={}  |  audio={} (track {}/{})",
                    s.playback_state,
                    s.video_info,
                    s.audio_info,
                    s.current_audio_track,
                    s.audio_track_count
                ),
                Color::rgb(224, 232, 244),
            ),
            (
                format!("Media Event: {}", s.last_event),
                Color::rgb(224, 232, 244),
            ),
            (
                format!("Last Input: {}", self.diagnostics.last_input),
                Color::rgb(224, 232, 244),
            ),
        ];

        for (idx, (line, color)) in lines.iter().enumerate() {
            let mut body = Paint::color(*color);
            body.set_font(&[font]);
            body.set_font_size(22.0);
            body.set_text_baseline(Baseline::Middle);
            let y = panel_y + 102.0 + (idx as f32) * 58.0;
            let _ = canvas.fill_text(116.0, y, line, &body);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focus_moves_clamped_and_back_exits_cleanly() {
        let mut app = SimulatorApp::new("0.11.3".to_string(), Gate1Diagnostics::default());
        assert_eq!(app.handle_action(NavAction::MoveLeft), AppCommand::None);
        assert_eq!(app.focused_index, 0);

        for _ in 0..12 {
            app.handle_action(NavAction::MoveRight);
        }
        assert_eq!(app.focused_index, SPIKE_ACTIONS.len() - 1);

        assert_eq!(
            app.handle_action(NavAction::Select),
            AppCommand::TriggerAction(SPIKE_ACTIONS.len() - 1)
        );
        assert_eq!(app.selected_index, Some(SPIKE_ACTIONS.len() - 1));

        // First Back clears selection; second Back requests exit.
        assert_eq!(app.handle_action(NavAction::Back), AppCommand::None);
        assert_eq!(app.selected_index, None);
        assert_eq!(app.handle_action(NavAction::Back), AppCommand::Quit);
    }

    #[test]
    fn punch_through_toggles_and_back_restores_scene() {
        let mut app = SimulatorApp::new("0.11.3".to_string(), Gate1Diagnostics::default());
        assert_eq!(
            app.handle_action(NavAction::TogglePunchThrough),
            AppCommand::None
        );
        assert!(app.punch_through_demo);
        assert_eq!(app.handle_action(NavAction::Back), AppCommand::None);
        assert!(!app.punch_through_demo);
    }

    #[test]
    fn pointer_click_hits_corresponding_spike_action() {
        let mut app = SimulatorApp::new("0.11.3".to_string(), Gate1Diagnostics::default());
        let cx = (button_x(2) + button_width() * 0.5) as i32;
        let cy = (BAR_Y + BAR_H * 0.5) as i32;
        assert_eq!(
            app.handle_click(cx, cy, 1920, 1080),
            AppCommand::TriggerAction(2)
        );
        assert_eq!(app.focused_index, 2);
    }
}
