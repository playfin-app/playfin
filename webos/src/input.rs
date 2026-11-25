//! Keyboard and TV remote input mapping for 10-foot navigation.

use sdl2::keyboard::Keycode;

/// Logical navigation and control actions shared between macOS simulator and webOS remote.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavAction {
    MoveLeft,
    MoveRight,
    MoveUp,
    MoveDown,
    Select,
    Back,
    TogglePunchThrough,
    Quit,
}

/// Maps an SDL2 keycode to a 10-foot navigation action.
pub fn map_keycode(keycode: Keycode) -> Option<NavAction> {
    match keycode {
        Keycode::Left | Keycode::A => Some(NavAction::MoveLeft),
        Keycode::Right | Keycode::D => Some(NavAction::MoveRight),
        Keycode::Up | Keycode::W => Some(NavAction::MoveUp),
        Keycode::Down | Keycode::S => Some(NavAction::MoveDown),
        Keycode::Return | Keycode::KpEnter | Keycode::Space => Some(NavAction::Select),
        Keycode::Escape | Keycode::Backspace | Keycode::AcBack => Some(NavAction::Back),
        Keycode::T => Some(NavAction::TogglePunchThrough),
        Keycode::Q => Some(NavAction::Quit),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_dpad_select_back_and_quit_keys() {
        assert_eq!(map_keycode(Keycode::Left), Some(NavAction::MoveLeft));
        assert_eq!(map_keycode(Keycode::Right), Some(NavAction::MoveRight));
        assert_eq!(map_keycode(Keycode::Up), Some(NavAction::MoveUp));
        assert_eq!(map_keycode(Keycode::Down), Some(NavAction::MoveDown));
        assert_eq!(map_keycode(Keycode::Return), Some(NavAction::Select));
        assert_eq!(map_keycode(Keycode::AcBack), Some(NavAction::Back));
        assert_eq!(map_keycode(Keycode::Escape), Some(NavAction::Back));
        assert_eq!(map_keycode(Keycode::T), Some(NavAction::TogglePunchThrough));
        assert_eq!(map_keycode(Keycode::Q), Some(NavAction::Quit));
    }

    #[test]
    fn ignores_unmapped_keys() {
        assert_eq!(map_keycode(Keycode::F12), None);
    }
}
