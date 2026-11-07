// SPDX-License-Identifier: GPL-3.0-or-later
// No window or drawable: checks the shared RGBA16F representation and GL->Metal handoff.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLIOSurface.h>
#include <math.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#define CHECK(condition, message) do { if(!(condition)) { fprintf(stderr,"FAIL: %s\n",message); return 1; } } while(0)
int main(void) { @autoreleasepool {
    const int width=16,height=8;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();CHECK(device,"Metal device unavailable");
    CGLPixelFormatAttribute attrs[]={kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAccelerated,0};
    CGLPixelFormatObj format=NULL;GLint count=0;
    CHECK(CGLChoosePixelFormat(attrs,&format,&count)==kCGLNoError && format,"CGL format");
    CGLContextObj context=NULL;
    CHECK(CGLCreateContext(format,NULL,&context)==kCGLNoError,"CGL context");CGLReleasePixelFormat(format);
    CHECK(CGLSetCurrentContext(context)==kCGLNoError,"current CGL context");
    CVPixelBufferRef pixels=NULL;
    NSDictionary *properties=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES,(id)kCVPixelBufferOpenGLCompatibilityKey:@YES};
    CHECK(CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_64RGBAHalf,(__bridge CFDictionaryRef)properties,&pixels)==kCVReturnSuccess,"RGBA16F pixel buffer");
    IOSurfaceRef surface=CVPixelBufferGetIOSurface(pixels);CHECK(surface,"IOSurface");
    GLuint texture=0,fbo=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_RECTANGLE,texture);
    CGLError bound=CGLTexImageIOSurface2D(context,GL_TEXTURE_RECTANGLE,GL_RGBA16F,width,height,GL_RGBA,GL_HALF_FLOAT,surface,0);
    if(bound!=kCGLNoError){fprintf(stderr,"CGL binding: %s\n",CGLErrorString(bound));return 1;}
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_RECTANGLE,texture,0);
    CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"RGBA16F framebuffer completeness");
    MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:width height:height mipmapped:NO];
    desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> shared=[device newTextureWithDescriptor:desc iosurface:surface plane:0];CHECK(shared,"Metal shared texture");
    const GLfloat lower[4]={2.0f,0.25f,0.5f,1.0f},upper[4]={0.125f,4.0f,0.75f,1.0f};
    glEnable(GL_SCISSOR_TEST);glScissor(0,0,width,height/2);glClearBufferfv(GL_COLOR,0,lower);
    glScissor(0,height/2,width,height/2);glClearBufferfv(GL_COLOR,0,upper);glDisable(GL_SCISSOR_TEST);
    CHECK(glGetError()==GL_NO_ERROR,"GL clear");
    GLsync fence=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);CHECK(fence,"GL fence");glFlush();
    // Deadline is only for this diagnostic. The production prototype polls with zero timeout.
    double deadline=NSProcessInfo.processInfo.systemUptime+5;
    GLenum status;
    do {status=glClientWaitSync(fence,0,1000000);} while(status==GL_TIMEOUT_EXPIRED && NSProcessInfo.processInfo.systemUptime<deadline);
    CHECK(status==GL_ALREADY_SIGNALED || status==GL_CONDITION_SATISFIED,"GL fence completion");glDeleteSync(fence);
    const NSUInteger rowBytes=256;
    id<MTLBuffer> readback=[device newBufferWithLength:rowBytes*height options:MTLResourceStorageModeShared];CHECK(readback,"readback buffer");
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];CHECK(blit,"Metal encoder");
    [blit copyFromTexture:shared sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1)
        toBuffer:readback destinationOffset:0 destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes*height];
    [blit endEncoding];[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted,"Metal completion");
    for(int y=0;y<height;y++) {
        const __fp16 *row=(const __fp16*)((const uint8_t*)readback.contents+y*rowBytes);
        const GLfloat *expected=y<height/2?lower:upper;
        for(int x=0;x<width;x++)for(int c=0;c<4;c++)CHECK(fabsf((float)row[x*4+c]-expected[c])<0.0001f,"channel, row-order or >1.0 value changed");
    }
    glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&texture);shared=nil;CVPixelBufferRelease(pixels);
    CGLSetCurrentContext(NULL);CGLReleaseContext(context);
    puts("PASS: 16x8 RGBA16F IOSurface, GL fence -> Metal blit/readback; channel/row order matches; 2.0 and 4.0 preserved. No display/HDR performance validation.");
    return 0;
} }
