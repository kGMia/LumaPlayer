// SPDX-License-Identifier: GPL-3.0-or-later
// Shared C/Metal scalar transfer math. PQ values are full-range, not YUV code values.
#pragma once
#ifdef __METAL_VERSION__
#include <metal_stdlib>
using namespace metal;
#define HDR_POW pow
#define HDR_EXP exp
#define HDR_MIN fmin
#define HDR_MAX fmax
#else
#include <math.h>
#define HDR_POW powf
#define HDR_EXP expf
#define HDR_MIN fminf
#define HDR_MAX fmaxf
#endif
static inline float hdr_pq_nits(float code) {
    const float m1=2610.0f/16384.0f, m2=2523.0f/32.0f;
    const float c1=3424.0f/4096.0f, c2=2413.0f/128.0f, c3=2392.0f/128.0f;
    code=HDR_MIN(1.0f,HDR_MAX(0.0f,code));
    float p=HDR_POW(code,1.0f/m2);
    return 10000.0f*HDR_POW(HDR_MAX(p-c1,0.0f)/(c2-c3*p),1.0f/m1);
}
static inline float hdr_nits_pq(float nits) {
    float y=HDR_POW(HDR_MIN(10000.0f,HDR_MAX(0.0f,nits))/10000.0f,2610.0f/16384.0f);
    return HDR_POW((3424.0f/4096.0f+(2413.0f/128.0f)*y)/(1.0f+(2392.0f/128.0f)*y),2523.0f/32.0f);
}
// Reference-white-relative output; NOT a claim of calibrated physical screen nits.
// Clip deliberately (no hidden tone curve), to isolate transfer/synchronization tests.
static inline float hdr_edr(float code, float referenceWhite, float headroom) {
    return HDR_MIN(hdr_pq_nits(code)/HDR_MAX(referenceWhite,1.0f),HDR_MAX(headroom,1.0f));
}

typedef struct { float r,g,b; } HDRRGB;
// R16Unorm sampling returns stored 16-bit values / 65535. P010 uses the high ten bits.
static inline HDRRGB hdr_p010_pq(float ySample,float cbSample,float crSample) {
    float y=(ySample*(65535.0f/64.0f)-64.0f)/876.0f;
    float cb=(cbSample*(65535.0f/64.0f)-512.0f)/896.0f;
    float cr=(crSample*(65535.0f/64.0f)-512.0f)/896.0f;
    // BT.2020 non-constant-luminance Y'CbCr -> PQ R'G'B'.
    HDRRGB rgb={y+1.4746f*cr,y-0.1645531268f*cb-0.5713531268f*cr,y+1.8814f*cb};
    return rgb;
}
static inline HDRRGB hdr_linear2020_to_srgb(float r,float g,float b) {
    HDRRGB rgb={1.660491f*r-0.587641f*g-0.072850f*b,
               -0.124550f*r+1.132900f*g-0.008349f*b,
               -0.018151f*r-0.100579f*g+1.118730f*b};
    return rgb;
}

static inline HDRRGB hdr_2020_to_srgb(HDRRGB pq,float referenceWhite) {
    return hdr_linear2020_to_srgb(hdr_pq_nits(pq.r)/referenceWhite,hdr_pq_nits(pq.g)/referenceWhite,hdr_pq_nits(pq.b)/referenceWhite);
}
static inline float hdr_hlg_scene(float code) {
    code=HDR_MIN(1.0f,HDR_MAX(0.0f,code));
    return code<=0.5f ? code*code/3.0f : (HDR_EXP((code-0.55991073f)/0.17883277f)+0.28466892f)/12.0f;
}
// BT.2100 reference HLG OOTF: virtual 1000-nit display, gamma 1.2, zero black.
// This reference assumption is not a measurement of the attached screen.
static inline HDRRGB hdr_hlg_to_srgb(HDRRGB code,float referenceWhite) {
    float r=hdr_hlg_scene(code.r),g=hdr_hlg_scene(code.g),b=hdr_hlg_scene(code.b);
    float luminance=0.2627f*r+0.6780f*g+0.0593f*b;
    float scale=(1000.0f/HDR_MAX(referenceWhite,1.0f))*HDR_POW(luminance,0.2f);
    return hdr_linear2020_to_srgb(r*scale,g*scale,b*scale);
}
#undef HDR_POW
#undef HDR_EXP
#undef HDR_MIN
#undef HDR_MAX
