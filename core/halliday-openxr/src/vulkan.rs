//! Public XR_KHR_vulkan_enable2 entry points. The graphics implementation is our Vulkan
//! image/readback helper, driven exclusively by the application's Vulkan proc-address function.
use openxr_sys::{self as xr, Handle, pfn};
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{LazyLock, Mutex};

#[derive(Default)]
struct Instance {
    enabled: bool,
    legacy_enabled: bool,
    legacy_requirements: bool,
    metal_enabled: bool,
    metal_requirements: bool,
    requirements: bool,
    loader: usize,
    vk_instance: usize,
    physical: usize,
    device: usize,
    /// family, requested count, queue-create flags. Borrow no caller create-info pointers.
    queues: Vec<[u32; 3]>,
}
static INSTANCES: LazyLock<Mutex<HashMap<u64, Instance>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static EARLY_LOADER: AtomicUsize = AtomicUsize::new(0);

#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct ReadbackRequest {
    pub image: *mut c_void,
    pub slice: u32,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub output: *mut u8,
}

unsafe extern "C" {
    fn dlsym(handle: *mut c_void, name: *const std::ffi::c_char) -> *mut c_void;
}

fn application_loader() -> usize {
    let early = EARLY_LOADER.load(Ordering::Acquire);
    if early != 0 {
        return early;
    }
    // Darwin RTLD_DEFAULT: use an application-visible Vulkan loader, never
    // dlopen a different driver or guess a library on the application's behalf.
    unsafe { dlsym((-2isize) as *mut c_void, c"vkGetInstanceProcAddr".as_ptr()) as usize }
}

/// Compatibility with native OpenVR clients which provide their own Vulkan loader before
/// negotiating OpenXR. This is only a proc-address pointer; no graphics objects are created.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn oxr_vulkan_set_loader(loader: *mut c_void) {
    EARLY_LOADER.store(loader as usize, Ordering::Release);
}

unsafe extern "C" {
    fn hxvk_create_instance(
        loader: *mut c_void,
        info: *const c_void,
        allocator: *const c_void,
        out: *mut *mut c_void,
    ) -> i32;
    fn hxvk_physical_device(loader: *mut c_void, instance: *mut c_void) -> *mut c_void;
    fn hxvk_create_device(
        loader: *mut c_void,
        instance: *mut c_void,
        physical: *mut c_void,
        info: *const c_void,
        allocator: *const c_void,
        out: *mut *mut c_void,
    ) -> i32;
    fn hxvk_device_queues(info: *const c_void, triples: *mut u32, capacity: u32) -> u32;
    fn hxvk_context(
        loader: *mut c_void,
        instance: *mut c_void,
        physical: *mut c_void,
        device: *mut c_void,
        family: u32,
        index: u32,
    ) -> *mut c_void;
    pub(crate) fn hxvk_destroy_context(context: *mut c_void);
    pub(crate) fn hxvk_image(
        context: *mut c_void,
        format: u64,
        width: u32,
        height: u32,
        layers: u32,
        usage: u64,
    ) -> *mut c_void;
    pub(crate) fn hxvk_prepare_image(image: *mut c_void) -> i32;
    pub(crate) fn hxvk_image_handle(image: *mut c_void) -> u64;
    pub(crate) fn hxvk_destroy_image(image: *mut c_void);
    pub(crate) fn hxvk_read_batch(
        context: *mut c_void,
        reads: *const ReadbackRequest,
        count: u32,
    ) -> i32;
}

pub(crate) fn register(instance: u64, enabled: bool, legacy_enabled: bool, metal_enabled: bool) {
    INSTANCES.lock().unwrap().insert(
        instance,
        Instance {
            enabled,
            legacy_enabled,
            metal_enabled,
            ..Default::default()
        },
    );
}
pub(crate) fn unregister(instance: u64) {
    INSTANCES.lock().unwrap().remove(&instance);
}

