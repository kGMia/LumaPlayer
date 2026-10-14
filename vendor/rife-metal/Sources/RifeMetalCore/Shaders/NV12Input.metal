#include <metal_stdlib>
using namespace metal;

// Fused 420v BT.709 -> packed FP16 NHWC RGB. Centered chroma, video range.
// Replicate source edges for the padded inference grid; no CPU padding surface.
kernel void rifeNV12ToRGB(texture2d<float, access::sample> yPlane [[texture(0)]],
                          texture2d<float, access::sample> uvPlane [[texture(1)]],
                          device half *out [[buffer(0)]],
                          constant float &inverseScale [[buffer(1)]],
                          constant uint2 &size [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (any(gid >= size)) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 pos = clamp((float2(gid) + 0.5f) * inverseScale,
                       float2(0.5f), float2(yPlane.get_width(), yPlane.get_height()) - 0.5f);
    float y = (yPlane.sample(s, pos).r * 255.0f - 16.0f) / 219.0f;
    float2 uv = (uvPlane.sample(s, pos * 0.5f).rg * 255.0f - 128.0f) / 224.0f;
    float3 rgb = clamp(float3(y + 1.5748f * uv.y,
                             y - 0.187324f * uv.x - 0.468124f * uv.y,
                             y + 1.8556f * uv.x), 0.0f, 1.0f);
    uint i = (gid.y * size.x + gid.x) * 3;
    out[i] = half(rgb.r); out[i+1] = half(rgb.g); out[i+2] = half(rgb.b);
}
