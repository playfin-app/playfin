use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

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
