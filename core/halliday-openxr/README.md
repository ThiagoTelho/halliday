# Independent native OpenXR

MIT implementation for native macOS Metal and Vulkan clients using Halliday's public game bridge.

* `XR_KHR_metal_enable`: client Metal queue, runtime-owned color textures.
* `XR_KHR_vulkan_enable2`: public instance/device creation, physical-device selection,
  graphics-queue binding, runtime-owned Vulkan color images. The client supplies its Vulkan
  `vkGetInstanceProcAddr`; the runtime does not link or bundle a driver.
* `XR_KHR_vulkan_enable`: compatibility for native OpenComposite clients that create
  their own Vulkan objects. The existing host supplies its loader through
  `oxr_vulkan_set_loader`, or a generic client can expose `vkGetInstanceProcAddr`
  globally. The runtime never opens a different Vulkan driver. Legacy device queries
  select the physical device; session binding imports the application's device and
  queue. Vulkan2 retains stricter validation against the logical queues created
  through its public creation API.
* Vulkan and Metal share the existing public v6 Halliday game bridge (`HALLIDAY_BRIDGE`).
  One stereo projection plus up to eight ordered quad layers are supported;
  arrays of one/two slices and subimage rectangles
  are accepted. RGBA8/BGRA8 linear and sRGB formats retain explicit per-eye transfer metadata.
  Both subimages must have equal dimensions; one mip and one sample are supported. Queue
  bindings must name an unprotected queue actually requested when the logical device was
  created. The currently tested Vulkan version is 1.1.
* The current image transport is **GPU → CPU → bridge**, not zero copy: the runtime submits
  readback behind the client's work on the same queue and waits for actual completion before
  publishing both eyes with the original render pose. Vulkan fence waits are bounded at 2 s;
  failure publishes no frame. A pending failed GPU allocation is retained rather than freed
  while in flight. This does not promise device-loss recovery.
* Vulkan initial color layouts are established once in `xrAcquireSwapchainImage`;
  `xrWaitSwapchainImage` never accesses the queue. The client must return each image in
  `COLOR_ATTACHMENT_OPTIMAL` with the graphics queue owning it, as the extension specifies.
* `oxr_vulkan_set_loader(void*)` is an optional native-launcher compatibility entry point;
  standard OpenXR clients provide their loader through the extension structures.
* Event polling refreshes dashboard focus, quit and host loss independently of frame
  submission. Sessions own a registration and a 200 ms heartbeat worker; teardown
  joins that worker before releasing the client. Host quit is acknowledged only by
  its current owner. `xrEndSession` releases the registration even if a native guest
  continues in 2D; late destruction cannot release the next client's claim.
  Two seconds without host display progress detects an abruptly stopped host.
  STOPPING sessions cannot revive; tracking-confidence loss alone does not stop one.
* An explicit host recenter epoch produces LOCAL/STAGE reference-change events with
  unknown previous-space transforms, resets the local anchor on the next frame,
  and discards a frame started before that change. Ordinary head motion never
  resets an origin.
* Boolean/scalar/vector input is cached at `xrSyncActions`, with stable change times,
  multiple bindings and bound-source enumeration/names. Canonical grip/aim identities
  and application offsets are preserved; no guessed physical controller correction
  is introduced. Space velocities include the application offset's lever arm.
* Bound output actions send both-hand vibration through the optional v6 reserved
  haptic mailbox. Output does not require input synchronization. Focus loss and
  session teardown cancel output; session epochs prevent replay. Destroying a
  public action handle retains the session's existing action spaces, bindings,
  input priority and already-issued haptic request until its owning resources
  are released, matching the Windows implementation.

* One live instance is supported. A second returns `XR_ERROR_LIMIT_REACHED`
  instead of sharing global session/input state. Teardown retains an occupied
  marker until cleanup completes, preventing a concurrent new instance from
  losing its resources to the old cleanup. Native graphics entry points are
  exposed only for that instance's enabled extensions.
* Static-image swapchains allocate one image and allow a single lifetime
  acquisition; dynamic images enforce acquire/wait/release FIFO ordering.
  A second `xrWaitFrame` waits for `xrBeginFrame` without holding the runtime
  mutex or replacing the pending frame's timestamp. Normal session exit can
  unblock that wait.
* Native Metal and Vulkan read both eyes plus all quads in one bounded
  same-frame GPU batch. Whole-batch validation precedes copying. Allocation
  failure retains reusable storage; Vulkan timeouts do not reset in-flight
  command buffers. This remains GPU-to-CPU readback, not zero copy.

Build the relocatable arm64 + x86_64 candidate with
`tools/build-independent-native-openxr.sh`. Requires the local Rust toolchain, both macOS
Rust targets, Xcode, and public Vulkan headers at `$VULKAN_SDK/include` (or
`/opt/homebrew/include`). Output is a private build directory, never an installed runtime.
Rosetta execution additionally requires an actual x86_64 Vulkan driver; building an x86_64
slice alone is not a graphics test.

This code was written against the [Khronos public Vulkan2 extension specification](https://github.com/KhronosGroup/OpenXR-Docs/blob/main/specification/sources/chapters/extensions/khr/khr_vulkan_enable2.adoc)
and [public Vulkan specification](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html),
using `openxr-sys` API types. No closed runtime implementation is embedded or copied.
