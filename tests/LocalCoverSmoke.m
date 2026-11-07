#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import "RemoteMediaProbe.h"
int main(int argc, const char **argv) { @autoreleasepool {
    if(argc!=3)return 2;
    NSDictionary *result=[[RemoteMediaProbe new] readFile:@(argv[1]) cover:YES];
    NSData *cover=result[@"cover"];
    if(!cover || [result[@"duration"] doubleValue]<11)return 3;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)cover,NULL);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;
    if(!image || CGImageGetWidth(image)>320 || CGImageGetHeight(image)>180)return 4;
    uint8_t pixels[16*16*4]={0};
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(pixels,16,16,8,64,color,(CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextDrawImage(context,CGRectMake(0,0,16,16),image);
    unsigned sum=0;for(int i=0;i<16*16;i++)sum+=pixels[i*4]+pixels[i*4+1]+pixels[i*4+2];
    if(sum<16*16*30)return 5;
    CGContextRelease(context);CGColorSpaceRelease(color);CGImageRelease(image);CFRelease(source);
    NSDictionary *black=[[RemoteMediaProbe new] readFile:@(argv[2]) cover:YES];
    if(black[@"cover"])return 6;
    RemoteMediaProbe *cancel=[RemoteMediaProbe new];[cancel cancel];
    if([cancel readFile:@(argv[1]) cover:YES].count)return 7;
    puts("PASS: MKV black opening skipped, nonblack cover decoded, entirely black clip not cached as cover, cancellation");
    return 0;
}}
