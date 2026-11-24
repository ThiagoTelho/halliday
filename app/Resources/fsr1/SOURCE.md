# FidelityFX Super Resolution 1

EASU and RCAS are AMD FidelityFX Super Resolution 1 (v1.20210629),
https://github.com/GPUOpen-Effects/FidelityFX-FSR, MIT licensed.
The included Metal shaders were translated from AMD's implementation for the
local FSR integration, with per-eye bounds for side-by-side stereo images.
The original AMD notice is in `LICENSE-AMD-FSR1.txt`.

`prepare.metal` converts explicitly linear inputs to display-encoded RGB before
FSR. Untagged and already encoded inputs retain their bytes. Projection pose,
FOV, vertical orientation and lens correction are handled by Halliday after this
pass. Transparent/premultiplied projection layers must bypass these opaque
EASU/RCAS shaders.
