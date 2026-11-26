//! Pure-Rust runtime bindings for LG webOS 5+ SDL exported video windows.

use std::ffi::{CStr, CString, c_char, c_int, c_void};

/// C ABI layout matching SDL2's `SDL_Rect`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SdlRect {
    pub x: c_int,
    pub y: c_int,
    pub w: c_int,
    pub h: c_int,
}

type CreateExportedWindowFn = unsafe extern "C" fn(c_int) -> *const c_char;
type SetExportedWindowFn = unsafe extern "C" fn(*const c_char, *mut SdlRect, *mut SdlRect) -> c_int;
type DestroyExportedWindowFn = unsafe extern "C" fn(*const c_char);
type GetPanelResolutionFn = unsafe extern "C" fn(*mut c_int, *mut c_int) -> c_int;

const EXPORTED_WINDOW_TYPE_VIDEO: c_int = 0;
const FALLBACK_PANEL_W: i32 = 1920;
const FALLBACK_PANEL_H: i32 = 1080;

/// Result of probing `libSDL2` webOS extensions at runtime via `RTLD_DEFAULT`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExportedWindowProbe {
    pub supported: bool,
    pub panel_resolution: Option<(i32, i32)>,
    pub detail: String,
}

unsafe fn lookup_symbol(name: &CStr) -> *mut c_void {
    #[cfg(unix)]
    {
        // SAFETY: `RTLD_DEFAULT` is valid on Linux/macOS and `name` is a static NUL-terminated C string.
        unsafe { libc::dlsym(libc::RTLD_DEFAULT, name.as_ptr()) }
    }
    #[cfg(not(unix))]
    {
        let _ = name;
        std::ptr::null_mut()
    }
}

/// Resolves whether the active `libSDL2` exposes the LG webOS exported-window extensions.
pub fn probe_support() -> ExportedWindowProbe {
    // SAFETY: Symbols have known C prototypes if exported by SDL2-webOS.
    unsafe {
        let create = lookup_symbol(c"SDL_webOSCreateExportedWindow");
        let set = lookup_symbol(c"SDL_webOSSetExportedWindow");
        let destroy = lookup_symbol(c"SDL_webOSDestroyExportedWindow");
        let panel_fn = lookup_symbol(c"SDL_webOSGetPanelResolution");

        let panel_resolution = if !panel_fn.is_null() {
            let get_res = std::mem::transmute::<*mut c_void, GetPanelResolutionFn>(panel_fn);
            let mut w: c_int = 0;
            let mut h: c_int = 0;
            if get_res(&mut w, &mut h) != 0 && w > 0 && h > 0 {
                Some((w, h))
            } else {
                None
            }
        } else {
            None
        };

        let supported = !create.is_null() && !set.is_null() && !destroy.is_null();
        let detail = if supported {
            match panel_resolution {
                Some((w, h)) => format!("SDL_webOS exported window OK ({w}x{h})"),
                None => "SDL_webOS exported window OK (panel res unavailable)".to_string(),
            }
        } else {
            "SDL_webOS exported window symbols absent (desktop/stock SDL2)".to_string()
        };

        ExportedWindowProbe {
            supported,
            panel_resolution,
            detail,
        }
    }
}

/// Computes integer source and aspect-preserving destination rectangles strictly inside `panel`.
pub fn compute_aspect_fit_rect(
    video_w: i32,
    video_h: i32,
    panel_w: i32,
    panel_h: i32,
) -> (SdlRect, SdlRect) {
    let pw = panel_w.max(1);
    let ph = panel_h.max(1);
    if video_w <= 0 || video_h <= 0 {
        return (
            SdlRect {
                x: 0,
                y: 0,
                w: FALLBACK_PANEL_W,
                h: FALLBACK_PANEL_H,
            },
            SdlRect {
                x: 0,
                y: 0,
                w: pw,
                h: ph,
            },
        );
    }

    let vw64 = i64::from(video_w);
    let vh64 = i64::from(video_h);
    let pw64 = i64::from(pw);
    let ph64 = i64::from(ph);

    let (dst_w, dst_h) = if vw64 * ph64 > pw64 * vh64 {
        let h = ((pw64 * vh64) / vw64).clamp(1, ph64) as i32;
        (pw, h)
    } else {
        let w = ((ph64 * vw64) / vh64).clamp(1, pw64) as i32;
        (w, ph)
    };

    let dst_x = (pw - dst_w) / 2;
    let dst_y = (ph - dst_h) / 2;
    (
        SdlRect {
            x: 0,
            y: 0,
            w: video_w,
            h: video_h,
        },
        SdlRect {
            x: dst_x,
            y: dst_y,
            w: dst_w,
            h: dst_h,
        },
    )
}