pub(crate) fn metal_requirements(
    instance: xr::Instance,
    system: xr::SystemId,
    mark: bool,
) -> xr::Result {
    if !super::is_live(instance) {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    if system.into_raw() != super::SYSTEM_ID {
        return xr::Result::ERROR_SYSTEM_INVALID;
    }
    let Ok(mut states) = INSTANCES.lock() else {
        return xr::Result::ERROR_RUNTIME_FAILURE;
    };
    let Some(state) = states.get_mut(&instance.into_raw()) else {
        return xr::Result::ERROR_HANDLE_INVALID;
    };
    if !state.metal_enabled {
        return xr::Result::ERROR_FUNCTION_UNSUPPORTED;
    }
    if mark {
        state.metal_requirements = true;
    }
    if state.metal_requirements {
        xr::Result::SUCCESS
    } else {
        xr::Result::ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING
    }
}

fn with<T>(
    instance: xr::Instance,
    system: xr::SystemId,
    f: impl FnOnce(&mut Instance) -> Result<T, xr::Result>,
) -> Result<T, xr::Result> {
    if !super::is_live(instance) {
        return Err(xr::Result::ERROR_HANDLE_INVALID);
    }
    if system.into_raw() != super::SYSTEM_ID {
        return Err(xr::Result::ERROR_SYSTEM_INVALID);
    }
    let mut states = INSTANCES
        .lock()
        .map_err(|_| xr::Result::ERROR_RUNTIME_FAILURE)?;
    let state = states
        .get_mut(&instance.into_raw())
        .ok_or(xr::Result::ERROR_HANDLE_INVALID)?;
    if !state.enabled && !state.legacy_enabled {
        return Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED);
    }
    f(state)
}

macro_rules! fp {
    ($f:expr,$t:ty) => {{
        let f: $t = $f;
        Some(unsafe { std::mem::transmute::<$t, pfn::VoidFunction>(f) })
    }};
}
pub(crate) fn lookup(name: &[u8]) -> Option<pfn::VoidFunction> {
    match name {
        b"xrGetVulkanGraphicsRequirementsKHR" => {
            fp!(legacy_requirements, pfn::GetVulkanGraphicsRequirementsKHR)
        }
        b"xrGetVulkanGraphicsDeviceKHR" => {
            fp!(legacy_physical_device, pfn::GetVulkanGraphicsDeviceKHR)
        }
        b"xrGetVulkanInstanceExtensionsKHR" => fp!(
            legacy_instance_extensions,
            pfn::GetVulkanInstanceExtensionsKHR
        ),
        b"xrGetVulkanDeviceExtensionsKHR" => {
            fp!(legacy_device_extensions, pfn::GetVulkanDeviceExtensionsKHR)
        }
        b"xrGetVulkanGraphicsRequirements2KHR" => {
            fp!(requirements, pfn::GetVulkanGraphicsRequirements2KHR)
        }
        b"xrCreateVulkanInstanceKHR" => fp!(create_instance, pfn::CreateVulkanInstanceKHR),
        b"xrGetVulkanGraphicsDevice2KHR" => fp!(physical_device, pfn::GetVulkanGraphicsDevice2KHR),
        b"xrCreateVulkanDeviceKHR" => fp!(create_device, pfn::CreateVulkanDeviceKHR),
        _ => None,
    }
}

/// Legacy Vulkan1 clients supply their loader through the native host's early
/// compatibility hook, create their own VkInstance/VkDevice and query these APIs.
unsafe extern "system" fn legacy_requirements(
    instance: xr::Instance,
    system: xr::SystemId,
    out: *mut xr::GraphicsRequirementsVulkanKHR,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if out.ty != xr::GraphicsRequirementsVulkanKHR::TYPE {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(instance, system, |s| {
        if !s.legacy_enabled {
            return Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED);
        }
        out.min_api_version_supported = xr::Version::new(1, 0, 0);
        out.max_api_version_supported = xr::Version::new(1, 1, 0);
        s.legacy_requirements = true;
        Ok(())
    })
    .map_or_else(|e| e, |_| xr::Result::SUCCESS)
}
unsafe extern "system" fn legacy_physical_device(
    instance: xr::Instance,
    system: xr::SystemId,
    vk: xr::platform::VkInstance,
    out: *mut xr::platform::VkPhysicalDevice,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = std::ptr::null();
    if vk.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(instance, system, |s| {
        if !s.legacy_enabled {
            return Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED);
        }
        let loader = application_loader();
        if loader == 0 {
            return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
        }
        let physical = unsafe { hxvk_physical_device(loader as *mut _, vk.cast_mut()) };
        if physical.is_null() {
            return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
        }
        s.loader = loader;
        s.vk_instance = vk as usize;
        s.physical = physical as usize;
        *out = physical;
        Ok(())
    })
    .map_or_else(|e| e, |_| xr::Result::SUCCESS)
}
unsafe fn legacy_extensions(
    instance: xr::Instance,
    system: xr::SystemId,
    capacity: u32,
    count: *mut u32,
    out: *mut std::ffi::c_char,
    text: &[u8],
) -> xr::Result {
    if let Err(e) = with(instance, system, |s| {
        if s.legacy_enabled {
            Ok(())
        } else {
            Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED)
        }
    }) {
        return e;
    }
    let bytes = text
        .iter()
        .map(|v| *v as std::ffi::c_char)
        .collect::<Vec<_>>();
    unsafe { crate::two_call(&bytes, capacity, count, out) }
}
unsafe extern "system" fn legacy_instance_extensions(
    instance: xr::Instance,
    system: xr::SystemId,
    capacity: u32,
    count: *mut u32,
    out: *mut std::ffi::c_char,
) -> xr::Result {
    unsafe {
        legacy_extensions(
            instance,
            system,
            capacity,
            count,
            out,
            b"VK_KHR_get_physical_device_properties2\0",
        )
    }
}
unsafe extern "system" fn legacy_device_extensions(
    instance: xr::Instance,
    system: xr::SystemId,
    capacity: u32,
    count: *mut u32,
    out: *mut std::ffi::c_char,
) -> xr::Result {
    unsafe {
        legacy_extensions(
            instance,
            system,
            capacity,
            count,
            out,
            b"VK_KHR_portability_subset\0",
        )
    }
}

