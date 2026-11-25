//! Simulator and Gate 1 TV diagnostics scene proving femtovg rendering, focus, and core linkage.

use crate::gl_config::{VIRTUAL_HEIGHT, VIRTUAL_WIDTH, virtual_transform};
use crate::input::NavAction;
use femtovg::renderer::OpenGl;
use femtovg::{Align, Baseline, Canvas, Color, FontId, Paint, Path};

const CARD_TITLES: [&str; 3] = ["Continue Watching", "Libraries", "Quick Connect"];

/// On-screen Gate 1 telemetry for verifying non-root LG C1 execution without SSH.
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
            last_input: "none".to_string(),
            fps: 0.0,
        }
    }
}

/// Interactive Phase 0 skeleton state for the desktop simulator and Gate 1 TV smoke test.
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

    /// Processes a navigation action; returns `false` when the app should exit.
    pub fn handle_action(&mut self, action: NavAction) -> bool {
        self.diagnostics.last_input = format!("Key: {action:?}");
        match action {
            NavAction::MoveLeft => {
                self.focused_index = self.focused_index.saturating_sub(1);
            }
            NavAction::MoveRight => {
                if self.focused_index + 1 < CARD_TITLES.len() {
                    self.focused_index += 1;
                }
            }
            NavAction::Select => {
                self.selected_index = Some(self.focused_index);
            }
            NavAction::Back => {
                if self.punch_through_demo {
                    self.punch_through_demo = false;
                } else if self.selected_index.is_some() {
                    self.selected_index = None;
                } else {
                    return false;
                }
            }
            NavAction::TogglePunchThrough => {
                self.punch_through_demo = !self.punch_through_demo;
            }
            NavAction::Quit => return false,
            NavAction::MoveUp | NavAction::MoveDown => {}
        }
        true
    }

    /// Records Magic Remote / mouse pointer coordinates in the diagnostic overlay.
    pub fn record_pointer(&mut self, kind: &str, x: i32, y: i32) {
        self.diagnostics.last_input = format!("{kind}: ({x}, {y})");
    }

    /// Advances smooth focus indicator interpolation toward `focused_index`.
    pub fn tick(&mut self, dt_secs: f32) {
        let target = self.focused_index as f32;
        let alpha = (dt_secs * 14.0).clamp(0.0, 1.0);
        self.focus_anim_pos += (target - self.focus_anim_pos) * alpha;
    }

    /// Renders the 1920x1080 scene onto `canvas` inside a physical `(width, height)` surface.
    pub fn render(&self, canvas: &mut Canvas<OpenGl>, font: FontId, width: u32, height: u32) {
        canvas.set_size(width, height, 1.0);
        canvas.reset();

        let vp = virtual_transform(width, height);
        canvas.translate(vp.offset_x, vp.offset_y);
        canvas.scale(vp.scale, vp.scale);

        if !self.punch_through_demo {
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
        header_bg.rounded_rect(80.0, 48.0, VIRTUAL_WIDTH - 160.0, 88.0, 18.0);
        canvas.fill_path(&header_bg, &Paint::color(Color::rgba(16, 20, 28, 225)));

        let mut title_paint = Paint::color(Color::rgb(245, 247, 250));
        title_paint.set_font(&[font]);
        title_paint.set_font_size(32.0);
        title_paint.set_text_baseline(Baseline::Middle);
        let _ = canvas.fill_text(
            116.0,
            92.0,
            format!(
                "Playfin webOS  |  core v{}  |  {:.0} FPS",
                self.core_version, self.diagnostics.fps
            ),
            &title_paint,
        );

        let mut hint_paint = Paint::color(Color::rgb(164, 177, 198));
        hint_paint.set_font(&[font]);
        hint_paint.set_font_size(22.0);
        hint_paint.set_text_align(Align::Right);
        hint_paint.set_text_baseline(Baseline::Middle);
        let mode_label = if self.punch_through_demo {
            "Alpha punch-through ON (T to toggle, Back to return)"
        } else {
            "Arrows: Focus  |  Enter: Select  |  T: Alpha hole  |  Back/Q: Exit"
        };
        let _ = canvas.fill_text(VIRTUAL_WIDTH - 116.0, 92.0, mode_label, &hint_paint);

        if self.punch_through_demo {
            let mut badge = Path::new();
            badge.rounded_rect(
                80.0,
                VIRTUAL_HEIGHT - 130.0,
                VIRTUAL_WIDTH - 160.0,
                76.0,
                16.0,
            );
            canvas.fill_path(&badge, &Paint::color(Color::rgba(16, 20, 28, 225)));
            let mut osd = Paint::color(Color::rgb(235, 240, 248));
            osd.set_font(&[font]);
            osd.set_font_size(26.0);
            osd.set_text_baseline(Baseline::Middle);
            let _ = canvas.fill_text(
                120.0,
                VIRTUAL_HEIGHT - 92.0,
                "Transparent center cleared to rgba(0,0,0,0) for Starfish video plane",
                &osd,
            );
            canvas.flush();
            return;
        }

        // Three focusable poster cards
        let card_w = 500.0;
        let card_h = 300.0;
        let gap = 70.0;
        let start_x = (VIRTUAL_WIDTH - (3.0 * card_w + 2.0 * gap)) * 0.5;
        let card_y = 210.0;

        for (idx, label) in CARD_TITLES.iter().enumerate() {
            let x = start_x + (idx as f32) * (card_w + gap);
            let is_focused = idx == self.focused_index;
            let is_selected = self.selected_index == Some(idx);

            let mut card = Path::new();
            card.rounded_rect(x, card_y, card_w, card_h, 22.0);
            let fill = if is_selected {
                Paint::linear_gradient(
                    x,
                    card_y,
                    x + card_w,
                    card_y + card_h,
                    Color::rgb(46, 98, 178),
                    Color::rgb(31, 61, 118),
                )
            } else {
                Paint::linear_gradient(
                    x,
                    card_y,
                    x + card_w,
                    card_y + card_h,
                    Color::rgb(35, 42, 56),
                    Color::rgb(24, 29, 40),
                )
            };
            canvas.fill_path(&card, &fill);

            let mut card_text = Paint::color(if is_focused {
                Color::rgb(255, 255, 255)
            } else {
                Color::rgb(190, 200, 216)
            });
            card_text.set_font(&[font]);
            card_text.set_font_size(32.0);
            card_text.set_text_align(Align::Center);
            card_text.set_text_baseline(Baseline::Middle);
            let _ = canvas.fill_text(x + card_w * 0.5, card_y + card_h * 0.5, label, &card_text);
        }

        // Animated focus ring
        let ring_x = start_x + self.focus_anim_pos * (card_w + gap);
        let mut ring = Path::new();
        ring.rounded_rect(
            ring_x - 6.0,
            card_y - 6.0,
            card_w + 12.0,
            card_h + 12.0,
            26.0,
        );
        let mut stroke = Paint::color(Color::rgb(98, 174, 255));
        stroke.set_line_width(6.0);
        canvas.stroke_path(&ring, &stroke);

        // Gate 1 on-screen diagnostics card (visible on LG C1 without SSH)
        self.render_diagnostics_panel(canvas, font);

        canvas.flush();
    }

    fn render_diagnostics_panel(&self, canvas: &mut Canvas<OpenGl>, font: FontId) {
        let panel_y = 580.0;
        let panel_h = 430.0;
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
            "Gate 1 Diagnostics (Non-Root Dev Mode)",
            &heading,
        );

        let lines = [
            format!("Device ID (reinstall test): {}", self.diagnostics.device_id),
            format!(
                "Data Dir ({}, persistent={}): {}",
                self.diagnostics.storage_note,
                self.diagnostics.survives_reinstall,
                self.diagnostics.data_dir
            ),
            format!(
                "Env HOME={}  |  XDG_DATA_HOME={}",
                self.diagnostics.home_env, self.diagnostics.xdg_data_env
            ),
            format!(
                "HTTPS / TLS (bundled-roots + ring): {}",
                self.diagnostics.https_status
            ),
            format!("argv[1]: {}", self.diagnostics.argv1_preview),
            format!("Last Input: {}", self.diagnostics.last_input),
        ];

        let mut body = Paint::color(Color::rgb(224, 232, 244));
        body.set_font(&[font]);
        body.set_font_size(23.0);
        body.set_text_baseline(Baseline::Middle);
        for (idx, line) in lines.iter().enumerate() {
            let y = panel_y + 102.0 + (idx as f32) * 52.0;
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
        assert!(app.handle_action(NavAction::MoveLeft));
        assert_eq!(app.focused_index, 0);

        assert!(app.handle_action(NavAction::MoveRight));
        assert!(app.handle_action(NavAction::MoveRight));
        assert!(app.handle_action(NavAction::MoveRight));
        assert_eq!(app.focused_index, 2);

        assert!(app.handle_action(NavAction::Select));
        assert_eq!(app.selected_index, Some(2));

        // First Back clears selection; second Back requests exit.
        assert!(app.handle_action(NavAction::Back));
        assert_eq!(app.selected_index, None);
        assert!(!app.handle_action(NavAction::Back));
    }

    #[test]
    fn punch_through_toggles_and_back_restores_scene() {
        let mut app = SimulatorApp::new("0.11.3".to_string(), Gate1Diagnostics::default());
        assert!(app.handle_action(NavAction::TogglePunchThrough));
        assert!(app.punch_through_demo);
        assert!(app.handle_action(NavAction::Back));
        assert!(!app.punch_through_demo);
    }
}
