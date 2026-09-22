use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=src/rtf.m");
    let output = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let object = output.join("rtf.o");
    assert!(Command::new("xcrun").args(["clang", "-c", "-O2", "-fobjc-arc", "-arch", "arm64",
        "-mmacosx-version-min=14.0", "src/rtf.m", "-o"]).arg(&object).status().unwrap().success());
    assert!(Command::new("xcrun").args(["ar", "rcs"]).arg(output.join("librtf.a"))
        .arg(object).status().unwrap().success());
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=rtf");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=Foundation");
}
