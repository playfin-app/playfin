//! Decoding of BlurHash images into raw RGBA bytes (32 bits).
//!
//! The standard BlurHash algorithm decodes a compact string (representing a truncated DCT)
//! into an array of RGBA pixels without any external dependency.

use crate::JellyfinError;

/// Decodes a single base83 character into an integer 0..=82.
fn decode_base83_char(b: u8) -> Option<u32> {
    match b {
        b'0'..=b'9' => Some((b - b'0') as u32),
        b'A'..=b'Z' => Some((b - b'A' + 10) as u32),
        b'a'..=b'z' => Some((b - b'a' + 36) as u32),
        b'#' => Some(62),
        b'$' => Some(63),
        b'%' => Some(64),
        b'*' => Some(65),
        b'+' => Some(66),
        b',' => Some(67),
        b'-' => Some(68),
        b'.' => Some(69),
        b':' => Some(70),
        b';' => Some(71),
        b'=' => Some(72),
        b'?' => Some(73),
        b'@' => Some(74),
        b'[' => Some(75),
        b']' => Some(76),
        b'^' => Some(77),
        b'_' => Some(78),
        b'{' => Some(79),
        b'|' => Some(80),
        b'}' => Some(81),
        b'~' => Some(82),
        _ => None,
    }
}

/// Decodes a base83 string into a 32-bit integer.
fn decode_base83(s: &str) -> Result<u32, JellyfinError> {
    let mut value: u32 = 0;
    for &b in s.as_bytes() {
        let digit = decode_base83_char(b).ok_or_else(|| {
            JellyfinError::Decode(format!(
                "Invalid blurhash: invalid character '{}'",
                b as char
            ))
        })?;
        value = value
            .checked_mul(83)
            .and_then(|v| v.checked_add(digit))
            .ok_or_else(|| JellyfinError::Decode("Invalid blurhash: integer overflow".into()))?;
    }
    Ok(value)
}

