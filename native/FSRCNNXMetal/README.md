# Native FSRCNNX 8/16

Real trained igv FSRCNNX models, exported by `scripts/export-fsrcnnx.py`. Seven merged FP16 MPSGraph stages preserve edge clamping, PReLU, residuals and x-major subpixel order. Metal reads and writes IOSurface NV12; fixed 2× luma SR with bilinear chroma scaling. Output and input pools are bounded. Single serial caller per instance.

`libIIVEFSR.dylib` exports the C ABI in `include/IIVEFSR.h`. The native mpv filter `iive-fsrcnnx` connects it to the player. Source remains editable in Xcode; this Swift package owns compilation and resources, rather than compiling the same file inside the app target.

Run `scripts/test-fsrcnnx-native.sh` for the small GPU/reference check. Current scope is BT.709/BT.1886 SDR, not HDR or guaranteed real-time performance. See `docs/native-models-20261014.md` at the repository root for integration details and actual results.

Derived trained parameters: Copyright (C) 2017–2021 igv, LGPL-3.0-or-later. Integration: GPL-3.0-or-later. Original sources/license texts: `plugin/shaders`, `plugin/licenses`. Metal build plugin: RifeMetal, Apache-2.0, `vendor/rife-metal/LICENSE`.
