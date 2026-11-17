//! Compiles the runtime's Metal side (`src/metal.m`) on macOS; elsewhere there is none.
fn main() {
    println!("cargo:rerun-if-changed=src/metal.m");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("src/metal.m")
            .flag("-fobjc-arc")
            .compile("halliday_openxr_metal");
        println!("cargo:rustc-link-lib=framework=Metal");
        println!("cargo:rustc-link-lib=framework=Foundation");
    }
}
