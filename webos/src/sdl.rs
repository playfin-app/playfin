//! Minimal safe RAII bindings over `sdl2-sys` avoiding struct-literal ABI drift on patched targets.

use crate::gl_config::{GlSurfaceSpec, required_gl_attributes};
use sdl2_sys as sys;
use std::ffi::{CStr, CString, c_void};
use std::marker::PhantomData;
use std::mem::MaybeUninit;
use std::ptr::{NonNull, addr_of};

/// High-level input and lifecycle events normalized across simulator and webOS SDL2.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SdlEvent {
    Quit,
    KeyDown { keycode: i32, scancode: u32 },
    MouseMotion { x: i32, y: i32 },
    MouseButtonDown { x: i32, y: i32 },
}

/// Sets an SDL runtime hint before subsystem initialization.
pub fn set_hint(name: &str, value: &str) -> bool {
    let Ok(c_name) = CString::new(name) else {
        return false;
    };
    let Ok(c_value) = CString::new(value) else {
        return false;
    };
    // SAFETY: Both pointers reference valid NUL-terminated strings for the duration of the call.
    unsafe { sys::SDL_SetHint(c_name.as_ptr(), c_value.as_ptr()) == sys::SDL_bool::SDL_TRUE }
}

fn last_sdl_error() -> String {
    // SAFETY: `SDL_GetError` always returns a valid static/thread-local C string (or empty string).
    let ptr = unsafe { sys::SDL_GetError() };
    if ptr.is_null() {
        return "unknown SDL error".to_string();
    }
    // SAFETY: Non-null C string returned by `SDL_GetError`.
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

/// RAII guard for SDL2 video subsystem initialization (`SDL_Init` / `SDL_Quit`).
pub struct SdlContext {
    _private: (),
}

impl SdlContext {
    /// Initializes SDL video and event subsystems.
    pub fn init_video() -> Result<Self, String> {
        // SAFETY: Called once on main thread; balanced by `SDL_Quit` in `Drop`.
        let rc = unsafe { sys::SDL_Init(sys::SDL_INIT_VIDEO) };
        if rc != 0 {
            return Err(last_sdl_error());
        }
        Ok(Self { _private: () })
    }

    /// Creates an OpenGL/GLES window and active context using `spec`.
    pub fn create_gl_window(
        &self,
        title: &str,
        width: i32,
        height: i32,
        spec: &GlSurfaceSpec,
    ) -> Result<SdlGlWindow<'_>, String> {
        SdlGlWindow::create(self, title, width, height, spec)
    }

    /// Polls pending SDL events, skipping irrelevant system events until a tracked event or empty queue.
    pub fn poll_event(&self) -> Option<SdlEvent> {
        loop {
            let mut raw = MaybeUninit::<sys::SDL_Event>::zeroed();
            // SAFETY: `raw` is properly aligned and sized for `SDL_Event`.
            let has_event = unsafe { sys::SDL_PollEvent(raw.as_mut_ptr()) } != 0;
            if !has_event {
                return None;
            }
            let event_ptr = raw.as_ptr();
            // SAFETY: `SDL_PollEvent` returned non-zero so `type_` is initialized across all variants.
            let kind = unsafe { (*event_ptr).type_ };

            if kind == sys::SDL_EventType::SDL_QUIT as u32 {
                return Some(SdlEvent::Quit);
            }
            if kind == sys::SDL_EventType::SDL_KEYDOWN as u32 {
                // SAFETY: `kind == SDL_KEYDOWN` selects `event.key`. Reading `scancode` as raw `u32`
                // avoids constructing an invalid Rust enum discriminant for custom webOS scancodes.
                let (keycode, scancode) = unsafe {
                    let key_ptr = addr_of!((*event_ptr).key);
                    let sym = (*key_ptr).keysym.sym;
                    let raw_scancode = addr_of!((*key_ptr).keysym.scancode)
                        .cast::<u32>()
                        .read_unaligned();
                    (sym, raw_scancode)
                };
                return Some(SdlEvent::KeyDown { keycode, scancode });
            }
            if kind == sys::SDL_EventType::SDL_MOUSEMOTION as u32 {
                // SAFETY: `kind == SDL_MOUSEMOTION` selects `event.motion`.
                let (x, y) = unsafe {
                    let motion = addr_of!((*event_ptr).motion);
                    ((*motion).x, (*motion).y)
                };
                return Some(SdlEvent::MouseMotion { x, y });
            }
            if kind == sys::SDL_EventType::SDL_MOUSEBUTTONDOWN as u32 {
                // SAFETY: `kind == SDL_MOUSEBUTTONDOWN` selects `event.button`.
                let (x, y) = unsafe {
                    let button = addr_of!((*event_ptr).button);
                    ((*button).x, (*button).y)
                };
                return Some(SdlEvent::MouseButtonDown { x, y });
            }
        }
    }
}

impl Drop for SdlContext {
    fn drop(&mut self) {
        // SAFETY: Balances `SDL_Init`; `'sdl` lifetime on windows ensures GL contexts/windows drop first.
        unsafe {
            sys::SDL_Quit();
        }
    }
}

