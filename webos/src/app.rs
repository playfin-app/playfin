//! Minimal simulator scene proving femtovg rendering, focus animation, and core linkage.

use crate::gl_config::{VIRTUAL_HEIGHT, VIRTUAL_WIDTH, virtual_transform};
use crate::input::NavAction;
use femtovg::renderer::OpenGl;
use femtovg::{Align, Baseline, Canvas, Color, FontId, Paint, Path};

const CARD_TITLES: [&str; 3] = ["Continue Watching", "Libraries", "Quick Connect"];

/// Interactive Phase 0 skeleton state for the desktop simulator and Gate 1 TV smoke test.
#[derive(Debug, Clone)]
pub struct SimulatorApp {
    pub focused_index: usize,
    pub selected_index: Option<usize>,
    pub punch_through_demo: bool,
    pub focus_anim_pos: f32,
    pub core_version: String,
}

impl Default for SimulatorApp {
    fn default() -> Self {
        Self::new(playfin_core::core_version())
    }
}

impl SimulatorApp {
    pub fn new(core_version: String) -> Self {
        Self {
            focused_index: 0,
            selected_index: None,
            punch_through_demo: false,
            focus_anim_pos: 0.0,
            core_version,
        }
    }

    /// Processes a navigation action; returns `false` when the app should exit.
    pub fn handle_action(&mut self, action: NavAction) -> bool {
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
        header_bg.rounded_rect(80.0, 56.0, VIRTUAL_WIDTH - 160.0, 96.0, 18.0);
        canvas.fill_path(&header_bg, &Paint::color(Color::rgba(16, 20, 28, 225)));

        let mut title_paint = Paint::color(Color::rgb(245, 247, 250));
        title_paint.set_font(&[font]);
        title_paint.set_font_size(34.0);
        title_paint.set_text_baseline(Baseline::Middle);
        let _ = canvas.fill_text(
            116.0,
            104.0,
            format!("Playfin webOS  |  core v{}", self.core_version),
            &title_paint,
        );

        let mut hint_paint = Paint::color(Color::rgb(164, 177, 198));
        hint_paint.set_font(&[font]);
        hint_paint.set_font_size(22.0);
        hint_paint.set_text_align(Align::Right);
        hint_paint.set_text_baseline(Baseline::Middle);
        let mode_label = if self.punch_through_demo {
            "Alpha punch-through ON (T to toggle, Esc back)"
        } else {
            "Arrows: Focus  |  Enter: Select  |  T: Alpha hole  |  Q: Quit"
        };
        let _ = canvas.fill_text(VIRTUAL_WIDTH - 116.0, 104.0, mode_label, &hint_paint);

        if self.punch_through_demo {
            let mut badge = Path::new();
            badge.rounded_rect(
                80.0,
                VIRTUAL_HEIGHT - 140.0,
                VIRTUAL_WIDTH - 160.0,
                80.0,
                16.0,
            );
            canvas.fill_path(&badge, &Paint::color(Color::rgba(16, 20, 28, 225)));
            let mut osd = Paint::color(Color::rgb(235, 240, 248));
            osd.set_font(&[font]);
            osd.set_font_size(26.0);
            osd.set_text_baseline(Baseline::Middle);
            let _ = canvas.fill_text(
                120.0,
                VIRTUAL_HEIGHT - 100.0,
                "Transparent center cleared to rgba(0,0,0,0) for Starfish video plane",
                &osd,
            );
            canvas.flush();
            return;
        }

        // Three focusable poster cards
        let card_w = 500.0;
        let card_h = 340.0;
        let gap = 70.0;
        let start_x = (VIRTUAL_WIDTH - (3.0 * card_w + 2.0 * gap)) * 0.5;
        let card_y = 320.0;

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

        canvas.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focus_moves_clamped_and_back_exits_cleanly() {
        let mut app = SimulatorApp::new("0.11.3".to_string());
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
        let mut app = SimulatorApp::new("0.11.3".to_string());
        assert!(app.handle_action(NavAction::TogglePunchThrough));
        assert!(app.punch_through_demo);
        assert!(app.handle_action(NavAction::Back));
        assert!(!app.punch_through_demo);
    }
}
