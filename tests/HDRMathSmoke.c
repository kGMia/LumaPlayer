// SPDX-License-Identifier: GPL-3.0-or-later
#include "../native/HDRPrototype/HDRMath.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(fabsf(hdr_pq_nits(0))<0.00001f);
    assert(fabsf(hdr_pq_nits(1)-10000)<1);
    // Independent ST2084 reference code values, not just round-trip checks.
    assert(fabsf(hdr_pq_nits(0.5080784f)-100)<0.05f);
    assert(fabsf(hdr_pq_nits(0.7518271f)-1000)<0.5f);
    float levels[]={0,0.1f,1,100,203,400,1000,4000,10000};
    for(unsigned i=0;i<sizeof(levels)/sizeof(*levels);i++)
        assert(fabsf(hdr_pq_nits(hdr_nits_pq(levels[i]))-levels[i])<fmaxf(0.001f,levels[i]*0.001f));
    assert(fabsf(hdr_edr(0.5080784f,100,4)-1)<0.001f);
    assert(hdr_edr(0.7518271f,100,4)==4);
    assert(hdr_edr(1,100,1)==1);
    float previous=0;
    for(int i=0;i<=1023;i++) {
        float value=hdr_edr(i/1023.0f,100,4);
        assert(isfinite(value) && value>=previous && value<=4);
        previous=value;
    }
    const float neutral=(512.0f*64.0f)/65535.0f;
    HDRRGB black=hdr_p010_pq((64.0f*64)/65535,neutral,neutral);
    HDRRGB white=hdr_p010_pq((940.0f*64)/65535,neutral,neutral);
    assert(fabsf(black.r)<0.00001 && fabsf(black.g)<0.00001 && fabsf(black.b)<0.00001);
    assert(fabsf(white.r-1)<0.00001 && fabsf(white.g-1)<0.00001 && fabsf(white.b-1)<0.00001);
    // PQ-domain pure red encoded independently using Kr/Kb BT.2020 coefficients.
    float y=0.2627f,cb=-y/1.8814f,cr=(1-y)/1.4746f;
    HDRRGB red=hdr_p010_pq((64+876*y)*64/65535,(512+896*cb)*64/65535,(512+896*cr)*64/65535);
    assert(fabsf(red.r-1)<0.00001 && fabsf(red.g)<0.00001 && fabsf(red.b)<0.00001);
    HDRRGB reference={0.5080784f,0.5080784f,0.5080784f};
    HDRRGB linear=hdr_2020_to_srgb(reference,100);
    assert(fabsf(linear.r-1)<0.001 && fabsf(linear.g-1)<0.001 && fabsf(linear.b-1)<0.001);
    assert(fabsf(hdr_hlg_scene(0))<0.00001f);
    assert(fabsf(hdr_hlg_scene(0.5f)-1.0f/12.0f)<0.00001f);
    assert(fabsf(hdr_hlg_scene(1)-1)<0.00001f);
    HDRRGB hlgWhite={0.75f,0.75f,0.75f};
    HDRRGB hlg=hdr_hlg_to_srgb(hlgWhite,100);
    assert(fabsf(hlg.r-2.0315f)<0.002f && fabsf(hlg.g-hlg.r)<0.0001f);
    hlg=hdr_hlg_to_srgb(hlgWhite,203);
    assert(fabsf(hlg.r-1)<0.002f);
    HDRRGB hlgPeak={1,1,1};hlg=hdr_hlg_to_srgb(hlgPeak,100);
    assert(fabsf(hlg.r-10)<0.001f);
    float lastHLG=0;
    for(int i=0;i<=1023;i++) {
        float c=i/1023.0f;HDRRGB v={c,c,c};v=hdr_hlg_to_srgb(v,100);
        assert(isfinite(v.r) && v.r>=lastHLG);lastHLG=v.r;
    }
    puts("PASS: PQ reference levels, round trip, monotonicity and headroom clipping, P010 range/matrix, HLG inverse OETF/OOTF and neutral gamut conversion (CPU only)");
}