/// Owned SDL window paired with its OpenGL/GLES context, guaranteeing safe teardown order.
pub struct SdlGlWindow<'sdl> {
    gl_ctx: sys::SDL_GLContext,
    window: NonNull<sys::SDL_Window>,
    _sdl: PhantomData<&'sdl SdlContext>,
}

impl<'sdl> SdlGlWindow<'sdl> {
    fn create(
        _sdl: &'sdl SdlContext,
        title: &str,
        width: i32,
        height: i32,
        spec: &GlSurfaceSpec,
    ) -> Result<Self, String> {
        let c_title = CString::new(title).map_err(|_| "window title contains NUL".to_string())?;

        for (attr, val) in required_gl_attributes(spec) {
            // SAFETY: Valid GL attribute/value requested prior to window creation.
            let rc = unsafe { sys::SDL_GL_SetAttribute(attr, val) };
            if rc != 0 {
                return Err(last_sdl_error());
            }
        }

        let pos = sys::SDL_WINDOWPOS_CENTERED_MASK as i32;
        #[cfg(feature = "webos")]
        let flags = sys::SDL_WindowFlags::SDL_WINDOW_OPENGL as u32
            | sys::SDL_WindowFlags::SDL_WINDOW_SHOWN as u32
            | sys::SDL_WindowFlags::SDL_WINDOW_FULLSCREEN_DESKTOP as u32;
        #[cfg(not(feature = "webos"))]
        let flags = sys::SDL_WindowFlags::SDL_WINDOW_OPENGL as u32
            | sys::SDL_WindowFlags::SDL_WINDOW_SHOWN as u32
            | sys::SDL_WindowFlags::SDL_WINDOW_RESIZABLE as u32
            | sys::SDL_WindowFlags::SDL_WINDOW_ALLOW_HIGHDPI as u32;

        // SAFETY: SDL video subsystem is initialized (`&'sdl SdlContext`) and title is NUL-terminated.
        let raw_window =
            unsafe { sys::SDL_CreateWindow(c_title.as_ptr(), pos, pos, width, height, flags) };
        let Some(window) = NonNull::new(raw_window) else {
            return Err(last_sdl_error());
        };

        // SAFETY: `window` is a valid non-null OpenGL SDL window.
        let gl_ctx = unsafe { sys::SDL_GL_CreateContext(window.as_ptr()) };
        if gl_ctx.is_null() {
            // SAFETY: Roll back window creation on GL context failure.
            unsafe { sys::SDL_DestroyWindow(window.as_ptr()) };
            return Err(last_sdl_error());
        }

        Ok(Self {
            gl_ctx,
            window,
            _sdl: PhantomData,
        })
    }

    /// Sets GL swap interval (`1` = VSync). Ignores unsupported drivers gracefully.
    pub fn set_vsync(&self, enabled: bool) {
        let interval = i32::from(enabled);
        // SAFETY: Current GL context belongs to this thread/window.
        let _ = unsafe { sys::SDL_GL_SetSwapInterval(interval) };
    }

    /// Resolves an OpenGL/GLES function pointer for `glow` or `femtovg`.
    pub fn gl_get_proc_address(&self, proc_name: &str) -> *const c_void {
        let Ok(c_name) = CString::new(proc_name) else {
            return std::ptr::null();
        };
        // SAFETY: GL context is current and `c_name` is a valid NUL-terminated symbol name.
        unsafe { sys::SDL_GL_GetProcAddress(c_name.as_ptr()) as *const c_void }
    }

    /// Queries the physical pixel dimensions of the GL drawable surface.
    pub fn drawable_size(&self) -> (u32, u32) {
        let mut w: i32 = 0;
        let mut h: i32 = 0;
        // SAFETY: `self.window` is a valid live SDL_Window and both out-pointers are valid.
        unsafe { sys::SDL_GL_GetDrawableSize(self.window.as_ptr(), &mut w, &mut h) };
        (w.max(0) as u32, h.max(0) as u32)
    }

    /// Queries the logical window dimensions used by SDL pointer events.
    pub fn window_size(&self) -> (u32, u32) {
        let mut w: i32 = 0;
        let mut h: i32 = 0;
        // SAFETY: `self.window` is a valid live SDL_Window and both out-pointers are valid.
        unsafe { sys::SDL_GetWindowSize(self.window.as_ptr(), &mut w, &mut h) };
        (w.max(0) as u32, h.max(0) as u32)
    }

    /// Presents the rendered framebuffer.
    pub fn swap_window(&self) {
        // SAFETY: `self.window` is valid and has an active OpenGL context.
        unsafe { sys::SDL_GL_SwapWindow(self.window.as_ptr()) };
    }
}

impl Drop for SdlGlWindow<'_> {
    fn drop(&mut self) {
        // SAFETY: Destroy GL context strictly before destroying the owning SDL window.
        unsafe {
            sys::SDL_GL_DeleteContext(self.gl_ctx);
            sys::SDL_DestroyWindow(self.window.as_ptr());
        }
    }
}
