// SPDX-License-Identifier: GPL-3.0-or-later
#include <metal_stdlib>
using namespace metal;
// Build script prepends HDRMath.h, keeping the CPU test and GPU math identical.
struct HDRUniforms { float headroom; float phase; float referenceWhite; uint animate; float imageAspect; float displayAspect; float chromaOffsetX; uint hlg; };
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut hdrVertex(uint id [[vertex_id]]) {
    float2 p=float2((id << 1) & 2, id & 2);
    return {float4(p*2.0-1.0,0.0,1.0),p};
}
fragment half4 hdrPattern(VertexOut in [[stage_in]], constant HDRUniforms &u [[buffer(0)]]) {
    // Bottom half: 0 / 100 / 203 / 400 / 1000 / 4000 source-nit patches.
    const float levels[6]={0.0,100.0,203.0,400.0,1000.0,4000.0};
    uint patch=min(uint(in.uv.x*6.0),5u);
    float pq=in.uv.y < 0.5 ? hdr_nits_pq(levels[patch]) : clamp(in.uv.x,0.0,1.0);
    float value=hdr_edr(pq,u.referenceWhite,u.headroom);
    // Marker animates without changing test patch brightness.
    if(u.animate && in.uv.y>0.94 && abs(in.uv.x-u.phase)<0.006) value=1.0;
    return half4(half3(value),1.0h);
}

fragment half4 hdrVideo(VertexOut in [[stage_in]], constant HDRUniforms &u [[buffer(0)]],
                        texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]]) {
    float2 uv=float2(in.uv.x,1.0-in.uv.y);
    if(u.imageAspect>u.displayAspect) uv.y=(uv.y-0.5)*(u.imageAspect/u.displayAspect)+0.5;
    else uv.x=(uv.x-0.5)*(u.displayAspect/u.imageAspect)+0.5;
    if(any(uv<0.0) || any(uv>1.0)) return half4(0,0,0,1);
    constexpr sampler sampling(coord::normalized,address::clamp_to_edge,filter::linear);
    float y=yPlane.sample(sampling,uv).r;
    float2 cbcr=uvPlane.sample(sampling,uv+float2(u.chromaOffsetX,0)).rg;
    HDRRGB pq=hdr_p010_pq(y,cbcr.x,cbcr.y);
    HDRRGB linear=u.hlg ? hdr_hlg_to_srgb(pq,u.referenceWhite) : hdr_2020_to_srgb(pq,u.referenceWhite);
    // Stage 2 deliberately clips gamut/highlights. No final tone/gamut mapping is claimed.
    return half4(half3(clamp(float3(linear.r,linear.g,linear.b),0.0,u.headroom)),1.0h);
}
