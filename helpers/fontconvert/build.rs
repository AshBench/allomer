//! Compiles the HarfBuzz/WOFF2 bridge and links the static libraries that
//! tools/build-fonts.py installed. FONTCONVERT_PREFIX names that install prefix.

use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=shim/fontshim.cc");
    println!("cargo:rerun-if-env-changed=FONTCONVERT_PREFIX");
    let prefix = PathBuf::from(
        std::env::var("FONTCONVERT_PREFIX")
            .expect("Set FONTCONVERT_PREFIX to the prefix built by tools/build-fonts.py."),
    );
    let include = prefix.join("include");
    assert!(
        include.join("harfbuzz/hb-subset.h").is_file() && include.join("woff2/encode.h").is_file(),
        "The font library prefix is incomplete. Run tools/build-fonts.py first."
    );
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("shim/fontshim.cc")
        .include(&include)
        .include(include.join("harfbuzz"))
        .opt_level(2)
        .compile("fontshim");
    println!("cargo:rustc-link-search=native={}", prefix.join("lib").display());
    for library in ["harfbuzz-subset", "harfbuzz", "woff2enc", "woff2dec", "woff2common",
                    "brotlienc", "brotlidec", "brotlicommon"] {
        println!("cargo:rustc-link-lib=static={library}");
    }
    println!("cargo:rustc-link-lib=dylib=c++");
}
