//! Halliday's OpenXR runtime (ROADMAP W15; begun as the spike of W8).
//!
//! An OpenXR application talks to the Khronos loader; the loader finds a runtime through a JSON
//! manifest (`XR_RUNTIME_JSON`, or the active-runtime file) that names this library, calls
//! `xrNegotiateLoaderRuntimeInterface`, and from then on reaches every runtime function through
//! the `xrGetInstanceProcAddr` it got back.
//!
//! Here: the negotiation; creating and destroying an instance; the runtime's properties; one
//! head-mounted system (the PS VR2: two views, orientation and position tracking); its view
//! configuration (primary stereo) and blend mode (opaque). Sessions, spaces, swapchains
//! (`XR_KHR_metal_enable`), the frame loop and actions are in `session.rs`, on macOS, where
//! Halliday is. Functions of extensions it doesn't have answer `XR_ERROR_FUNCTION_UNSUPPORTED`.
//! Written for Halliday (MIT) from the OpenXR specification and the loader's runtime interface
//! document; types from `openxr-sys`.

use std::ffi::{CStr, c_char};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

use openxr_sys as xr;
use openxr_sys::Handle;
use openxr_sys::pfn;

#[cfg(target_os = "macos")]
mod session;
#[cfg(target_os = "macos")]
mod vulkan;

/// The session's functions: `session.rs` where Halliday runs, none elsewhere.
#[cfg(target_os = "macos")]
fn session_function(name: &[u8]) -> Option<pfn::VoidFunction> {
    session::lookup(name).or_else(|| vulkan::lookup(name))
}
#[cfg(not(target_os = "macos"))]
fn session_function(_name: &[u8]) -> Option<pfn::VoidFunction> {
    None
}

/// The runtime's name, as applications see it.
pub const RUNTIME_NAME: &str = "Halliday";
/// The one system this runtime has.
const SYSTEM_ID: u64 = 1;
/// Sony's USB vendor id: the PS VR2.
const VENDOR_ID: u32 = 0x054C;
/// Each eye's panel area: the render size recommended while Halliday isn't running to say its
/// own.
const EYE_WIDTH: u32 = 2000;
const EYE_HEIGHT: u32 = 2040;

/// The extensions the runtime has, with their versions: Metal swapchains, where there is Metal.
#[cfg(target_os = "macos")]
const EXTENSIONS: &[(&str, u32)] = &[
    ("XR_KHR_metal_enable", 1),
    ("XR_KHR_vulkan_enable2", 2),
    ("XR_KHR_vulkan_enable", 8),
];
#[cfg(not(target_os = "macos"))]
const EXTENSIONS: &[(&str, u32)] = &[];

/// The size each eye is to be drawn at: what Halliday asks for while it runs.
fn eye_size() -> (u32, u32) {
    #[cfg(target_os = "macos")]
    if let Some(size) = session::eye_size() {
        return size;
    }
    (EYE_WIDTH, EYE_HEIGHT)
}

/// Live instances (handles are never reused).
struct Instance {
    handle: u64,
    extensions: Vec<&'static str>,
    destroying: bool,
}
static INSTANCES: Mutex<Vec<Instance>> = Mutex::new(Vec::new());
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

// Integration tests temporarily own process-wide instance/session tables. Pure math/path
// tests remain parallel; every fixture that creates/destroys an instance shares this lease.
#[cfg(test)]
static TEST_RUNTIME_LOCK: Mutex<()> = Mutex::new(());

/// The loader's entry point into the runtime.
///
/// # Safety
/// `loader_info` and `runtime_request` must be valid pointers to the structs the OpenXR loader
/// passes (as the loader's runtime interface requires).
#[unsafe(no_mangle)]
pub unsafe extern "system" fn xrNegotiateLoaderRuntimeInterface(
    loader_info: *const xr::NegotiateLoaderInfo,
    runtime_request: *mut xr::NegotiateRuntimeRequest,
) -> xr::Result {
    let (Some(info), Some(request)) = (unsafe { loader_info.as_ref() }, unsafe {
        runtime_request.as_mut()
    }) else {
        return xr::Result::ERROR_INITIALIZATION_FAILED;
    };
    if info.struct_type != xr::NegotiateLoaderInfo::TYPE
        || info.struct_version != xr::LOADER_INFO_STRUCT_VERSION as u32
        || info.struct_size != size_of::<xr::NegotiateLoaderInfo>()
        || request.struct_type != xr::NegotiateRuntimeRequest::TYPE
        || request.struct_version != xr::RUNTIME_INFO_STRUCT_VERSION as u32
        || request.struct_size != size_of::<xr::NegotiateRuntimeRequest>()
        || info.min_interface_version > info.max_interface_version
        || info.min_api_version > info.max_api_version
    {
        return xr::Result::ERROR_INITIALIZATION_FAILED;
    }
    let ours = xr::CURRENT_LOADER_RUNTIME_VERSION as u32;
    if info.min_interface_version > ours || info.max_interface_version < ours {
        return xr::Result::ERROR_INITIALIZATION_FAILED;
    }
    // OpenXR 1.0 and 1.1 applications.
    let api = xr::Version::new(1, 1, 0);
    if info.max_api_version < xr::Version::new(1, 0, 0) || info.min_api_version > api {
        return xr::Result::ERROR_INITIALIZATION_FAILED;
    }
    request.runtime_interface_version = ours;
    request.runtime_api_version = if info.max_api_version < api {
        info.max_api_version
    } else {
        api
    };
    request.get_instance_proc_addr = Some(get_instance_proc_addr);
    xr::Result::SUCCESS
}

