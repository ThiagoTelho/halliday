fn main() {
    // A DLL with no DllMain: nothing runs when it loads.
    println!("cargo:rustc-link-arg-cdylib=/NOENTRY");
}
