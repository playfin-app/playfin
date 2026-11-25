//! Keyboard and TV remote input mapping for 10-foot navigation.

use sdl2_sys::SDL_KeyCode;

/// Custom LG webOS Back button scancode defined in `SDL_webOS.h`.
pub const WEBOS_SCANCODE_BACK: u32 = 482;
/// Custom LG webOS Exit button scancode defined in `SDL_webOS.h`.
pub const WEBOS_SCANCODE_EXIT: u32 = 505;

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

/// Maps an SDL2 `keysym.sym` and raw `keysym.scancode` to a 10-foot navigation action.
pub fn map_key_input(keycode: i32, scancode: u32) -> Option<NavAction> {
    if scancode == WEBOS_SCANCODE_BACK {
        return Some(NavAction::Back);
    }
    if scancode == WEBOS_SCANCODE_EXIT {
        return Some(NavAction::Quit);
    }
    map_keycode(keycode)
}

/// Maps a standard SDL2 virtual keycode (`SDLK_*`) to a 10-foot navigation action.
pub fn map_keycode(keycode: i32) -> Option<NavAction> {
    const fn k(code: SDL_KeyCode) -> i32 {
        code as i32
    }

    match keycode {
        v if v == k(SDL_KeyCode::SDLK_LEFT) || v == k(SDL_KeyCode::SDLK_a) => {
            Some(NavAction::MoveLeft)
        }
        v if v == k(SDL_KeyCode::SDLK_RIGHT) || v == k(SDL_KeyCode::SDLK_d) => {
            Some(NavAction::MoveRight)
        }
        v if v == k(SDL_KeyCode::SDLK_UP) || v == k(SDL_KeyCode::SDLK_w) => Some(NavAction::MoveUp),
        v if v == k(SDL_KeyCode::SDLK_DOWN) || v == k(SDL_KeyCode::SDLK_s) => {
            Some(NavAction::MoveDown)
        }
        v if v == k(SDL_KeyCode::SDLK_RETURN)
            || v == k(SDL_KeyCode::SDLK_KP_ENTER)
            || v == k(SDL_KeyCode::SDLK_SPACE)
            || v == k(SDL_KeyCode::SDLK_SELECT) =>
        {
            Some(NavAction::Select)
        }
        v if v == k(SDL_KeyCode::SDLK_ESCAPE)
            || v == k(SDL_KeyCode::SDLK_BACKSPACE)
            || v == k(SDL_KeyCode::SDLK_AC_BACK)
            || v == k(SDL_KeyCode::SDLK_CANCEL) =>
        {
            Some(NavAction::Back)
        }
        v if v == k(SDL_KeyCode::SDLK_t) => Some(NavAction::TogglePunchThrough),
        v if v == k(SDL_KeyCode::SDLK_q) => Some(NavAction::Quit),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_dpad_select_back_and_quit_keys() {
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_LEFT as i32),
            Some(NavAction::MoveLeft)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_RIGHT as i32),
            Some(NavAction::MoveRight)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_UP as i32),
            Some(NavAction::MoveUp)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_DOWN as i32),
            Some(NavAction::MoveDown)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_RETURN as i32),
            Some(NavAction::Select)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_AC_BACK as i32),
            Some(NavAction::Back)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_ESCAPE as i32),
            Some(NavAction::Back)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_t as i32),
            Some(NavAction::TogglePunchThrough)
        );
        assert_eq!(
            map_keycode(SDL_KeyCode::SDLK_q as i32),
            Some(NavAction::Quit)
        );
    }

    #[test]
    fn maps_webos_remote_scancodes_and_ignores_unknown() {
        assert_eq!(map_key_input(0, WEBOS_SCANCODE_BACK), Some(NavAction::Back));
        assert_eq!(map_key_input(0, WEBOS_SCANCODE_EXIT), Some(NavAction::Quit));
        assert_eq!(map_key_input(SDL_KeyCode::SDLK_F12 as i32, 0), None);
    }
}