/// RAII handle owning a webOS compositor video plane created via `SDL_webOSCreateExportedWindow`.
pub struct ExportedVideoWindow {
    window_id: String,
    window_id_c: CString,
    panel_w: i32,
    panel_h: i32,
    set_fn: SetExportedWindowFn,
    destroy_fn: DestroyExportedWindowFn,
}

impl ExportedVideoWindow {
    /// Creates a new video-type exported window ID to pass in `option.windowId` at media Load.
    pub fn create(fallback_panel_w: i32, fallback_panel_h: i32) -> Result<Self, String> {
        let probe = probe_support();
        if !probe.supported {
            return Err(probe.detail);
        }

        // SAFETY: All three symbols were verified non-null by `probe_support`.
        let (create_fn, set_fn, destroy_fn): (
            CreateExportedWindowFn,
            SetExportedWindowFn,
            DestroyExportedWindowFn,
        ) = unsafe {
            let create = lookup_symbol(c"SDL_webOSCreateExportedWindow");
            let set = lookup_symbol(c"SDL_webOSSetExportedWindow");
            let destroy = lookup_symbol(c"SDL_webOSDestroyExportedWindow");
            (
                std::mem::transmute::<*mut c_void, CreateExportedWindowFn>(create),
                std::mem::transmute::<*mut c_void, SetExportedWindowFn>(set),
                std::mem::transmute::<*mut c_void, DestroyExportedWindowFn>(destroy),
            )
        };

        // SAFETY: Called on the SDL thread after video subsystem initialization; copy string immediately.
        let id_ptr = unsafe { create_fn(EXPORTED_WINDOW_TYPE_VIDEO) };
        if id_ptr.is_null() {
            return Err("SDL_webOSCreateExportedWindow returned NULL".to_string());
        }
        // SAFETY: Non-null NUL-terminated static/thread buffer returned by SDL2-webOS.
        let window_id = unsafe { CStr::from_ptr(id_ptr) }
            .to_string_lossy()
            .into_owned();
        let window_id_c = CString::new(window_id.as_str())
            .map_err(|_| "exported window id contains interior NUL".to_string())?;

        let (panel_w, panel_h) = probe.panel_resolution.unwrap_or((
            fallback_panel_w.max(FALLBACK_PANEL_W),
            fallback_panel_h.max(FALLBACK_PANEL_H),
        ));

        Ok(Self {
            window_id,
            window_id_c,
            panel_w,
            panel_h,
            set_fn,
            destroy_fn,
        })
    }

    pub fn window_id(&self) -> &str {
        &self.window_id
    }

    /// Returns the detected or fallback compositor panel resolution in pixels.
    pub fn panel_resolution(&self) -> (i32, i32) {
        (self.panel_w, self.panel_h)
    }

    /// Updates exported video plane source/destination geometry cleanly inside the TV panel.
    pub fn place(&self, video_w: i32, video_h: i32) -> Result<(SdlRect, SdlRect), String> {
        let (mut src, mut dst) =
            compute_aspect_fit_rect(video_w, video_h, self.panel_w, self.panel_h);
        // SAFETY: Valid NUL-terminated window id and writable stack `SDL_Rect` pointers.
        let ok = unsafe { (self.set_fn)(self.window_id_c.as_ptr(), &mut src, &mut dst) };
        if ok == 0 {
            return Err("SDL_webOSSetExportedWindow returned SDL_FALSE".to_string());
        }
        Ok((src, dst))
    }
}

impl Drop for ExportedVideoWindow {
    fn drop(&mut self) {
        // SAFETY: Valid window ID owned exclusively by this struct.
        unsafe {
            (self.destroy_fn)(self.window_id_c.as_ptr());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aspect_fit_letterboxes_cinemascope_inside_4k_panel() {
        let (src, dst) = compute_aspect_fit_rect(3840, 1608, 3840, 2160);
        assert_eq!(src.w, 3840);
        assert_eq!(src.h, 1608);
        assert_eq!(dst.x, 0);
        assert_eq!(dst.w, 3840);
        assert_eq!(dst.h, 1608);
        assert_eq!(dst.y, (2160 - 1608) / 2);
        assert!(dst.x >= 0 && dst.y >= 0 && dst.x + dst.w <= 3840 && dst.y + dst.h <= 2160);
    }

    #[test]
    fn aspect_fit_pillarboxes_4_3_and_handles_zero_dimensions() {
        let (_, dst) = compute_aspect_fit_rect(1440, 1080, 1920, 1080);
        assert_eq!(dst.w, 1440);
        assert_eq!(dst.h, 1080);
        assert_eq!(dst.x, 240);
        assert_eq!(dst.y, 0);

        let (src_zero, dst_zero) = compute_aspect_fit_rect(0, 0, 1920, 1080);
        assert_eq!((src_zero.w, src_zero.h), (1920, 1080));
        assert_eq!((dst_zero.w, dst_zero.h), (1920, 1080));
    }
}
