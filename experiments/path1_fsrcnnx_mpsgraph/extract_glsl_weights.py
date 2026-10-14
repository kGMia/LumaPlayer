#!/usr/bin/env python3
"""
Extract numerical convolution weights from FSRCNNX GLSL shaders into structured binary tensors.
Uses Python built-in struct module ('e' for IEEE 754 half-precision float).
"""
import re, os, json, struct

def extract_weights_from_shader(shader_path):
    with open(shader_path, "r", encoding="utf-8") as f:
        text = f.read()

    numbers = []
    # Pattern to match numbers like -0.1572492271661758, 1.1100435256958008, etc.
    for match in re.finditer(r"[-+]?\d*\.\d+(?:[eE][-+]?\d+)?", text):
        val = float(match.group(0))
        numbers.append(val)

    # Pack into binary half-precision floats (16-bit)
    packed = bytearray()
    for n in numbers:
        packed.extend(struct.pack('<e', n))
    return numbers, packed

def main():
    root = "/Users/august/Project/video enhancer"
    shader8 = os.path.join(root, "plugin/shaders/FSRCNNX_x2_8-0-4-1.glsl")
    shader16 = os.path.join(root, "plugin/shaders/FSRCNNX_x2_16-0-4-1.glsl")
    out_dir = os.path.join(root, "experiments/path1_fsrcnnx_mpsgraph")

    w8_list, w8_bytes = extract_weights_from_shader(shader8)
    w16_list, w16_bytes = extract_weights_from_shader(shader16)

    with open(os.path.join(out_dir, "fsrcnnx8_fp16.bin"), "wb") as f:
        f.write(w8_bytes)
    with open(os.path.join(out_dir, "fsrcnnx16_fp16.bin"), "wb") as f:
        f.write(w16_bytes)

    manifest = {
        "fsrcnnx8": {
            "file": "fsrcnnx8_fp16.bin",
            "weight_count": len(w8_list),
            "size_bytes": len(w8_bytes),
            "format": "float16",
            "layers": [
                {"name": "conv1_expand", "kernel": "5x5", "in_channels": 1, "out_channels": 32},
                {"name": "conv2_shrink", "kernel": "1x1", "in_channels": 32, "out_channels": 8},
                {"name": "conv3_mapping1", "kernel": "3x3", "in_channels": 8, "out_channels": 8},
                {"name": "conv4_mapping2", "kernel": "3x3", "in_channels": 8, "out_channels": 8},
                {"name": "conv5_mapping3", "kernel": "3x3", "in_channels": 8, "out_channels": 8},
                {"name": "conv6_mapping4", "kernel": "3x3", "in_channels": 8, "out_channels": 8},
                {"name": "conv7_expand", "kernel": "1x1", "in_channels": 8, "out_channels": 32},
                {"name": "deconv_upscale", "kernel": "9x9", "in_channels": 32, "out_channels": 1, "stride": 2}
            ]
        },
        "fsrcnnx16": {
            "file": "fsrcnnx16_fp16.bin",
            "weight_count": len(w16_list),
            "size_bytes": len(w16_bytes),
            "format": "float16",
            "layers": [
                {"name": "conv1_expand", "kernel": "5x5", "in_channels": 1, "out_channels": 64},
                {"name": "conv2_shrink", "kernel": "1x1", "in_channels": 64, "out_channels": 16},
                {"name": "conv3_mapping1", "kernel": "3x3", "in_channels": 16, "out_channels": 16},
                {"name": "conv4_mapping2", "kernel": "3x3", "in_channels": 16, "out_channels": 16},
                {"name": "conv5_mapping3", "kernel": "3x3", "in_channels": 16, "out_channels": 16},
                {"name": "conv6_mapping4", "kernel": "3x3", "in_channels": 16, "out_channels": 16},
                {"name": "conv7_expand", "kernel": "1x1", "in_channels": 16, "out_channels": 64},
                {"name": "deconv_upscale", "kernel": "9x9", "in_channels": 64, "out_channels": 1, "stride": 2}
            ]
        }
    }

    with open(os.path.join(out_dir, "weights_manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Extracted FSRCNNX 8: {len(w8_list)} FP16 values ({len(w8_bytes) / 1024:.1f} KB)")
    print(f"Extracted FSRCNNX 16: {len(w16_list)} FP16 values ({len(w16_bytes) / 1024:.1f} KB)")

if __name__ == "__main__":
    main()
