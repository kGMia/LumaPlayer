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
// Subpixel order matches export-fsrcnnx.py: channel = dx * 2 + dy.
// chromaParams: .x = horizontal UV texel shift (+0.25 for Left->Center), .y = input scale (1.0 for 8-bit, 257/256 for P010),
// .z = splitRatio in [0, 1] (0 = full SR; >0 = bilinear source on left of splitRatio, unchanged SR 2x on right).
kernel void fsrWriteNV12(device const half *subpixel [[buffer(0)]],
                         texture2d<half,access::sample> sourceUV [[texture(0)]],
                         texture2d<half,access::write> y [[texture(1)]] ,
                         texture2d<half,access::write> uv [[texture(2)]],
                         texture2d<half,access::sample> sourceY [[texture(3)]],
                         constant float4 &chromaParams [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=y.get_width() || gid.y>=y.get_height()) return;
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    uint w=y.get_width()/2;
    uint i=((gid.y/2)*w+gid.x/2)*4+(gid.x%2)*2+gid.y%2;
    float2 lumaPos = (float2(gid)+0.5f)/float2(y.get_width(),y.get_height());
    float srY = clamp(float(subpixel[i]), 0.0f, 1.0f);
    float splitRatio = chromaParams.z;
    // Comparison must preserve the normal model output on the SR side.
    // The source side uses bilinear scaling to the same output dimensions.
    half lumaOut = half(srY);
    if(splitRatio > 0.0f && lumaPos.x < splitRatio) {
        lumaOut = half(clamp(float(sourceY.sample(s,lumaPos).r) * chromaParams.y, 0.0f, 1.0f));
    }
    y.write(half4(lumaOut,0,0,1),gid);
    if((gid.x%2)==0 && (gid.y%2)==0) {
        float2 pos=(float2(gid/2)+0.5f)/float2(uv.get_width(),uv.get_height());
        pos.x += chromaParams.x / float(sourceUV.get_width());
        float2 chroma = clamp(float2(sourceUV.sample(s,pos).rg) * chromaParams.y, 0.0f, 1.0f);
        uv.write(half4(half2(chroma),0,1),gid/2);
    }
}
