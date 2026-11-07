// SPDX-License-Identifier: GPL-3.0-or-later
#include <assert.h>
#include <stdio.h>
#include "../native/Player/Modern/VideoCrop.h"
int main(void) {
    struct IIVECrop c;
    assert(iive_center_crop(1920,1080,1,0,4.0/3,&c));
    assert(c.w==1440 && c.h==1080 && c.x==240 && c.y==0);
    assert(iive_center_crop(3840,2160,1,0,4.0/3,&c));
    assert(c.w==2880 && c.h==2160 && c.x==480);
    // PAL anamorphic 16:9 becomes centered 4:3 without stretching pixels.
    assert(iive_center_crop(720,576,64.0/45,0,4.0/3,&c));
    assert(c.w==540 && c.h==576 && c.x==90);
    // A 90-degree rotated landscape frame already presents as 9:16.
    assert(iive_center_crop(1920,1080,1,90,9.0/16,&c));
    assert(c.w==1920 && c.h==1080);
    assert(iive_center_crop(1080,1920,1,0,16.0/9,&c));
    assert(c.w==1080 && c.h==606 && c.y==656);
    for(int r=0;r<360;r+=90)for(int w=2;w<4000;w+=113) {
        if(iive_center_crop(w,1081,1,r,2.39,&c)) {
            assert(c.x>=0 && c.y>=0 && c.x+c.w<=w && c.y+c.h<=1081);
            assert(!(c.w%2 || c.h%2 || c.x%2 || c.y%2));
        }
    }
    assert(!iive_center_crop(0,1080,1,0,1,&c));
    assert(!iive_center_crop(1920,1080,NAN,0,1,&c));
    assert(!iive_center_crop(1920,1080,1,45,1,&c));
    puts("PASS: crop geometry, anamorphic pixels, rotation, 2x SR, chroma alignment and invalid dimensions.");
}
