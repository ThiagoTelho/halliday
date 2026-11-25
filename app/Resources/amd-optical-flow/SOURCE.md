# AMD Optical Flow on Metal

Original **AMD Optical Flow 1.1.2**, from **FidelityFX SDK v1.1.4**, MIT license:
https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/tree/c6efa6bf7f2027b3ec94f28578bb5965eabb9e55/sdk/include/FidelityFX/gpu/opticalflow

The seven original HLSL programs are compiled with shaderc/glslang to SPIR-V,
then SPIRV-Cross to Metal 3.2. They retain AMD's luma, six-level pyramid,
histogram/divergence scene-change detection, hierarchical block search, filtering
and vector refinement math. No Apple optical-flow implementation is substituted.
`LICENSE-AMD.txt` preserves AMD's notice. `PROVENANCE.json` records the exact
revision and source/output hashes. Reproduce with `tools/port-amd-optical-flow.py`.

Halliday's original `adapter.metal` separates and optionally downsamples each eye,
clears scratch resources and exports the result. `GameOpticalFlow.swift` schedules
the passes directly on one Metal command buffer, without CPU waits/readback.
The default analysis size is half the source width/height per eye. Luma and
integer-vector scratch textures use 32-bit components; values retain AMD's
integer/8-bit-luma semantics. Full-resolution output synthesis is separate.

The API accepts an explicit previous/current image pair. It primes AMD's previous
histogram from that exact previous image, resets the provisional cut-history bits,
then evaluates current-frame divergence. `frameIndex=6` skips the SDK's six-frame
startup guard because both caller-supplied images are already valid. Coarse-to-fine
flow seeds are local to this pair; no stale temporal vector prediction is reused.

Output: one vector per 8×8 analysis block, indexed in the **current** image. AMD's
current→previous lookup vectors are negated to expose previous→current displacement
in analysis pixels (+X right, +Y down). `vectorScaleToSource` converts to source
pixels. Two independent eye banks prevent stereo leakage. Per-eye scene-change
flags come from AMD's SCD history; the caller must suppress synthesis on a cut.

This is **not AMD FSR Frame Generation** and requires no game depth/motion-vector
buffers. No GPL FrameGen/OFXR composition or scheduling code is incorporated.
GPU validation tests cover signs/units, stereo isolation, moving objects and cuts;
synthetic timing does not establish game performance or physical VR quality.
