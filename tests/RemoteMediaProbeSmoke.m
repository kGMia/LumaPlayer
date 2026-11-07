#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import "RemoteMediaProbe.h"
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2)return 2;
    NSDictionary *opts=@{@"demuxer-lavf-format":@"mov",@"stream-lavf-o":@"max_redirects=0",@"http-header-fields":@"Authorization: Basic dGVzdDp0ZXN0LW9ubHk="};
    RemoteMediaProbe *probe=[RemoteMediaProbe new];
    NSDictionary *result=[probe readURL:@(argv[1]) options:opts cover:YES];
    if([result[@"duration"] doubleValue]<0.9 || ![result[@"cover"] isKindOfClass:NSData.class])return 3;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)result[@"cover"],NULL);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;
    if(!image || CGImageGetWidth(image)>320 || CGImageGetHeight(image)>180)return 4;
    CGImageRelease(image);CFRelease(source);
    RemoteMediaProbe *canceled=[RemoteMediaProbe new];[canceled cancel];
    if([canceled readURL:@(argv[1]) options:opts cover:YES].count)return 5;
    NSDictionary *basic=[[RemoteMediaProbe new] readURL:@(argv[1]) options:opts cover:NO];
    if([basic[@"duration"] doubleValue]<0.9 || basic[@"cover"])return 6;
    printf("PASS: authenticated native remote duration/thumbnail read, duration-only read and cancellation\n");
    return 0;
}}
