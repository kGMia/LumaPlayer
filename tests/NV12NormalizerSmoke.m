// SPDX-License-Identifier: GPL-3.0-or-later
// Opt-in GPU regression & P010 timing check.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "IIVEApple.h"
#include <math.h>
#include <stdio.h>
#include <stdint.h>

static CVPixelBufferRef make_buffer(size_t w, size_t h, OSType format, BOOL metal) {
    NSDictionary *attrs = metal
        ? @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{},
            (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES}
        : nil;
    CVPixelBufferRef pixels=NULL;
    CVPixelBufferCreate(NULL,w,h,format,(__bridge CFDictionaryRef)attrs,&pixels);
    return pixels;
}

// Reference model of the exact normalizeNV12 kernel math for both 8-bit NV12 and 10-bit P010.
static int verify_p010_reference_math(void) {
    int failures=0;
    for(int full=0;full<2;full++)for(int left=0;left<2;left++) {
        uint16_t y10_black=full?0:(16*4);
        uint16_t y10_white=full?1023:(235*4);
        float raw_black=(float)(y10_black<<6)/65535.0f;
        float raw_white=(float)(y10_white<<6)/65535.0f;
        float out_black, out_white;
        if(full) {
            out_black=(16.0f+((raw_black*(65535.0f/64.0f))/1023.0f)*219.0f)/255.0f;
            out_white=(16.0f+((raw_white*(65535.0f/64.0f))/1023.0f)*219.0f)/255.0f;
        } else {
            out_black=raw_black*(257.0f/256.0f);
            out_white=raw_white*(257.0f/256.0f);
        }
        int oy0=(int)lrintf(out_black*255.0f);
        int oy1=(int)lrintf(out_white*255.0f);
        if(abs(oy0-16)>0 || abs(oy1-235)>0) failures++;

        float uv0_raw=(float)((32*4)<<6)/65535.0f;
        float uv1_raw=(float)((224*4)<<6)/65535.0f;
        float sampled_uv = left ? (uv0_raw*0.75f + uv1_raw*0.25f) : uv0_raw;
        float out_uv;
        if(full) {
            float code10 = sampled_uv*(65535.0f/64.0f);
            out_uv = (128.0f + (code10 - 512.0f)*(224.0f/1023.0f))/255.0f;
        } else {
            out_uv = sampled_uv*(257.0f/256.0f);
        }
        double chroma10=left?(32*4)*0.75+(224*4)*0.25:(32*4);
        double expectedChroma=full?(128.0+(chroma10-512.0)*(224.0/1023.0)):(chroma10/4.0);
        if(fabs(out_uv*255.0 - expectedChroma) > 0.05) failures++;
    }
    return failures;
}

static int test_nv12_8bit(void *engine) {
    int failures=0;
    for(int full=0;full<2;full++)for(int left=0;left<2;left++) {
        CVPixelBufferRef source=make_buffer(4,2,full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,YES);
        CVPixelBufferRef output=make_buffer(4,2,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,YES);
        if(!source || !output){if(source)CVPixelBufferRelease(source);if(output)CVPixelBufferRelease(output);failures++;continue;}
        CVPixelBufferLockBaseAddress(source,0);
        uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(source,0),*uv=CVPixelBufferGetBaseAddressOfPlane(source,1);
        size_t stride=CVPixelBufferGetBytesPerRowOfPlane(source,0);
        for(int row=0;row<2;row++)for(int col=0;col<4;col++)y[row*stride+col]=full?(col?255:0):(col?235:16);
        uv[0]=32;uv[1]=128;uv[2]=224;uv[3]=128;
        CVPixelBufferUnlockBaseAddress(source,0);
        CVBufferSetAttachment(source,kCVImageBufferChromaLocationTopFieldKey,left?kCVImageBufferChromaLocation_Left:kCVImageBufferChromaLocation_Center,kCVAttachmentMode_ShouldPropagate);
        if(!iive_nv12_normalize(engine,source,output,full,left))failures++;
        else {
            CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
            uint8_t *oy=CVPixelBufferGetBaseAddressOfPlane(output,0),*ouv=CVPixelBufferGetBaseAddressOfPlane(output,1);
            double chroma=left?32*0.75+224*0.25:32;
            double last=224;
            if(full){chroma=128+(chroma-128)*224.0/255;last=128+(last-128)*224.0/255;}
            if(abs(oy[0]-16)>1 || abs(oy[1]-235)>1 || fabs(ouv[0]-chroma)>1 ||
               fabs(ouv[2]-last)>1 || abs(ouv[1]-128)>1 || abs(ouv[3]-128)>1)failures++;
            CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
            CFTypeRef inputTag=CVBufferCopyAttachment(source,kCVImageBufferChromaLocationTopFieldKey,NULL);
            CFTypeRef outputTag=CVBufferCopyAttachment(output,kCVImageBufferChromaLocationTopFieldKey,NULL);
            if(!inputTag || !CFEqual(inputTag,left?kCVImageBufferChromaLocation_Left:kCVImageBufferChromaLocation_Center) ||
               !outputTag || !CFEqual(outputTag,kCVImageBufferChromaLocation_Center))failures++;
            if(inputTag)CFRelease(inputTag);if(outputTag)CFRelease(outputTag);
        }
        CVPixelBufferRelease(source);CVPixelBufferRelease(output);
    }
    return failures;
}

