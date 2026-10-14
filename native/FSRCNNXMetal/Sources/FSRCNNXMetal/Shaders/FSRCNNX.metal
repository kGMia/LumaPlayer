// SPDX-License-Identifier: GPL-3.0-or-later
#include <metal_stdlib>
using namespace metal;
kernel void fsrReadLuma(texture2d<half,access::read> y [[texture(0)]],
                        device half *out [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=y.get_width() || gid.y>=y.get_height()) return;
    out[gid.y*y.get_width()+gid.x]=y.read(gid).r;
}
// GLSL aggregation uses index.x * 2 + index.y. Preserve this order exactly.
kernel void fsrWriteNV12(device const half *subpixel [[buffer(0)]],
                         texture2d<half,access::sample> sourceUV [[texture(0)]],
                         texture2d<half,access::write> y [[texture(1)]],
                         texture2d<half,access::write> uv [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=y.get_width() || gid.y>=y.get_height()) return;
    uint w=y.get_width()/2;
    uint i=((gid.y/2)*w+gid.x/2)*4+(gid.x%2)*2+gid.y%2;
    y.write(half4(subpixel[i],0,0,1),gid);
    if((gid.x%2)==0 && (gid.y%2)==0) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float2 pos=(float2(gid/2)+0.5f)/float2(uv.get_width(),uv.get_height());
        uv.write(sourceUV.sample(s,pos),gid/2);
    }
}
