# Superseded experiment — do not apply this patch

The patch was never a working mpv integration: it used Objective-C syntax in C, did not retain source plane ownership, and a CVPixelBuffer wrapping software memory is not automatically Metal/IOSurface compatible. Its kernels also used an NCHW layout incompatible with the real NHWC stream tensors.

The real implementation now lives in `vendor/rife-metal/Sources/RifeMetalCore/StreamInput.swift`, `Shaders/NV12Input.metal` and `native/mpv-filter/vf_iive_rife.c`. It uses IOSurface pools and correct BT.709 video-range conversion. It is partial copy reduction, not end-to-end zero-copy. See `docs/agent-handoff-20261014.md`.
