# Optional per-image source timing (HLFT v1)

`ProjectionLayer.imageTime` remains the host import receipt time. It is not the
source image clock. HLFT provides an additional timestamp associated with the
same producer epoch and frame index as the pixels; no pose timestamp is substituted.

The v6 mapping size/layout stays unchanged. A versioned extension at byte 64704
uses 776 previously unused bytes, ending at 65480. HLVM ends at 64672. Its 19
40-byte seqlock records cover the three copied-image slots and the sixteen
captured-window records (index `3 + number % 16`). A 32-byte C snapshot contains
`epoch`, `frame_index`, signed `nanoseconds`, `clock_kind` and zero `reserved`.
The accompanying frame advertises valid optional metadata with bit 18.

Clock kinds deliberately distinguish semantics:

- `1`: the exact submitted OpenXR `xrEndFrame.displayTime`, an intended image
  presentation target in that runtime's time domain. It is not engine simulation
  time. Native and Windows producers retain it with their own image packet,
  including the older packet selected by deferred readback.
- `2`: OpenVR's producer-side first-eye `Submit` entry time in QPC-derived
  nanoseconds, captured before waiting for readback or window presentation.
  Both eyes, copied frames and captured-window records carry that same value.

Only differences between positive timestamps of the same kind and producer epoch
are meaningful. Do not subtract producer QPC/OpenXR values from Mach/host clocks.
Negotiated game cadence remains a scheduling budget, not proof that images from
a 43 FPS game are 16.67 ms apart. Successfully published indices can be contiguous
even when source images were skipped.

The C getters verify the exact leased copied slot, or stable captured-window
number/index, before and after reading the associated seqlock record. They return
`1` for valid timing, `0` for unadvertised legacy timing, and `-1` for invalid,
stale, busy or wrong-owner timing, always clearing the output first. Timing
failure suppresses use of that timing; it does not discard otherwise valid pixels.
Old clients remain unadvertised; a new producer on an old host does not pretend
the extension is available.

Legacy OpenVR now claims initialization with compare-exchange. A positive timing
lease is negotiated only when both HLFT and the existing ownership extension are
available; old hosts retain epoch zero and their historical OpenVR classification.
Read-only HMD-presence queries never claim a producer or start a heartbeat. Cleanup
validates the current owner/epoch and releases admission after CPU slot-copy workers finish. Jobs
retain their original mapped header and lease; late callbacks cannot redirect old
pixels into a newer producer mapping. A stalled copy keeps ownership until host
retirement rather than freeing a slot still being written. GPU cleanup operations
are not added to the shutdown callback.

CPU fixtures cover layout/absence, record wrap/clear, exact epoch/index/kind,
held pixel slots, delayed/bunched delivery, 43 Hz pair spacing, captured-ring
replacement, invalid timing retaining real pixels, admission conflicts/reinit,
old-host epoch zero, malformed capability rollback and side-effect-free presence.
Native/OpenVR cross-build success does not establish physical headset acceptance.