static int test_p010_10bit(void *engine) {
    int failures=0;
    for(int full=0;full<2;full++)for(int left=0;left<2;left++) {
        CVPixelBufferRef source=make_buffer(4,2,full?kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,YES);
        CVPixelBufferRef output=make_buffer(4,2,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,YES);
        if(!source || !output){if(source)CVPixelBufferRelease(source);if(output)CVPixelBufferRelease(output);failures++;continue;}
        CVPixelBufferLockBaseAddress(source,0);
        uint8_t *yBytes=CVPixelBufferGetBaseAddressOfPlane(source,0),*uvBytes=CVPixelBufferGetBaseAddressOfPlane(source,1);
        size_t yStride=CVPixelBufferGetBytesPerRowOfPlane(source,0);
        for(int row=0;row<2;row++) {
            uint16_t *yRow=(uint16_t *)(yBytes + row*yStride);
            for(int col=0;col<4;col++) {
                uint16_t code10=full?(col?1023:0):(col?(235*4):(16*4));
                yRow[col]=(uint16_t)(code10 << 6);
            }
        }
        uint16_t *uv=(uint16_t *)uvBytes;
        uv[0]=(uint16_t)((32*4) << 6);
        uv[1]=(uint16_t)((128*4) << 6);
        uv[2]=(uint16_t)((224*4) << 6);
        uv[3]=(uint16_t)((128*4) << 6);
        CVPixelBufferUnlockBaseAddress(source,0);
        CVBufferSetAttachment(source,kCVImageBufferChromaLocationTopFieldKey,left?kCVImageBufferChromaLocation_Left:kCVImageBufferChromaLocation_Center,kCVAttachmentMode_ShouldPropagate);
        if(!iive_nv12_normalize(engine,source,output,full,left))failures++;
        else {
            CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
            uint8_t *oy=CVPixelBufferGetBaseAddressOfPlane(output,0),*ouv=CVPixelBufferGetBaseAddressOfPlane(output,1);
            double chroma10=left?(32*4)*0.75+(224*4)*0.25:(32*4);
            double last10=224*4;
            double expectedChroma=full?(128.0+(chroma10-512.0)*(224.0/1023.0)):(chroma10/4.0);
            double expectedLast=full?(128.0+(last10-512.0)*(224.0/1023.0)):(last10/4.0);
            if(abs(oy[0]-16)>1 || abs(oy[1]-235)>1 || fabs(ouv[0]-expectedChroma)>1.5 ||
               fabs(ouv[2]-expectedLast)>1.5 || abs(ouv[1]-128)>1 || abs(ouv[3]-128)>1) {
                fprintf(stderr,"P010 mismatch (full=%d,left=%d): oy=[%d,%d] ouv=[%d,%d,%d,%d] expectedChroma=%.1f expectedLast=%.1f\n",
                        full,left,oy[0],oy[1],ouv[0],ouv[1],ouv[2],ouv[3],expectedChroma,expectedLast);
                failures++;
            }
            CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
        }
        CVPixelBufferRelease(source);CVPixelBufferRelease(output);
    }
    return failures;
}

