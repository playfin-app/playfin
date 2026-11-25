//! OpenGL / OpenGL ES surface configuration and 1080p virtual layout scaling.

use glow::HasContext;
use sdl2_sys::{SDL_GLattr, SDL_GLprofile};

pub const VIRTUAL_WIDTH: f32 = 1920.0;
pub const VIRTUAL_HEIGHT: f32 = 1080.0;

/// Target OpenGL profile selected by build target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GlTargetProfile {
    DesktopCore { major: u8, minor: u8 },
    OpenGlEs { major: u8, minor: u8 },
}

impl GlTargetProfile {
    /// Uses OpenGL ES 2.0 on webOS builds and OpenGL 3.3 Core on desktop simulator.
    pub const fn for_current_target() -> Self {
        #[cfg(feature = "webos")]
        {
            Self::OpenGlEs { major: 2, minor: 0 }
        }
        #[cfg(not(feature = "webos"))]
        {
            Self::DesktopCore { major: 3, minor: 3 }
        }
    }

    pub const fn sdl_profile(self) -> SDL_GLprofile {
        match self {
            Self::DesktopCore { .. } => SDL_GLprofile::SDL_GL_CONTEXT_PROFILE_CORE,
            Self::OpenGlEs { .. } => SDL_GLprofile::SDL_GL_CONTEXT_PROFILE_ES,
        }
    }

    pub const fn version(self) -> (u8, u8) {
        match self {
            Self::DesktopCore { major, minor } | Self::OpenGlEs { major, minor } => (major, minor),
        }
    }
}

/// Framebuffer and surface attributes required by femtovg and Starfish punch-through.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GlSurfaceSpec {
    pub profile: GlTargetProfile,
    pub alpha_bits: u8,
    pub stencil_bits: u8,
    pub double_buffer: bool,
    pub clear_rgba: [f32; 4],
}

impl Default for GlSurfaceSpec {
    fn default() -> Self {
        Self {
            profile: GlTargetProfile::for_current_target(),
            alpha_bits: 8,
            stencil_bits: 8,
            double_buffer: true,
            clear_rgba: [0.0, 0.0, 0.0, 0.0],
        }
    }
}

/// Returns the ordered `(attr, value)` pairs passed to `SDL_GL_SetAttribute` prior to window creation.
pub const fn required_gl_attributes(spec: &GlSurfaceSpec) -> [(SDL_GLattr, i32); 6] {
    let (major, minor) = spec.profile.version();
    [
        (
            SDL_GLattr::SDL_GL_CONTEXT_PROFILE_MASK,
            spec.profile.sdl_profile() as i32,
        ),
        (SDL_GLattr::SDL_GL_CONTEXT_MAJOR_VERSION, major as i32),
        (SDL_GLattr::SDL_GL_CONTEXT_MINOR_VERSION, minor as i32),
        (SDL_GLattr::SDL_GL_ALPHA_SIZE, spec.alpha_bits as i32),
        (SDL_GLattr::SDL_GL_STENCIL_SIZE, spec.stencil_bits as i32),
        (
            SDL_GLattr::SDL_GL_DOUBLEBUFFER,
            if spec.double_buffer { 1 } else { 0 },
        ),
    ]
}

/// Clears color and stencil buffers with transparent alpha for Starfish punch-through.
pub fn clear_transparent(gl: &glow::Context, spec: &GlSurfaceSpec) {
    let [r, g, b, a] = spec.clear_rgba;
    // SAFETY: Caller guarantees a valid, current OpenGL/GLES context.
    unsafe {
        gl.clear_color(r, g, b, a);
        gl.clear(glow::COLOR_BUFFER_BIT | glow::STENCIL_BUFFER_BIT);
    }
}

/// Uniform scale and letterbox offset mapping 1920x1080 virtual coordinates to physical pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ViewportTransform {
    pub scale: f32,
    pub offset_x: f32,
    pub offset_y: f32,
}

pub fn virtual_transform(physical_width: u32, physical_height: u32) -> ViewportTransform {
    if physical_width == 0 || physical_height == 0 {
        return ViewportTransform {
            scale: 1.0,
            offset_x: 0.0,
            offset_y: 0.0,
        };
    }
    let w = physical_width as f32;
    let h = physical_height as f32;
    let scale = (w / VIRTUAL_WIDTH).min(h / VIRTUAL_HEIGHT);
    let offset_x = (w - VIRTUAL_WIDTH * scale) * 0.5;
    let offset_y = (h - VIRTUAL_HEIGHT * scale) * 0.5;
    ViewportTransform {
        scale,
        offset_x,
        offset_y,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_spec_sets_alpha_stencil_and_transparent_clear() {
        let spec = GlSurfaceSpec::default();
        assert_eq!(spec.alpha_bits, 8);
        assert_eq!(spec.stencil_bits, 8);
        assert!(spec.double_buffer);
        assert_eq!(spec.clear_rgba, [0.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn desktop_profile_uses_core_3_3_and_es_profile_uses_gles() {
        assert_eq!(
            GlTargetProfile::DesktopCore { major: 3, minor: 3 }.sdl_profile() as u32,
            SDL_GLprofile::SDL_GL_CONTEXT_PROFILE_CORE as u32
        );
        assert_eq!(
            GlTargetProfile::OpenGlEs { major: 2, minor: 0 }.sdl_profile() as u32,
            SDL_GLprofile::SDL_GL_CONTEXT_PROFILE_ES as u32
        );
        let attrs = required_gl_attributes(&GlSurfaceSpec::default());
        assert!(
            attrs
                .iter()
                .any(|(a, v)| *a as u32 == SDL_GLattr::SDL_GL_ALPHA_SIZE as u32 && *v == 8)
        );
        assert!(
            attrs
                .iter()
                .any(|(a, v)| *a as u32 == SDL_GLattr::SDL_GL_STENCIL_SIZE as u32 && *v == 8)
        );
    }

    #[test]
    fn virtual_transform_scales_1280x720_and_letterboxes_ultrawide() {
        let t = virtual_transform(1280, 720);
        assert!((t.scale - (2.0 / 3.0)).abs() < 1e-5);
        assert!(t.offset_x.abs() < 1e-4);
        assert!(t.offset_y.abs() < 1e-4);

        let wide = virtual_transform(2560, 1080);
        assert!((wide.scale - 1.0).abs() < 1e-5);
        assert!((wide.offset_x - 320.0).abs() < 1e-4);
        assert!(wide.offset_y.abs() < 1e-4);
    }
}