/// Converts an sRGB byte (0..=255) into a normalised linear component (0.0..=1.0).
fn srgb_to_linear(value: u8) -> f32 {
    let v = (value as f32) / 255.0;
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

/// Converts a linear component (0.0..=1.0) into an sRGB byte (0..=255).
fn linear_to_srgb(value: f32) -> u8 {
    if value.is_nan() || value <= 0.0 {
        return 0;
    }
    if value >= 1.0 {
        return 255;
    }
    let s = if value <= 0.0031308 {
        value * 12.92
    } else {
        1.055 * value.powf(1.0 / 2.4) - 0.055
    };
    (s * 255.0 + 0.5).clamp(0.0, 255.0) as u8
}

/// Squares while preserving the sign: `copysign(v^2, v)`.
fn sign_pow2(value: f32) -> f32 {
    if value < 0.0 {
        -value * value
    } else {
        value * value
    }
}

/// Decodes a BlurHash into an array of RGBA bytes of `width` × `height` dimensions.
///
/// Returns exactly `width * height * 4` bytes (R, G, B, A=255 for each pixel).
/// On error (invalid format, zero dimensions, forbidden characters),
/// returns `JellyfinError::Decode` without ever panicking.
pub fn decode_blurhash_to_rgba(
    blur_hash: &str,
    width: u32,
    height: u32,
) -> Result<Vec<u8>, JellyfinError> {
    if width == 0 || height == 0 {
        return Err(JellyfinError::Decode(
            "Invalid blurhash dimensions: width and height must be greater than 0".into(),
        ));
    }

    if width > 1024 || height > 1024 {
        return Err(JellyfinError::Decode(
            "BlurHash decode dimension exceeds maximum supported limit (1024x1024)".into(),
        ));
    }

    if blur_hash.len() < 6 {
        return Err(JellyfinError::Decode(format!(
            "Invalid blurhash: length must be at least 6, got {}",
            blur_hash.len()
        )));
    }

    if !blur_hash.is_ascii() {
        return Err(JellyfinError::Decode(
            "Invalid blurhash: string must contain only ASCII characters".into(),
        ));
    }

    let pixel_count = (width as usize)
        .checked_mul(height as usize)
        .ok_or_else(|| JellyfinError::Decode("Invalid dimensions: overflow".into()))?;
    let byte_count = pixel_count
        .checked_mul(4)
        .ok_or_else(|| JellyfinError::Decode("Invalid dimensions: overflow".into()))?;

    // 1. Decoding of the size flag (character 0)
    let size_flag = decode_base83(&blur_hash[0..1])?;
    let num_y = (size_flag / 9) + 1;
    let num_x = (size_flag % 9) + 1;

    if num_x > 9 || num_y > 9 {
        return Err(JellyfinError::Decode(
            "Invalid blurhash: component count exceeds maximum of 9".into(),
        ));
    }

    let expected_len = 4 + 2 * (num_x as usize) * (num_y as usize);
    if blur_hash.len() != expected_len {
        return Err(JellyfinError::Decode(format!(
            "Invalid blurhash: expected length {expected_len}, got {}",
            blur_hash.len()
        )));
    }

    // 2. Maximum AC amplitude factor (character 1)
    let quantized_max = decode_base83(&blur_hash[1..2])?;
    let max_value = ((quantized_max + 1) as f32) / 166.0;

    // 3. Average DC component (characters 2..6)
    let dc_value = decode_base83(&blur_hash[2..6])?;
    let r_dc = srgb_to_linear(((dc_value >> 16) & 255) as u8);
    let g_dc = srgb_to_linear(((dc_value >> 8) & 255) as u8);
    let b_dc = srgb_to_linear((dc_value & 255) as u8);

    let num_components = (num_x * num_y) as usize;
    let mut colors = Vec::with_capacity(num_components);
    colors.push([r_dc, g_dc, b_dc]);

    // 4. AC components (2 characters each)
    for i in 1..num_components {
        let start = 4 + i * 2;
        let ac_value = decode_base83(&blur_hash[start..start + 2])?;
        let quant_r = (ac_value / (19 * 19)) as f32;
        let quant_g = ((ac_value / 19) % 19) as f32;
        let quant_b = (ac_value % 19) as f32;

        let r = sign_pow2(((quant_r - 9.0) / 9.0).clamp(-1.0, 1.0)) * max_value;
        let g = sign_pow2(((quant_g - 9.0) / 9.0).clamp(-1.0, 1.0)) * max_value;
        let b = sign_pow2(((quant_b - 9.0) / 9.0).clamp(-1.0, 1.0)) * max_value;
        colors.push([r, g, b]);
    }

    // 5. Precomputation of the cosines to speed up the DCT reconstruction
    let mut cos_x = Vec::with_capacity(width as usize);
    for x in 0..width {
        let mut row = Vec::with_capacity(num_x as usize);
        let x_f = x as f32;
        for i in 0..num_x {
            let factor = std::f32::consts::PI * (i as f32) * x_f / (width as f32);
            row.push(factor.cos());
        }
        cos_x.push(row);
    }

    let mut cos_y = Vec::with_capacity(height as usize);
    for y in 0..height {
        let mut col = Vec::with_capacity(num_y as usize);
        let y_f = y as f32;
        for j in 0..num_y {
            let factor = std::f32::consts::PI * (j as f32) * y_f / (height as f32);
            col.push(factor.cos());
        }
        cos_y.push(col);
    }

    // 6. Rendering of the RGBA pixels
    let mut rgba = Vec::with_capacity(byte_count);
    for cy in &cos_y {
        for cx in &cos_x {
            let mut r = 0.0_f32;
            let mut g = 0.0_f32;
            let mut b = 0.0_f32;

            for (j, &basis_y) in cy.iter().enumerate() {
                let row_offset = j * (num_x as usize);
                for (i, &basis_x) in cx.iter().enumerate() {
                    let basis = basis_x * basis_y;
                    let color = colors[row_offset + i];
                    r += color[0] * basis;
                    g += color[1] * basis;
                    b += color[2] * basis;
                }
            }

            rgba.push(linear_to_srgb(r));
            rgba.push(linear_to_srgb(g));
            rgba.push(linear_to_srgb(b));
            rgba.push(255);
        }
    }

    Ok(rgba)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Valid base83 characters according to the BlurHash specification.
    const BASE83_ALPHABET: &[u8; 83] =
        b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~";

    #[test]
    fn test_base83_alphabet_completeness() {
        assert_eq!(BASE83_ALPHABET.len(), 83);
        for (i, &b) in BASE83_ALPHABET.iter().enumerate() {
            assert_eq!(
                decode_base83_char(b),
                Some(i as u32),
                "Character '{}' failed to map to {}",
                b as char,
                i
            );
        }
    }

    #[test]
    fn test_decode_solid_colors_gives_exact_pixels() {
        // 1×1 hash (a single component): white then pure red.
        let white = decode_blurhash_to_rgba("00TSUA", 4, 4).unwrap();
        assert_eq!(white.len(), 4 * 4 * 4);
        assert!(white.chunks(4).all(|px| px == [255, 255, 255, 255]));

        let red = decode_blurhash_to_rgba("00TI:j", 2, 2).unwrap();
        assert!(red.chunks(4).all(|px| px == [255, 0, 0, 255]));
    }

    #[test]
    fn test_decode_valid_blurhash() {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
        let width = 32;
        let height = 32;
        let rgba = decode_blurhash_to_rgba(hash, width, height).expect("Decoding should succeed");

        assert_eq!(rgba.len(), (width * height * 4) as usize);

        // All the alpha values must be 255
        for (i, &byte) in rgba.iter().enumerate() {
            if i % 4 == 3 {
                assert_eq!(byte, 255, "Alpha channel must be 255");
            }
        }
    }

    #[test]
    fn test_decode_small_dimensions() {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
        let rgba = decode_blurhash_to_rgba(hash, 4, 3).expect("Decoding should succeed");
        assert_eq!(rgba.len(), 4 * 3 * 4);
    }

    #[test]
    fn test_decode_invalid_dimensions() {
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj";
        assert!(matches!(
            decode_blurhash_to_rgba(hash, 0, 32),
            Err(JellyfinError::Decode(_))
        ));
        assert!(matches!(
            decode_blurhash_to_rgba(hash, 32, 0),
            Err(JellyfinError::Decode(_))
        ));
        assert!(matches!(
            decode_blurhash_to_rgba(hash, 1025, 32),
            Err(JellyfinError::Decode(_))
        ));
        assert!(matches!(
            decode_blurhash_to_rgba(hash, 32, 1025),
            Err(JellyfinError::Decode(_))
        ));
    }

    #[test]
    fn test_decode_invalid_lengths() {
        // Trop court (< 6)
        assert!(matches!(
            decode_blurhash_to_rgba("", 10, 10),
            Err(JellyfinError::Decode(_))
        ));
        assert!(matches!(
            decode_blurhash_to_rgba("LEHV6", 10, 10),
            Err(JellyfinError::Decode(_))
        ));

        // Wrong length for a hash of 4x3 components (expected 28, here 27)
        let hash_27 = "LEHV6nWB2yk8pyo0adR*.7kCMdn";
        assert!(matches!(
            decode_blurhash_to_rgba(hash_27, 10, 10),
            Err(JellyfinError::Decode(_))
        ));
    }

    #[test]
    fn test_decode_invalid_characters() {
        // '!' is not in the base83 alphabet
        let invalid_hash = "LEHV6nWB2yk8pyo0adR!.7kCMdnj";
        assert!(matches!(
            decode_blurhash_to_rgba(invalid_hash, 10, 10),
            Err(JellyfinError::Decode(_))
        ));

        // Non-ASCII Unicode characters
        let unicode_hash = "LEHV6nWB2yk8pyo0adR*.7kCMdn😀";
        assert!(matches!(
            decode_blurhash_to_rgba(unicode_hash, 10, 10),
            Err(JellyfinError::Decode(_))
        ));
    }

    #[test]
    fn test_decode_never_panics_on_fuzz() {
        let fuzz_inputs = [
            "0",
            "000000",
            "~~~~~~~~~~~~",
            "   ",
            "??????",
            "LEHV6nWB2yk8pyo0adR*.7kCMdnj extra",
        ];
        for input in fuzz_inputs {
            let _ = decode_blurhash_to_rgba(input, 16, 16);
        }
    }
}
