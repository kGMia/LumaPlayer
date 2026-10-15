// SPDX-License-Identifier: GPL-3.0-or-later
#include <metal_stdlib>
using namespace metal;

// Input/output use the same BT.709 matrix and transfer. Only bit depth (8-bit NV12
// or MSB-aligned 10-bit P010), range, and chroma siting change. A left chroma sample
// is half a luma pixel left of a centered sample: centered output therefore samples
// source UV one quarter texel right.
kernel void normalizeNV12(texture2d<float, access::read> y [[texture(0)]],
                          texture2d<float, access::sample> uv [[texture(1)]],
                          texture2d<float, access::write> outY [[texture(2)]],
                          texture2d<float, access::write> outUV [[texture(3)]],
                          constant uint3 &options [[buffer(0)]],
                          uint2 p [[thread_position_in_grid]]) {
    if (p.x >= outY.get_width() || p.y >= outY.get_height()) return;
    bool fullRange = options.x != 0;
    bool leftChroma = options.y != 0;
    bool tenBit = options.z != 0;

    float luma = y.read(p).r;
    if (tenBit) {
        if (fullRange) {
            float code10 = luma * (65535.0f / 64.0f);
            luma = (16.0f + (code10 / 1023.0f) * 219.0f) / 255.0f;
        } else {
            // 10-bit video range [64..940] << 6 in R16Unorm maps to [16..235]/255 via 257/256.
            luma = luma * (257.0f / 256.0f);
        }
    } else if (fullRange) {
        luma = (16.0f + luma * 219.0f) / 255.0f;
    }
    outY.write(float4(clamp(luma, 0.0f, 1.0f), 0, 0, 1), p);

    if (p.x < outUV.get_width() && p.y < outUV.get_height()) {
        constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 offset = float2(leftChroma ? 0.25f : 0.0f, 0);
        float2 at = (float2(p) + 0.5f + offset) / float2(uv.get_width(), uv.get_height());
        float2 chroma = uv.sample(linearClamp, at).rg;
        if (tenBit) {
            if (fullRange) {
                float2 code10 = chroma * (65535.0f / 64.0f);
                chroma = (128.0f + (code10 - 512.0f) * (224.0f / 1023.0f)) / 255.0f;
            } else {
                chroma = chroma * (257.0f / 256.0f);
            }
        } else if (fullRange) {
            chroma = (128.0f + (chroma * 255.0f - 128.0f) * (224.0f / 255.0f)) / 255.0f;
        }
        outUV.write(float4(clamp(chroma, 0.0f, 1.0f), 0, 1), p);
    }
}
