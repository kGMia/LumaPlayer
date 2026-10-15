// SPDX-License-Identifier: GPL-3.0-or-later
#include <metal_stdlib>
using namespace metal;
kernel void fsrReadLuma(texture2d<half,access::read> y [[texture(0)]],
                        device half *out [[buffer(0)]],
                        constant float &lumaScale [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=y.get_width() || gid.y>=y.get_height()) return;
    float sampleY = clamp(float(y.read(gid).r) * lumaScale, 0.0f, 1.0f);
    out[gid.y*y.get_width()+gid.x]=half(sampleY);
}
// GLSL aggregation uses index.x * 2 + index.y. Preserve this order exactly.
// chromaParams: x = chromaOffset, y = inputScale, z = splitRatio (0 = full SR, >0 = original luma on left).
kernel void fsrWriteNV12(device const half *subpixel [[buffer(0)]],
                         texture2d<half,access::sample> sourceUV [[texture(0)]],
                         texture2d<half,access::write> y [[texture(1)]],
                         texture2d<half,access::write> uv [[texture(2)]],
                         texture2d<half,access::sample> sourceY [[texture(3)]],
                         constant float4 &chromaParams [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=y.get_width() || gid.y>=y.get_height()) return;
    uint w=y.get_width()/2;
    uint i=((gid.y/2)*w+gid.x/2)*4+(gid.x%2)*2+gid.y%2;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float splitRatio = chromaParams.z;
    if(splitRatio > 0.001f && float(gid.x) < float(y.get_width()) * splitRatio) {
        float2 lumaPos = (float2(gid) + 0.5f) / float2(y.get_width(), y.get_height());
        float origY = clamp(float(sourceY.sample(s, lumaPos).r) * chromaParams.y, 0.0f, 1.0f);
        y.write(half4(half(origY),0,0,1),gid);
    } else {
        y.write(half4(subpixel[i],0,0,1),gid);
    }
    if((gid.x%2)==0 && (gid.y%2)==0) {
        float2 pos=(float2(gid/2)+0.5f)/float2(uv.get_width(),uv.get_height());
        // Fuse left -> center siting and optional P010 MSB-unorm scaling into the final chroma upscale.
        pos.x += chromaParams.x / float(sourceUV.get_width());
        float2 chroma = clamp(float2(sourceUV.sample(s,pos).rg) * chromaParams.y, 0.0f, 1.0f);
        uv.write(half4(half2(chroma),0,1),gid/2);
    }
}
