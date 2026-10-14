#include <metal_stdlib>
using namespace metal;

// Fused mask interpolation, blend, crop and BT.709 video-range NV12 packing.
// FullDim is the padded tensor grid, never the cropped output dimensions.
static float3 blendedRGB(uint2 p, device const half *a, device const half *b,
                         device const half *mask, uint2 fullDim, uint2 maskDim) {
    float2 uv=(float2(p)+0.5f)*float2(maskDim)/float2(fullDim)-0.5f;
    int2 base=int2(floor(uv)); float2 f=fract(uv);
    int2 hi=int2(maskDim)-1;
    int2 p00=clamp(base,int2(0),hi),p11=clamp(base+1,int2(0),hi);
    float m=mix(mix(float(mask[p00.y*maskDim.x+p00.x]),float(mask[p00.y*maskDim.x+p11.x]),f.x),
                mix(float(mask[p11.y*maskDim.x+p00.x]),float(mask[p11.y*maskDim.x+p11.x]),f.x),f.y);
    half factor=1.0h/(1.0h+exp(-half(m)));
    uint i=(p.y*fullDim.x+p.x)*3;
    half3 x=half3(a[i],a[i+1],a[i+2]),y=half3(b[i],b[i+1],b[i+2]);
    return clamp(float3(x*factor+y*(1.0h-factor)),0.0f,1.0f);
}
kernel void rifeBlendToNV12(device const half *a [[buffer(0)]], device const half *b [[buffer(1)]],
                            device const half *mask [[buffer(2)]],
                            constant uint2 &fullDim [[buffer(3)]],constant uint2 &maskDim [[buffer(4)]],
                            texture2d<float,access::write> yPlane [[texture(0)]],
                            texture2d<float,access::write> uvPlane [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=uvPlane.get_width() || gid.y>=uvPlane.get_height()) return;
    float3 average=0;
    for(uint y=0;y<2;y++)for(uint x=0;x<2;x++) {
        uint2 p=gid*2+uint2(x,y);
        float3 rgb=blendedRGB(p,a,b,mask,fullDim,maskDim);
        float luma=dot(rgb,float3(0.2126f,0.7152f,0.0722f));
        yPlane.write(float4((16.0f+219.0f*luma)/255.0f,0,0,1),p);
        average+=rgb*0.25f;
    }
    float luma=dot(average,float3(0.2126f,0.7152f,0.0722f));
    float2 chroma=float2((average.b-luma)/1.8556f,(average.r-luma)/1.5748f);
    uvPlane.write(float4((float2(128.0f)+224.0f*chroma)/255.0f,0,1),gid);
}