unsafe extern "system" fn requirements(
    instance: xr::Instance,
    system: xr::SystemId,
    out: *mut xr::GraphicsRequirementsVulkan2KHR,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if out.ty != xr::GraphicsRequirementsVulkan2KHR::TYPE {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(instance, system, |s| {
        if !s.enabled {
            return Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED);
        }
        // Vulkan API versions are expressed as XrVersion here, not packed Vk API integers.
        out.min_api_version_supported = xr::Version::new(1, 0, 0);
        // Highest API version exercised by the real Metal/MoltenVK fixtures. The extension
        // permits newer compatible versions; this value is a tested-version claim, not a cap.
        out.max_api_version_supported = xr::Version::new(1, 1, 0);
        s.requirements = true;
        Ok(())
    })
    .map_or_else(|e| e, |_| xr::Result::SUCCESS)
}

unsafe extern "system" fn create_instance(
    instance: xr::Instance,
    info: *const xr::VulkanInstanceCreateInfoKHR,
    out: *mut xr::platform::VkInstance,
    result: *mut i32,
) -> xr::Result {
    let (Some(info), Some(out), Some(result)) =
        (unsafe { info.as_ref() }, unsafe { out.as_mut() }, unsafe {
            result.as_mut()
        })
    else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = std::ptr::null();
    *result = -3;
    if info.ty != xr::VulkanInstanceCreateInfoKHR::TYPE
        || info.vulkan_create_info.is_null()
        || !info.create_flags.is_empty()
    {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(instance, info.system_id, |s| {
        if !s.enabled {
            return Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED);
        }
        let loader = info
            .pfn_get_instance_proc_addr
            .map(|p| p as usize)
            .unwrap_or_else(application_loader);
        if loader == 0 {
            return Err(xr::Result::ERROR_VALIDATION_FAILURE);
        }
        let mut value = std::ptr::null_mut();
        *result = unsafe {
            hxvk_create_instance(
                loader as *mut _,
                info.vulkan_create_info,
                info.vulkan_allocator,
                &mut value,
            )
        };
        if *result == 0 {
            s.loader = loader;
            s.vk_instance = value as usize;
            s.physical = 0;
            s.device = 0;
            s.queues.clear();
            *out = value;
        }
        Ok(())
    })
    .map_or_else(|e| e, |_| xr::Result::SUCCESS)
}

unsafe extern "system" fn physical_device(
    instance: xr::Instance,
    info: *const xr::VulkanGraphicsDeviceGetInfoKHR,
    out: *mut xr::platform::VkPhysicalDevice,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = std::ptr::null();
    if info.ty != xr::VulkanGraphicsDeviceGetInfoKHR::TYPE || info.vulkan_instance.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(instance, info.system_id, |s| {
        if !s.enabled {
            return Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED);
        }
        if s.vk_instance != info.vulkan_instance as usize || s.loader == 0 {
            return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
        }
        let value = unsafe { hxvk_physical_device(s.loader as *mut _, s.vk_instance as *mut _) };
        if value.is_null() {
            return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
        }
        s.physical = value as usize;
        *out = value;
        Ok(())
    })
    .map_or_else(|e| e, |_| xr::Result::SUCCESS)
}