macro_rules! fp {
    ($f:expr, $t:ty) => {{
        let f: $t = $f;
        // SAFETY: OpenXR hands out every function as a `PFN_xrVoidFunction`; callers cast it back
        // to its real type before calling it.
        Some(unsafe { std::mem::transmute::<$t, pfn::VoidFunction>(f) })
    }};
}

unsafe extern "system" fn get_instance_proc_addr(
    instance: xr::Instance,
    name: *const c_char,
    function: *mut Option<pfn::VoidFunction>,
) -> xr::Result {
    let Some(out) = (unsafe { function.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = None;
    if name.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let name = unsafe { CStr::from_ptr(name) }.to_bytes();
    // Before an instance exists, only these may be asked for.
    let global = matches!(
        name,
        b"xrEnumerateInstanceExtensionProperties"
            | b"xrEnumerateApiLayerProperties"
            | b"xrCreateInstance"
    );
    if instance == xr::Instance::NULL && !global {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    if instance != xr::Instance::NULL && !is_live(instance) {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    let extension = match name {
        b"xrGetMetalGraphicsRequirementsKHR" => Some("XR_KHR_metal_enable"),
        b"xrGetVulkanGraphicsRequirementsKHR"
        | b"xrGetVulkanGraphicsDeviceKHR"
        | b"xrGetVulkanInstanceExtensionsKHR"
        | b"xrGetVulkanDeviceExtensionsKHR" => Some("XR_KHR_vulkan_enable"),
        b"xrGetVulkanGraphicsRequirements2KHR"
        | b"xrCreateVulkanInstanceKHR"
        | b"xrGetVulkanGraphicsDevice2KHR"
        | b"xrCreateVulkanDeviceKHR" => Some("XR_KHR_vulkan_enable2"),
        _ => None,
    };
    if extension.is_some_and(|extension| !extension_enabled(instance, extension)) {
        return xr::Result::ERROR_FUNCTION_UNSUPPORTED;
    }
    *out = match name {
        b"xrGetInstanceProcAddr" => fp!(get_instance_proc_addr, pfn::GetInstanceProcAddr),
        b"xrEnumerateApiLayerProperties" => fp!(
            enumerate_api_layer_properties,
            pfn::EnumerateApiLayerProperties
        ),
        b"xrEnumerateInstanceExtensionProperties" => fp!(
            enumerate_instance_extension_properties,
            pfn::EnumerateInstanceExtensionProperties
        ),
        b"xrCreateInstance" => fp!(create_instance, pfn::CreateInstance),
        b"xrDestroyInstance" => fp!(destroy_instance, pfn::DestroyInstance),
        b"xrGetInstanceProperties" => fp!(get_instance_properties, pfn::GetInstanceProperties),
        b"xrResultToString" => fp!(result_to_string, pfn::ResultToString),
        b"xrStructureTypeToString" => fp!(structure_type_to_string, pfn::StructureTypeToString),
        b"xrGetSystem" => fp!(get_system, pfn::GetSystem),
        b"xrGetSystemProperties" => fp!(get_system_properties, pfn::GetSystemProperties),
        b"xrEnumerateViewConfigurations" => fp!(
            enumerate_view_configurations,
            pfn::EnumerateViewConfigurations
        ),
        b"xrGetViewConfigurationProperties" => fp!(
            get_view_configuration_properties,
            pfn::GetViewConfigurationProperties
        ),
        b"xrEnumerateViewConfigurationViews" => fp!(
            enumerate_view_configuration_views,
            pfn::EnumerateViewConfigurationViews
        ),
        b"xrEnumerateEnvironmentBlendModes" => fp!(
            enumerate_environment_blend_modes,
            pfn::EnumerateEnvironmentBlendModes
        ),
        b"xrPollEvent" => fp!(poll_event, pfn::PollEvent),
        // Sessions and all that comes with them. The loader fills its dispatch table with every
        // core function when an instance is made and calls them without checking, so each must
        // resolve: where there is no session code (not macOS), to one that says so.
        n if CORE_SESSION.contains(&n) => session_function(n).or(Some(unsafe {
            std::mem::transmute::<unsafe extern "system" fn() -> xr::Result, pfn::VoidFunction>(
                not_here,
            )
        })),
        b"xrGetMetalGraphicsRequirementsKHR"
        | b"xrGetVulkanGraphicsRequirementsKHR"
        | b"xrGetVulkanGraphicsDeviceKHR"
        | b"xrGetVulkanInstanceExtensionsKHR"
        | b"xrGetVulkanDeviceExtensionsKHR"
        | b"xrGetVulkanGraphicsRequirements2KHR"
        | b"xrCreateVulkanInstanceKHR"
        | b"xrGetVulkanGraphicsDevice2KHR"
        | b"xrCreateVulkanDeviceKHR" => session_function(name),
        _ => None,
    };
    if out.is_some() {
        xr::Result::SUCCESS
    } else {
        xr::Result::ERROR_FUNCTION_UNSUPPORTED
    }
}

/// The core functions (OpenXR 1.0 and 1.1) that need a session.
const CORE_SESSION: &[&[u8]] = &[
    b"xrCreateSession",
    b"xrDestroySession",
    b"xrBeginSession",
    b"xrEndSession",
    b"xrRequestExitSession",
    b"xrEnumerateReferenceSpaces",
    b"xrCreateReferenceSpace",
    b"xrGetReferenceSpaceBoundsRect",
    b"xrCreateActionSpace",
    b"xrLocateSpace",
    b"xrLocateSpaces",
    b"xrDestroySpace",
    b"xrEnumerateSwapchainFormats",
    b"xrCreateSwapchain",
    b"xrDestroySwapchain",
    b"xrEnumerateSwapchainImages",
    b"xrAcquireSwapchainImage",
    b"xrWaitSwapchainImage",
    b"xrReleaseSwapchainImage",
    b"xrWaitFrame",
    b"xrBeginFrame",
    b"xrEndFrame",
    b"xrLocateViews",
    b"xrStringToPath",
    b"xrPathToString",
    b"xrCreateActionSet",
    b"xrDestroyActionSet",
    b"xrCreateAction",
    b"xrDestroyAction",
    b"xrSuggestInteractionProfileBindings",
    b"xrAttachSessionActionSets",
    b"xrGetCurrentInteractionProfile",
    b"xrGetActionStateBoolean",
    b"xrGetActionStateFloat",
    b"xrGetActionStateVector2f",
    b"xrGetActionStatePose",
    b"xrSyncActions",
    b"xrEnumerateBoundSourcesForAction",
    b"xrGetInputSourceLocalizedName",
    b"xrApplyHapticFeedback",
    b"xrStopHapticFeedback",
];

/// Stands in for a session function where there are no sessions. It takes no parameters: under
/// the C calling convention (AAPCS64, System V) a caller passing arguments to it is harmless.
unsafe extern "system" fn not_here() -> xr::Result {
    xr::Result::ERROR_RUNTIME_FAILURE
}

/// The next event: a session's change of state, when there is one.
unsafe extern "system" fn poll_event(
    instance: xr::Instance,
    buffer: *mut xr::EventDataBuffer,
) -> xr::Result {
    if !is_live(instance) {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    if buffer.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    #[cfg(target_os = "macos")]
    {
        // SAFETY: checked for null; the application's event buffer.
        unsafe { session::poll(instance.into_raw(), buffer) }
    }
    #[cfg(not(target_os = "macos"))]
    xr::Result::EVENT_UNAVAILABLE
}

fn is_live(instance: xr::Instance) -> bool {
    INSTANCES
        .lock()
        .map(|v| {
            v.iter()
                .any(|i| i.handle == instance.into_raw() && !i.destroying)
        })
        .unwrap_or(false)
}

fn extension_enabled(instance: xr::Instance, extension: &str) -> bool {
    INSTANCES
        .lock()
        .map(|v| {
            v.iter().any(|i| {
                i.handle == instance.into_raw()
                    && !i.destroying
                    && i.extensions.contains(&extension)
            })
        })
        .unwrap_or(false)
}

/// OpenXR's two-call idiom: with a capacity of 0, report how many; else fill up to the capacity.
///
/// # Safety
/// `count` must be valid; `out` must hold `capacity` elements when `capacity` > 0.
pub(crate) unsafe fn two_call<T: Copy>(
    items: &[T],
    capacity: u32,
    count: *mut u32,
    out: *mut T,
) -> xr::Result {
    let Some(count) = (unsafe { count.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *count = items.len() as u32;
    if capacity == 0 {
        return xr::Result::SUCCESS;
    }
    if (capacity as usize) < items.len() {
        return xr::Result::ERROR_SIZE_INSUFFICIENT;
    }
    if out.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    for (i, item) in items.iter().enumerate() {
        unsafe { out.add(i).write(*item) };
    }
    xr::Result::SUCCESS
}

/// Copies `s` into a fixed C string buffer (truncated, always terminated).
fn write_name<const N: usize>(buffer: &mut [c_char; N], s: &str) {
    let bytes = s.as_bytes();
    let n = bytes.len().min(N - 1);
    for (dst, &b) in buffer.iter_mut().zip(&bytes[..n]) {
        *dst = b as c_char;
    }
    buffer[n] = 0;
}

unsafe extern "system" fn enumerate_api_layer_properties(
    capacity: u32,
    count: *mut u32,
    out: *mut xr::ApiLayerProperties,
) -> xr::Result {
    unsafe { two_call::<xr::ApiLayerProperties>(&[], capacity, count, out) }
}

unsafe extern "system" fn enumerate_instance_extension_properties(
    layer: *const c_char,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::ExtensionProperties,
) -> xr::Result {
    if !layer.is_null() {
        return xr::Result::ERROR_API_LAYER_NOT_PRESENT;
    }
    let Some(count) = (unsafe { count.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *count = EXTENSIONS.len() as u32;
    if capacity == 0 {
        return xr::Result::SUCCESS;
    }
    if (capacity as usize) < EXTENSIONS.len() {
        return xr::Result::ERROR_SIZE_INSUFFICIENT;
    }
    if out.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    for (i, (name, version)) in EXTENSIONS.iter().enumerate() {
        // The application filled in `ty` and `next`; only the values are ours.
        let properties = unsafe { &mut *out.add(i) };
        write_name(&mut properties.extension_name, name);
        properties.extension_version = *version;
    }
    xr::Result::SUCCESS
}

unsafe extern "system" fn create_instance(
    info: *const xr::InstanceCreateInfo,
    instance: *mut xr::Instance,
) -> xr::Result {
    let (Some(info), Some(instance)) = (unsafe { info.as_ref() }, unsafe { instance.as_mut() })
    else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *instance = xr::Instance::NULL;
    if info.ty != xr::InstanceCreateInfo::TYPE {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    if info.enabled_extension_count != 0 && info.enabled_extension_names.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let api = info.application_info.api_version;
    if api.major() != 1 || api.minor() > 1 {
        return xr::Result::ERROR_API_VERSION_UNSUPPORTED;
    }
    let mut extensions = Vec::new();
    #[cfg(target_os = "macos")]
    let mut vulkan_enabled = false;
    #[cfg(target_os = "macos")]
    let mut legacy_vulkan_enabled = false;
    #[cfg(target_os = "macos")]
    let mut metal_enabled = false;
    for i in 0..info.enabled_extension_count as usize {
        // SAFETY: the application's array of `enabled_extension_count` C strings.
        let name = unsafe { *info.enabled_extension_names.add(i) };
        if name.is_null() {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        let asked = unsafe { CStr::from_ptr(name) };
        #[cfg(target_os = "macos")]
        if asked.to_bytes() == b"XR_KHR_vulkan_enable" {
            legacy_vulkan_enabled = true;
        }
        #[cfg(target_os = "macos")]
        if asked.to_bytes() == b"XR_KHR_vulkan_enable2" {
            vulkan_enabled = true;
        }
        #[cfg(target_os = "macos")]
        if asked.to_bytes() == b"XR_KHR_metal_enable" {
            metal_enabled = true;
        }
        let Some(&(extension, _)) = EXTENSIONS
            .iter()
            .find(|(name, _)| asked.to_bytes() == name.as_bytes())
        else {
            return xr::Result::ERROR_EXTENSION_NOT_PRESENT;
        };
        extensions.push(extension);
    }
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    let Ok(mut live) = INSTANCES.lock() else {
        return xr::Result::ERROR_RUNTIME_FAILURE;
    };
    // Session/input storage is process-wide. Refuse a second instance rather
    // than allowing its cleanup to destroy another application's live state.
    if !live.is_empty() {
        return xr::Result::ERROR_LIMIT_REACHED;
    }
    live.push(Instance {
        handle,
        extensions,
        destroying: false,
    });
    #[cfg(target_os = "macos")]
    vulkan::register(handle, vulkan_enabled, legacy_vulkan_enabled, metal_enabled);
    *instance = xr::Instance::from_raw(handle);
    xr::Result::SUCCESS
}

unsafe extern "system" fn destroy_instance(instance: xr::Instance) -> xr::Result {
    let Ok(mut live) = INSTANCES.lock() else {
        return xr::Result::ERROR_RUNTIME_FAILURE;
    };
    let Some(entry) = live
        .iter_mut()
        .find(|i| i.handle == instance.into_raw() && !i.destroying)
    else {
        return xr::Result::ERROR_HANDLE_INVALID;
    };
    // Keep the slot occupied until teardown completes, without holding this
    // mutex across Runtime cleanup (which can join the heartbeat worker).
    entry.destroying = true;
    drop(live);
    #[cfg(target_os = "macos")]
    {
        session::instance_destroyed(instance.into_raw());
        vulkan::unregister(instance.into_raw());
    }
    let Ok(mut live) = INSTANCES.lock() else {
        return xr::Result::ERROR_RUNTIME_FAILURE;
    };
    live.retain(|i| i.handle != instance.into_raw());
    xr::Result::SUCCESS
}

unsafe extern "system" fn get_instance_properties(
    instance: xr::Instance,
    out: *mut xr::InstanceProperties,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if !is_live(instance) {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    out.runtime_version = xr::Version::new(0, 0, 1);
    write_name(&mut out.runtime_name, RUNTIME_NAME);
    xr::Result::SUCCESS
}

unsafe extern "system" fn result_to_string(
    _: xr::Instance,
    value: xr::Result,
    buffer: *mut c_char,
) -> xr::Result {
    if buffer.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let text = format!("{value:?}");
    // SAFETY: the caller passes a buffer of XR_MAX_RESULT_STRING_SIZE characters.
    let buffer = unsafe { &mut *(buffer as *mut [c_char; xr::MAX_RESULT_STRING_SIZE]) };
    write_name(buffer, &text);
    xr::Result::SUCCESS
}

unsafe extern "system" fn structure_type_to_string(
    _: xr::Instance,
    value: xr::StructureType,
    buffer: *mut c_char,
) -> xr::Result {
    if buffer.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let text = format!("{value:?}");
    // SAFETY: the caller passes a buffer of XR_MAX_STRUCTURE_NAME_SIZE characters.
    let buffer = unsafe { &mut *(buffer as *mut [c_char; xr::MAX_STRUCTURE_NAME_SIZE]) };
    write_name(buffer, &text);
    xr::Result::SUCCESS
}

unsafe extern "system" fn get_system(
    instance: xr::Instance,
    info: *const xr::SystemGetInfo,
    system: *mut xr::SystemId,
) -> xr::Result {
    let (Some(info), Some(system)) = (unsafe { info.as_ref() }, unsafe { system.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if !is_live(instance) {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    if info.form_factor != xr::FormFactor::HEAD_MOUNTED_DISPLAY {
        return xr::Result::ERROR_FORM_FACTOR_UNSUPPORTED;
    }
    *system = xr::SystemId::from_raw(SYSTEM_ID);
    xr::Result::SUCCESS
}

unsafe extern "system" fn get_system_properties(
    instance: xr::Instance,
    system: xr::SystemId,
    out: *mut xr::SystemProperties,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if !is_live(instance) {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    if system.into_raw() != SYSTEM_ID {
        return xr::Result::ERROR_SYSTEM_INVALID;
    }
    out.system_id = system;
    out.vendor_id = VENDOR_ID;
    write_name(&mut out.system_name, "PlayStation VR2 (Halliday)");
    out.graphics_properties = xr::SystemGraphicsProperties {
        max_swapchain_image_width: 4096,
        max_swapchain_image_height: 4096,
        max_layer_count: (halliday_bridge::OVERLAYS + 1) as u32,
    };
    out.tracking_properties = xr::SystemTrackingProperties {
        orientation_tracking: xr::TRUE,
        position_tracking: xr::TRUE,
    };
    xr::Result::SUCCESS
}

fn check_system(instance: xr::Instance, system: xr::SystemId) -> Option<xr::Result> {
    if !is_live(instance) {
        return Some(xr::Result::ERROR_HANDLE_INVALID);
    }
    if system.into_raw() != SYSTEM_ID {
        return Some(xr::Result::ERROR_SYSTEM_INVALID);
    }
    None
}

unsafe extern "system" fn enumerate_view_configurations(
    instance: xr::Instance,
    system: xr::SystemId,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::ViewConfigurationType,
) -> xr::Result {
    if let Some(error) = check_system(instance, system) {
        return error;
    }
    unsafe {
        two_call(
            &[xr::ViewConfigurationType::PRIMARY_STEREO],
            capacity,
            count,
            out,
        )
    }
}

unsafe extern "system" fn get_view_configuration_properties(
    instance: xr::Instance,
    system: xr::SystemId,
    kind: xr::ViewConfigurationType,
    out: *mut xr::ViewConfigurationProperties,
) -> xr::Result {
    if let Some(error) = check_system(instance, system) {
        return error;
    }
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if kind != xr::ViewConfigurationType::PRIMARY_STEREO {
        return xr::Result::ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    out.view_configuration_type = kind;
    out.fov_mutable = xr::FALSE;
    xr::Result::SUCCESS
}

unsafe extern "system" fn enumerate_view_configuration_views(
    instance: xr::Instance,
    system: xr::SystemId,
    kind: xr::ViewConfigurationType,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::ViewConfigurationView,
) -> xr::Result {
    if let Some(error) = check_system(instance, system) {
        return error;
    }
    if kind != xr::ViewConfigurationType::PRIMARY_STEREO {
        return xr::Result::ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    let Some(count) = (unsafe { count.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *count = 2;
    if capacity == 0 {
        return xr::Result::SUCCESS;
    }
    if capacity < 2 {
        return xr::Result::ERROR_SIZE_INSUFFICIENT;
    }
    if out.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    for i in 0..2 {
        // The application filled in `ty` and `next`; only the values are ours.
        let view = unsafe { &mut *out.add(i) };
        (
            view.recommended_image_rect_width,
            view.recommended_image_rect_height,
        ) = eye_size();
        view.max_image_rect_width = 4096;
        view.max_image_rect_height = 4096;
        view.recommended_swapchain_sample_count = 1;
        view.max_swapchain_sample_count = 1;
    }
    xr::Result::SUCCESS
}

unsafe extern "system" fn enumerate_environment_blend_modes(
    instance: xr::Instance,
    system: xr::SystemId,
    kind: xr::ViewConfigurationType,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::EnvironmentBlendMode,
) -> xr::Result {
    if let Some(error) = check_system(instance, system) {
        return error;
    }
    if kind != xr::ViewConfigurationType::PRIMARY_STEREO {
        return xr::Result::ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    unsafe { two_call(&[xr::EnvironmentBlendMode::OPAQUE], capacity, count, out) }
}

#[cfg(test)]
mod tests {
    //! The calls the OpenXR loader and an application make, in their order.
    use super::*;
    use std::ptr;

    fn negotiate() -> pfn::GetInstanceProcAddr {
        let info = xr::NegotiateLoaderInfo {
            struct_type: xr::NegotiateLoaderInfo::TYPE,
            struct_version: xr::LOADER_INFO_STRUCT_VERSION as u32,
            struct_size: size_of::<xr::NegotiateLoaderInfo>(),
            min_interface_version: 1,
            max_interface_version: xr::CURRENT_LOADER_RUNTIME_VERSION as u32,
            min_api_version: xr::Version::new(1, 0, 0),
            max_api_version: xr::Version::new(1, 0x3ff, 0xfff),
        };
        let mut request = xr::NegotiateRuntimeRequest {
            struct_type: xr::NegotiateRuntimeRequest::TYPE,
            struct_version: xr::RUNTIME_INFO_STRUCT_VERSION as u32,
            struct_size: size_of::<xr::NegotiateRuntimeRequest>(),
            runtime_interface_version: 0,
            runtime_api_version: xr::Version::new(0, 0, 0),
            get_instance_proc_addr: None,
        };
        assert_eq!(
            unsafe { xrNegotiateLoaderRuntimeInterface(&info, &mut request) },
            xr::Result::SUCCESS
        );
        assert_eq!(request.runtime_api_version, xr::Version::new(1, 1, 0));
        request
            .get_instance_proc_addr
            .expect("a getInstanceProcAddr")
    }

    fn lookup<T>(gipa: pfn::GetInstanceProcAddr, instance: xr::Instance, name: &CStr) -> T {
        let mut f = None;
        assert_eq!(
            unsafe { gipa(instance, name.as_ptr(), &mut f) },
            xr::Result::SUCCESS,
            "{name:?}"
        );
        unsafe { std::mem::transmute_copy(&f.unwrap()) }
    }

    #[test]
    fn an_application_finds_the_headset() {
        let _runtime = TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let gipa = negotiate();
        let create: pfn::CreateInstance = lookup(gipa, xr::Instance::NULL, c"xrCreateInstance");
        let mut info: xr::InstanceCreateInfo = unsafe { std::mem::zeroed() };
        info.ty = xr::InstanceCreateInfo::TYPE;
        write_name(&mut info.application_info.application_name, "test");
        info.application_info.api_version = xr::Version::new(1, 0, 0);
        let mut instance = xr::Instance::NULL;
        assert_eq!(unsafe { create(&info, &mut instance) }, xr::Result::SUCCESS);

        let properties: pfn::GetInstanceProperties =
            lookup(gipa, instance, c"xrGetInstanceProperties");
        let mut p: xr::InstanceProperties = unsafe { std::mem::zeroed() };
        p.ty = xr::InstanceProperties::TYPE;
        assert_eq!(unsafe { properties(instance, &mut p) }, xr::Result::SUCCESS);
        assert_eq!(
            unsafe { CStr::from_ptr(p.runtime_name.as_ptr()) }
                .to_str()
                .unwrap(),
            RUNTIME_NAME
        );

        let get_system: pfn::GetSystem = lookup(gipa, instance, c"xrGetSystem");
        let get_info = xr::SystemGetInfo {
            ty: xr::SystemGetInfo::TYPE,
            next: ptr::null(),
            form_factor: xr::FormFactor::HEAD_MOUNTED_DISPLAY,
        };
        let mut system = xr::SystemId::NULL;
        assert_eq!(
            unsafe { get_system(instance, &get_info, &mut system) },
            xr::Result::SUCCESS
        );

        let views: pfn::EnumerateViewConfigurationViews =
            lookup(gipa, instance, c"xrEnumerateViewConfigurationViews");
        let mut count = 0;
        let stereo = xr::ViewConfigurationType::PRIMARY_STEREO;
        assert_eq!(
            unsafe { views(instance, system, stereo, 0, &mut count, ptr::null_mut()) },
            xr::Result::SUCCESS
        );
        assert_eq!(count, 2);
        let mut v: [xr::ViewConfigurationView; 2] = unsafe { std::mem::zeroed() };
        assert_eq!(
            unsafe { views(instance, system, stereo, 2, &mut count, v.as_mut_ptr()) },
            xr::Result::SUCCESS
        );
        assert_eq!(
            (
                v[0].recommended_image_rect_width,
                v[1].recommended_image_rect_height
            ),
            eye_size()
        );

        // A session needs a graphics binding (Metal); without one it says so.
        let create_session: pfn::CreateSession = lookup(gipa, instance, c"xrCreateSession");
        let session_info = xr::SessionCreateInfo {
            ty: xr::SessionCreateInfo::TYPE,
            next: ptr::null(),
            create_flags: xr::SessionCreateFlags::EMPTY,
            system_id: system,
        };
        let mut session = xr::Session::NULL;
        assert_eq!(
            unsafe { create_session(instance, &session_info, &mut session) },
            if cfg!(target_os = "macos") {
                xr::Result::ERROR_GRAPHICS_DEVICE_INVALID
            } else {
                xr::Result::ERROR_RUNTIME_FAILURE
            }
        );
        let poll: pfn::PollEvent = lookup(gipa, instance, c"xrPollEvent");
        let mut event: xr::EventDataBuffer = unsafe { std::mem::zeroed() };
        assert_eq!(
            unsafe { poll(instance, &mut event) },
            xr::Result::EVENT_UNAVAILABLE
        );
        // Extensions nobody enabled stay unresolved.
        let mut f = None;
        assert_eq!(
            unsafe { gipa(instance, c"xrGetVisibilityMaskKHR".as_ptr(), &mut f) },
            xr::Result::ERROR_FUNCTION_UNSUPPORTED
        );

        let destroy: pfn::DestroyInstance = lookup(gipa, instance, c"xrDestroyInstance");
        assert_eq!(unsafe { destroy(instance) }, xr::Result::SUCCESS);
        assert_eq!(
            unsafe { destroy(instance) },
            xr::Result::ERROR_HANDLE_INVALID
        );
    }

    #[test]
    fn handheld_systems_are_refused() {
        let _runtime = TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let gipa = negotiate();
        let create: pfn::CreateInstance = lookup(gipa, xr::Instance::NULL, c"xrCreateInstance");
        let mut info: xr::InstanceCreateInfo = unsafe { std::mem::zeroed() };
        info.ty = xr::InstanceCreateInfo::TYPE;
        info.application_info.api_version = xr::Version::new(1, 0, 0);
        let mut instance = xr::Instance::NULL;
        assert_eq!(unsafe { create(&info, &mut instance) }, xr::Result::SUCCESS);
        let get_system: pfn::GetSystem = lookup(gipa, instance, c"xrGetSystem");
        let get_info = xr::SystemGetInfo {
            ty: xr::SystemGetInfo::TYPE,
            next: ptr::null(),
            form_factor: xr::FormFactor::HANDHELD_DISPLAY,
        };
        let mut system = xr::SystemId::NULL;
        assert_eq!(
            unsafe { get_system(instance, &get_info, &mut system) },
            xr::Result::ERROR_FORM_FACTOR_UNSUPPORTED
        );
        assert_eq!(unsafe { destroy_instance(instance) }, xr::Result::SUCCESS);
    }

    #[test]
    fn unsupported_api_versions_do_not_create_an_instance() {
        let _runtime = TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let mut info: xr::InstanceCreateInfo = unsafe { std::mem::zeroed() };
        info.ty = xr::InstanceCreateInfo::TYPE;
        for version in [
            xr::Version::new(0, 0, 0),
            xr::Version::new(1, 2, 0),
            xr::Version::new(2, 0, 0),
        ] {
            info.application_info.api_version = version;
            let mut instance = xr::Instance::from_raw(u64::MAX);
            assert_eq!(
                unsafe { create_instance(&info, &mut instance) },
                xr::Result::ERROR_API_VERSION_UNSUPPORTED
            );
            assert_eq!(instance, xr::Instance::NULL);
        }
        // Patch numbers do not add API commands and are not a reason to reject an app.
        for version in [xr::Version::new(1, 0, 999), xr::Version::new(1, 1, 999)] {
            info.application_info.api_version = version;
            let mut instance = xr::Instance::NULL;
            assert_eq!(
                unsafe { create_instance(&info, &mut instance) },
                xr::Result::SUCCESS
            );
            assert_eq!(unsafe { destroy_instance(instance) }, xr::Result::SUCCESS);
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn graphics_dispatch_is_scoped_to_each_instances_enabled_extensions() {
        let _runtime = TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let gipa = negotiate();
        let extensions = [
            c"XR_KHR_metal_enable",
            c"XR_KHR_vulkan_enable",
            c"XR_KHR_vulkan_enable2",
        ];
        let commands: [&[&CStr]; 3] = [
            &[c"xrGetMetalGraphicsRequirementsKHR"],
            &[
                c"xrGetVulkanGraphicsRequirementsKHR",
                c"xrGetVulkanGraphicsDeviceKHR",
                c"xrGetVulkanInstanceExtensionsKHR",
                c"xrGetVulkanDeviceExtensionsKHR",
            ],
            &[
                c"xrGetVulkanGraphicsRequirements2KHR",
                c"xrCreateVulkanInstanceKHR",
                c"xrGetVulkanGraphicsDevice2KHR",
                c"xrCreateVulkanDeviceKHR",
            ],
        ];
        let mut info: xr::InstanceCreateInfo = unsafe { std::mem::zeroed() };
        info.ty = xr::InstanceCreateInfo::TYPE;
        info.application_info.api_version = xr::Version::new(1, 0, 0);
        for (instance_kind, extension) in extensions.iter().enumerate() {
            let name = extension.as_ptr();
            info.enabled_extension_count = 1;
            info.enabled_extension_names = &name;
            let mut instance = xr::Instance::NULL;
            assert_eq!(
                unsafe { create_instance(&info, &mut instance) },
                xr::Result::SUCCESS
            );
            let mut duplicate = xr::Instance::NULL;
            assert_eq!(
                unsafe { create_instance(&info, &mut duplicate) },
                xr::Result::ERROR_LIMIT_REACHED
            );
            assert_eq!(duplicate, xr::Instance::NULL);
            for (command_kind, commands) in commands.iter().enumerate() {
                for command in *commands {
                    let mut function = None;
                    let expected = if command_kind == instance_kind {
                        xr::Result::SUCCESS
                    } else {
                        xr::Result::ERROR_FUNCTION_UNSUPPORTED
                    };
                    assert_eq!(
                        unsafe { gipa(instance, command.as_ptr(), &mut function) },
                        expected,
                        "{command:?}"
                    );
                    assert_eq!(function.is_some(), command_kind == instance_kind);
                }
            }
            assert_eq!(unsafe { destroy_instance(instance) }, xr::Result::SUCCESS);
            let mut function = None;
            assert_eq!(
                unsafe {
                    gipa(
                        instance,
                        c"xrGetVulkanGraphicsRequirements2KHR".as_ptr(),
                        &mut function,
                    )
                },
                xr::Result::ERROR_HANDLE_INVALID
            );
        }
        let mut function = None;
        assert_eq!(
            unsafe {
                gipa(
                    xr::Instance::NULL,
                    c"xrGetInstanceProcAddr".as_ptr(),
                    &mut function,
                )
            },
            xr::Result::ERROR_HANDLE_INVALID
        );
    }
}
