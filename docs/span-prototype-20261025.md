# SPAN prototype — 2026-10-25

Independent Swift 6 package: `native/SPANCoreML`, executable `iive-span`; open its `Package.swift` in Xcode. No player UI/defaults/bundle changes. Uses official SPAN x2/48 `params_ema`, frozen Conv3XC branches, Core ML image input/output (`CVPixelBuffer`), serial bounded inference, SDR guards, selectable compute units and `MLComputePlan`. Core ML internal copies are not observable; this is not an end-to-end zero-copy claim.

Sources reviewed: [official architecture](https://github.com/hongyuanyu/SPAN/blob/c77a5917759f09e66fbc7124220c5afc5ee221e5/basicsr/archs/span_arch.py), official archive's x2 test log, Apache-2.0 license, [Apple image I/O](https://apple.github.io/coremltools/docs-guides/source/image-inputs.html), and installed SDK compute-plan headers. Source range/mean and in-place SiLU semantics are preserved. Weights load with `weights_only=True` and strict schema; source hash is pinned. Downloads only the 17MB checkpoint member, not the 1.2GB results archive.

Basic M5 observations (one 128×128 crop → 256×256, three repeated calls, **not 720p/1080p throughput**):

- FP32 CPU/GPU: plan assigns 65 operations to GPU; mean model-call 7.80ms, PSNR 47.29dB. FSRCNNX8 in that run: 0.61ms, 40.91dB.
- FP32 CPU/NE: plan assigns all 65 operations to CPU. Merely enabling NE does not establish NE use.
- FP16 CPU/NE: plan assigns 65 operations to NE and 2 unknown; mean 1.57ms, PSNR 47.20dB. FSRCNNX8 in that run: 0.90ms. Planned placement is not measured NE utilization or guaranteed exclusive execution.
- Only this bicubic-downsampled real-film crop was compared. SPAN processes RGB, FSRCNNX luma/NV12, so quality includes chroma-conversion differences. Setup, RGB/NV12 conversion and file I/O are excluded from model-call times. No perceptual/temporal quality or sustained real-time conclusion.

**Numerical blocker:** convolution fusion matches PyTorch exactly in the small test. A random full-range RGB pressure image exposes large FP16 differences (MAE 75.23/255); FP32 MAE is 0.044/255 but has an isolated ~250/255 outlier. Both fail the strict parity gate, despite low errors on the real crop. Export defaults refuse failed parity; `--allow-parity-risk` exists only for diagnostics and marks metadata/reports `unvalidated_numeric_risk`. Do not integrate these artifacts into playback. coremltools 9.0 also warns that PyTorch 2.12.1 exceeds its tested version range.

Run with the pinned conversion environment (requires uv and Python 3.13):

```sh
python3 scripts/prepare-span.py
bash scripts/setup-span-toolchain.sh
build/span-toolchain/bin/python scripts/export-span-coreml.py --width 128 --height 128 --precision fp32 --allow-parity-risk --output build/models/NEW-span.mlpackage
bash scripts/build-span.sh
build/span-toolchain/bin/python benchmarks/prepare_span_fixture.py INPUT.mov --time 60 --assume-bt709-sdr --output /tmp/NEW-span-fixture
native/SPANCoreML/.build/release/iive-span build/models/NEW-span.mlpackage /tmp/NEW-span-fixture/input.png /tmp/NEW-span-fixture/reference.png cpu-gpu 3 /tmp/NEW-span-results
```

Output directories must be new. `cpu-ne`, `all` and `cpu` are also available. Diagnostic PNGs are comparison artifacts only, never a playback transport. Source media is not modified. Current compiled models and conversion manifests are under `build/models/span-x2-128-experimental.*` (FP32) and `span-x2-128-fp16-diagnostic.*` (FP16). Earlier failed/intermediate artifacts are not validated exports.

Release build and tiny native inference runs passed. Reports: [GPU](../benchmarks/results/span-gpu-20261025/report.json), [FP32 CPU/NE](../benchmarks/results/span-ne-20261025/report.json), [FP16 CPU/NE](../benchmarks/results/span-fp16-ne-20261025/report.json). No GUI/full tests or app repack.

## Precision follow-up

Pinned PyTorch **2.7.0**, coremltools **9.0**, NumPy **2.2.6**, Pillow **11.2.1** in the workspace-only `build/span-toolchain`. Repeating FP32 reproduced the previous noise discrepancy, so changing toolchain alone did not fix it. Conversion now rejects untested versions, checks constant/ramp/noise plus an optional real image, records a `.validation.json` even when publication fails, and never substitutes a real-image pass for the pressure check.

Added `mixed-attention`: FP16 convolution/layout ops, FP32 nonlinearities and attention/residual arithmetic. At 128×128, constant, ramp and the real crop pass; noise still fails (MAE **75.39/255**, maximum **255/255**). This profile stays diagnostic; it did not establish a numerical fix or a performance benefit.

`benchmarks/diagnose_span.py` probes tensors before image quantization, with topology agreement checked against the original fused graph. On the same noise input, FP32 maximum error grows from **0.000023** at the stem to **0.109** at block 4 and **16.33** at block 6 (feature units); clipped RGB maximum error reaches **250.04/255**. This localizes amplification inside the network, rather than solely to RGB byte conversion. Extra probe outputs can change graph optimizations; these are diagnostics, not runtime profiling. The result does not imply all natural video exhibits the same failure.

```sh
build/span-toolchain/bin/python benchmarks/diagnose_span.py --precision fp32 --output /tmp/NEW-span-layers.json
# Optional real-image case: --case real_image --image PATH/128x128-RGB.png
# Export diagnostic profile: --precision mixed-attention --parity-image PATH/128x128-RGB.png --allow-parity-risk
```

Evidence: [layer report](../benchmarks/results/span-layer-supported-fp32-20261025.json), [mixed-precision validation](../benchmarks/results/span-mixed-validation-20261025.json). Small diagnostics and default refusal/no-model-publication check passed; model parity did not pass. No 720p/GUI/player tests were started.

Next: retain SPAN as a research branch and FSRCNNX as default. Prioritize a separate FSRCNNX Core ML/NE prototype to investigate moving SR work away from RIFE's GPU queue; measure transfer costs and actual device placement before integrating. Resume SPAN playback work only after addressing numeric robustness on difficult inputs.