unsafe extern "system" fn create_device(
    instance: xr::Instance,
    info: *const xr::VulkanDeviceCreateInfoKHR,
    out: *mut xr::platform::VkDevice,
    result: *mut i32,
) -> xr::Result {
    let (Some(info), Some(out), Some(result)) =
        (unsafe { info.as_ref() }, unsafe { out.as_mut() }, unsafe {
            result.as_mut()
        })
    else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = std::ptr::null();
    *result = -3;
    if info.ty != xr::VulkanDeviceCreateInfoKHR::TYPE
        || info.vulkan_create_info.is_null()
        || !info.create_flags.is_empty()
    {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(instance, info.system_id, |s| {
        if !s.enabled {
            return Err(xr::Result::ERROR_FUNCTION_UNSUPPORTED);
        }
        let loader = info
            .pfn_get_instance_proc_addr
            .map(|p| p as usize)
            .unwrap_or(s.loader);
        if s.physical == 0 || s.physical != info.vulkan_physical_device as usize {
            return Err(xr::Result::ERROR_HANDLE_INVALID);
        }
        if loader == 0 || loader != s.loader {
            return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
        }
        let mut value = std::ptr::null_mut();
        *result = unsafe {
            hxvk_create_device(
                loader as *mut _,
                s.vk_instance as *mut _,
                s.physical as *mut _,
                info.vulkan_create_info,
                info.vulkan_allocator,
                &mut value,
            )
        };
        if *result == 0 {
            s.device = value as usize;
            let count =
                unsafe { hxvk_device_queues(info.vulkan_create_info, std::ptr::null_mut(), 0) };
            s.queues = vec![[0; 3]; count as usize];
            unsafe {
                hxvk_device_queues(info.vulkan_create_info, s.queues.as_mut_ptr().cast(), count);
            }
            *out = value;
        }
        Ok(())
    })
    .map_or_else(|e| e, |_| xr::Result::SUCCESS)
}

pub(crate) unsafe fn context(
    instance: xr::Instance,
    system: xr::SystemId,
    b: &xr::GraphicsBindingVulkanKHR,
) -> Result<*mut c_void, xr::Result> {
    with(instance, system, |s| {
        if s.legacy_enabled && s.legacy_requirements && s.device == 0 {
            // Vulkan1 clients create their device themselves. The contract requires
            // the supplied queue to have been created; no create-info is exposed to
            // this extension. Retain Vulkan2's stricter recorded-queue check below.
            if s.loader == 0
                || s.vk_instance != b.instance as usize
                || s.physical != b.physical_device as usize
                || b.device.is_null()
            {
                return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
            }
        } else {
            if !s.requirements {
                return Err(xr::Result::ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING);
            }
            if s.loader == 0
                || s.device == 0
                || s.device != b.device as usize
                || s.physical != b.physical_device as usize
                || s.vk_instance != b.instance as usize
            {
                return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
            }
            if !created_queue(&s.queues, b.queue_family_index, b.queue_index) {
                return Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID);
            }
        }
        let c = unsafe {
            hxvk_context(
                s.loader as *mut _,
                b.instance.cast_mut(),
                b.physical_device.cast_mut(),
                b.device.cast_mut(),
                b.queue_family_index,
                b.queue_index,
            )
        };
        if c.is_null() {
            Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID)
        } else {
            Ok(c)
        }
    })
}

