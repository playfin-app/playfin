use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=WEBOS_SYSROOT");

    // Cross-compile builds for LG webOS link against the Buildroot sysroot. At runtime the
    // TV's own /usr/lib/libSDL2 is used: the sysroot copy only has stub exported-window
    // functions (no video plane), so it must never be bundled or found via an rpath.
    if let Ok(sysroot) = std::env::var("WEBOS_SYSROOT")
        && !sysroot.is_empty()
    {
        println!("cargo:rustc-link-search=native={sysroot}/usr/lib");
        if Path::new(&sysroot)
            .join("usr/lib/libglibc_polyfills.a")
            .exists()
        {
            // Link after std/ring/sqlite objects so Rust std's getauxval reference is satisfied.
            println!("cargo:rustc-link-arg=-lglibc_polyfills");
            println!("cargo:rustc-link-arg=-ldl");
        } else {
            println!("cargo:warning=libglibc_polyfills.a not found under {sysroot}/usr/lib");
        }
        return;
    }

    // Help desktop simulator builds on Apple Silicon macOS find Homebrew's SDL2
    // without requiring callers to set LIBRARY_PATH manually.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        for candidate in ["/opt/homebrew/lib", "/usr/local/lib"] {
            if Path::new(candidate).join("libSDL2.dylib").exists() {
                println!("cargo:rustc-link-search=native={candidate}");
            }
        }
    }
}
