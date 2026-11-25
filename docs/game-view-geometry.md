# Game FOV crop

The crop removes game rendering work **before the game renders**. It negotiates
a smaller image and an exactly corresponding smaller projection frustum. It
does not stretch, zoom or downscale an already-rendered full-FOV frame.

## Host integration

`GameBridge.init(..., crop: GameCropSettings = .init())` is the entry point.
Default is **off**. When enabled, initial retained tangent-span fractions are
horizontal **0.85**, vertical **0.90**. Example:

```swift
GameBridge(device: device, queue: queue, displayHz: hz, ipd: ipd,
    crop: .init(enabled: settings.gameCropEnabled,
                horizontal: 0.85, vertical: 0.90))
```

Wire every construction/reconstruction of the independent game bridge. Treat a
geometry preference change like a render-size change: require a game/session
restart. The bridge configuration is immutable for its generation, so an
existing game's swapchains are never silently relabelled with a new camera.
The host settings expose independent horizontal and vertical crop values.

## Geometry contract

- **Left eye:** remove columns from its left/temporal edge. Keep its right/nasal
  FOV boundary bit-identical.
- **Right eye:** remove columns from its right/temporal edge. Keep its left/nasal
  FOV boundary bit-identical.
- Remove equal rows from the upper and lower tangent-space boundaries.
- Round dimensions to 32-pixel alignment; derive the *effective* FOV from the
  actual integer image dimensions. A retained source pixel keeps exactly its
  original camera ray and tangent-space density. This is not uniform angular
  pixels-per-degree; the original projection itself has nonuniform angular PPD.
- At 100% rendering, **2016×2048 → 1728×1856 per eye**, 22.32% fewer rendered
  pixels after alignment. This is a pixel-budget reduction, **not a measured FPS
  or latency gain**. At other render scales, alignment gives slightly different
  effective fractions.
- The existing compositor samples each image through its negotiated FOV and
  outputs opaque black outside it. The physical lens FOV stays unchanged. It
  never stretches the retained rectangle over the removed field.
- Optional FSR uses a corresponding cropped output budget. RCAS and frame
  generation keep the image's FOV metadata.

The existing shared-memory ABI already contains the recommended per-eye size
and both eyes' tangents. Host negotiation therefore covers:

| Client | Existing consumer |
| --- | --- |
| Native OpenXR Metal/Vulkan | `eye_size`, session configuration, `xrLocateViews` |
| Windows OpenXR D3D11/D3D12/Vulkan | `controlConfiguredViewSize`, `controlViewConfig` |
| OpenVR | `GetRecommendedRenderTargetSize`, `GetProjectionRaw/Matrix` |

OpenVR's host fallback uses the negotiated crop FOV rather than the full optical
FOV. A game that overrides recommendations may keep its own render size/FOV;
receiving an image cannot by itself reduce that game's GPU rendering work.

## Offline validation

- `bash tools/test-game-view-geometry.sh`: 132,720 retained rays across both eyes,
  render scales, crop settings and head rotations; nasal preservation, source
  density, dimensions, invalid inputs and bit-identical disabled defaults.
- `bash tools/test-projection-desktop-metal.sh`: real `scene_fs`, both-eye crop
  under the full physical FOV; independent gradient oracle, opaque-black missing
  field, no stretching/eye swap; ordinary desktop geometry regression checks.
- `cargo test --manifest-path core/Cargo.toml -p halliday-openxr`: real host
  shared-memory configuration to native XR view-size/FOV and pose checks, plus
  the existing runtime suite. No headset or game is needed.

No installed application, game, permission, user setting or hardware calibration
is modified. No measured game performance claim is made by these checks.
