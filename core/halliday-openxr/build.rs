//! Compiles the runtime's Metal side (`src/metal.m`) on macOS; elsewhere there is none.
fn main() {
    println!("cargo:rerun-if-changed=src/metal.m");
    println!("cargo:rerun-if-changed=src/vulkan.cpp");
    println!("cargo:rerun-if-changed=../halliday-bridge/include/readback_batch.h");
    println!("cargo:rerun-if-env-changed=VULKAN_SDK");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("src/metal.m")
            .flag("-fobjc-arc")
            .compile("halliday_openxr_metal");
        // Only Vulkan declarations are used. Calls go through the application's loader; the
        // runtime neither links a Vulkan driver nor embeds MoltenVK/a closed runtime.
        let include = std::env::var_os("VULKAN_SDK")
            .map(|sdk| std::path::PathBuf::from(sdk).join("include"))
            .unwrap_or_else(|| "/opt/homebrew/include".into());
        cc::Build::new()
            .cpp(true)
            .file("src/vulkan.cpp")
            .include(include)
            .flag("-std=c++17")
            .compile("halliday_openxr_vulkan");
        println!("cargo:rustc-link-lib=framework=Metal");
        println!("cargo:rustc-link-lib=framework=Foundation");
    }
}
