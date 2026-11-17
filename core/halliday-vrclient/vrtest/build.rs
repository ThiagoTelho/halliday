fn main() {
    // A console program with its own entry point (no C runtime to call main).
    println!("cargo:rustc-link-arg-bins=/ENTRY:start");
    println!("cargo:rustc-link-arg-bins=/SUBSYSTEM:CONSOLE");
}
