// SPDX-License-Identifier: GPL-3.0-or-later
#include <math.h>
#include <stdbool.h>

struct IIVECrop { int w, h, x, y; };
// mpv's video-crop x:y syntax means an OFFSET, not an aspect ratio.
// Calculate a centered rectangle in post-filter pixels; account for PAR and
// the display rotation, and align to chroma samples for 4:2:0 surfaces.
static inline bool iive_center_crop(int w, int h, double par, int rotation,
                                    double target, struct IIVECrop *out) {
    if(w<2 || h<2 || w>65536 || h>65536 || !isfinite(par) || par<=0 ||
       !isfinite(target) || target<=0 || rotation%90) return false;
    if(rotation%180)target=1.0/target;
    double pixel_ratio=target/par;
    double cw=w, ch=h;
    if(w/(double)h>pixel_ratio)cw=h*pixel_ratio;else ch=w/pixel_ratio;
    // Rational pixel aspects can land just below an exact integer in double
    // precision (e.g. 540 becomes 539.99999); avoid losing a chroma pair.
    int iw=((int)floor(fmin(w,cw+1e-7)))&~1, ih=((int)floor(fmin(h,ch+1e-7)))&~1;
    if(iw<2 || ih<2)return false;
    *out=(struct IIVECrop){iw,ih,((w-iw)/2)&~1,((h-ih)/2)&~1};
    return true;
}