fn created_queue(queues: &[[u32; 3]], family: u32, index: u32) -> bool {
    queues
        .iter()
        .any(|q| q[0] == family && q[2] == 0 && index < q[1])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_requested_unprotected_logical_queues_can_be_bound() {
        let queues = [[2, 1, 0], [3, 2, 0], [4, 1, 1]];
        assert!(created_queue(&queues, 2, 0));
        assert!(!created_queue(&queues, 2, 1));
        assert!(created_queue(&queues, 3, 1));
        assert!(!created_queue(&queues, 3, 2));
        assert!(!created_queue(&queues, 4, 0));
        assert!(!created_queue(&queues, 0, 0));
    }

    #[test]
    fn extension_requirements_and_binding_are_checked_before_driver_access() {
        let _runtime = crate::TEST_RUNTIME_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        unsafe {
            let extension = c"XR_KHR_vulkan_enable2".as_ptr();
            let mut create: xr::InstanceCreateInfo = std::mem::zeroed();
            create.ty = xr::InstanceCreateInfo::TYPE;
            create.application_info.api_version = xr::Version::new(1, 0, 0);
            let mut disabled = xr::Instance::NULL;
            assert_eq!(
                crate::create_instance(&create, &mut disabled),
                xr::Result::SUCCESS
            );
            let system = xr::SystemId::from_raw(crate::SYSTEM_ID);
            let mut requirements_out: xr::GraphicsRequirementsVulkan2KHR = std::mem::zeroed();
            requirements_out.ty = xr::GraphicsRequirementsVulkan2KHR::TYPE;
            assert_eq!(
                requirements(disabled, system, &mut requirements_out),
                xr::Result::ERROR_FUNCTION_UNSUPPORTED
            );
            assert_eq!(
                metal_requirements(disabled, system, true),
                xr::Result::ERROR_FUNCTION_UNSUPPORTED
            );
            assert_eq!(crate::destroy_instance(disabled), xr::Result::SUCCESS);

            create.enabled_extension_count = 1;
            create.enabled_extension_names = &extension;
            let mut enabled = xr::Instance::NULL;
            assert_eq!(
                crate::create_instance(&create, &mut enabled),
                xr::Result::SUCCESS
            );
            let binding: xr::GraphicsBindingVulkanKHR = std::mem::zeroed();
            assert_eq!(
                context(enabled, system, &binding),
                Err(xr::Result::ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING)
            );
            assert_eq!(
                requirements(enabled, xr::SystemId::NULL, &mut requirements_out),
                xr::Result::ERROR_SYSTEM_INVALID
            );
            assert_eq!(
                requirements(enabled, system, &mut requirements_out),
                xr::Result::SUCCESS
            );
            assert_eq!(
                context(enabled, system, &binding),
                Err(xr::Result::ERROR_GRAPHICS_DEVICE_INVALID)
            );
            assert_eq!(
                requirements_out.min_api_version_supported,
                xr::Version::new(1, 0, 0)
            );
            assert_eq!(crate::destroy_instance(enabled), xr::Result::SUCCESS);
            assert_eq!(
                requirements(enabled, system, &mut requirements_out),
                xr::Result::ERROR_HANDLE_INVALID
            );
        }
    }
    #[test]
    fn legacy_vulkan_extension_queries_and_requirements_are_independent() {
        let _lock = crate::TEST_RUNTIME_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        unsafe {
            let extension = c"XR_KHR_vulkan_enable".as_ptr();
            let mut create: xr::InstanceCreateInfo = std::mem::zeroed();
            create.ty = xr::InstanceCreateInfo::TYPE;
            create.application_info.api_version = xr::Version::new(1, 0, 0);
            create.enabled_extension_count = 1;
            create.enabled_extension_names = &extension;
            let mut instance = xr::Instance::NULL;
            assert_eq!(
                crate::create_instance(&create, &mut instance),
                xr::Result::SUCCESS
            );
            let system = xr::SystemId::from_raw(crate::SYSTEM_ID);
            let mut output: xr::GraphicsRequirementsVulkanKHR = std::mem::zeroed();
            output.ty = xr::GraphicsRequirementsVulkanKHR::TYPE;
            assert_eq!(
                legacy_requirements(instance, system, &mut output),
                xr::Result::SUCCESS
            );
            assert_eq!(
                requirements(instance, system, &mut output),
                xr::Result::ERROR_FUNCTION_UNSUPPORTED
            );
            let mut count = 0;
            assert_eq!(
                legacy_instance_extensions(instance, system, 0, &mut count, std::ptr::null_mut()),
                xr::Result::SUCCESS
            );
            let mut buffer = vec![0i8; count as usize];
            assert_eq!(
                legacy_instance_extensions(
                    instance,
                    system,
                    count,
                    &mut count,
                    buffer.as_mut_ptr()
                ),
                xr::Result::SUCCESS
            );
            assert_eq!(
                std::ffi::CStr::from_ptr(buffer.as_ptr()).to_str().unwrap(),
                "VK_KHR_get_physical_device_properties2"
            );
            assert_eq!(
                legacy_device_extensions(instance, system, 0, &mut count, std::ptr::null_mut()),
                xr::Result::SUCCESS
            );
            buffer.resize(count as usize, 0);
            assert_eq!(
                legacy_device_extensions(instance, system, count, &mut count, buffer.as_mut_ptr()),
                xr::Result::SUCCESS
            );
            assert_eq!(
                std::ffi::CStr::from_ptr(buffer.as_ptr()).to_str().unwrap(),
                "VK_KHR_portability_subset"
            );
            let mut function = None;
            assert_eq!(
                crate::get_instance_proc_addr(
                    instance,
                    c"xrGetVulkanGraphicsDeviceKHR".as_ptr(),
                    &mut function
                ),
                xr::Result::SUCCESS
            );
            assert!(function.is_some());
            assert_eq!(crate::destroy_instance(instance), xr::Result::SUCCESS);
        }
    }
}