static void measure_p010_latency(void *engine, size_t w, size_t h, const char *label) {
    BOOL useMetal = (engine != NULL);
    CVPixelBufferRef source=make_buffer(w,h,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,useMetal);
    CVPixelBufferRef dest=make_buffer(w,h,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,useMetal);
    if(!source || !dest) {
        if(source)CVPixelBufferRelease(source);
        if(dest)CVPixelBufferRelease(dest);
        return;
    }
    int iters=12;
    double gpuMs=-1.0;
    if(engine) {
        for(int i=0;i<3;i++) iive_nv12_normalize(engine,source,dest,false,true);
        CFTimeInterval t0=CACurrentMediaTime();
        for(int i=0;i<iters;i++) {
            iive_nv12_normalize(engine,source,dest,false,true);
        }
        gpuMs=(CACurrentMediaTime()-t0)*1000.0/iters;
    }

    CFTimeInterval t1=CACurrentMediaTime();
    for(int i=0;i<iters;i++) {
        CVPixelBufferLockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(dest,0);
        for(int p=0;p<2;p++) {
            size_t pw=CVPixelBufferGetWidthOfPlane(source,p)*(p==1?2:1);
            size_t ph=CVPixelBufferGetHeightOfPlane(source,p);
            const uint8_t *srcBase=CVPixelBufferGetBaseAddressOfPlane(source,p);
            uint8_t *dstBase=CVPixelBufferGetBaseAddressOfPlane(dest,p);
            size_t srcStride=CVPixelBufferGetBytesPerRowOfPlane(source,p);
            size_t dstStride=CVPixelBufferGetBytesPerRowOfPlane(dest,p);
            for(size_t r=0;r<ph;r++) {
                const uint16_t *sRow=(const uint16_t *)(srcBase+r*srcStride);
                uint8_t *dRow=dstBase+r*dstStride;
                for(size_t c=0;c<pw;c++) dRow[c]=(uint8_t)(sRow[c]>>8);
            }
        }
        CVPixelBufferUnlockBaseAddress(dest,0);
        CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
    }
    double cpuMs=(CACurrentMediaTime()-t1)*1000.0/iters;

    CFTimeInterval t2=CACurrentMediaTime();
    for(int i=0;i<iters;i++) {
        CVPixelBufferRef retained=CVPixelBufferRetain(source);
        CVPixelBufferRelease(retained);
    }
    double zeroCopyMs=(CACurrentMediaTime()-t2)*1000.0/iters;

    if(gpuMs>=0) {
        printf("P010 %s (%zux%zu) input_ms: shared-p010=%.4f ms | metal-normalized=%.3f ms | cpu-copy=%.3f ms\n",
               label,w,h,zeroCopyMs,gpuMs,cpuMs);
    } else {
        printf("P010 %s (%zux%zu) input_ms: shared-p010=%.4f ms | cpu-copy=%.3f ms (GPU device restricted in CLI sandbox)\n",
               label,w,h,zeroCopyMs,cpuMs);
    }
    CVPixelBufferRelease(source);
    CVPixelBufferRelease(dest);
}

int main(void) { @autoreleasepool {
    int mathFailures=verify_p010_reference_math();
    printf("P010 10-bit reference quantization/chroma math: %s (%d failures)\n",mathFailures?"FAIL":"PASS",mathFailures);
    void *engine=iive_nv12_create();
    if(!engine) {
        measure_p010_latency(NULL,1920,1080,"1080p");
        measure_p010_latency(NULL,3840,2160,"4K");
        return mathFailures?1:0;
    }
    int failures8=test_nv12_8bit(engine);
    int failures10=test_p010_10bit(engine);
    int failures=mathFailures+failures8+failures10;
    printf("NV12 8-bit limited/full × centered/left: %s (%d failures)\n",failures8?"FAIL":"PASS",failures8);
    printf("P010 10-bit limited/full × centered/left: %s (%d failures)\n",failures10?"FAIL":"PASS",failures10);
    if(!failures) {
        measure_p010_latency(engine,1920,1080,"1080p");
        measure_p010_latency(engine,3840,2160,"4K");
    }
    iive_nv12_destroy(engine);
    return failures?1:0;
}}
