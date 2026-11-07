// SPDX-License-Identifier: GPL-3.0-or-later
#import "RemoteMediaProbe.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
#include <stdatomic.h>
#include <sys/stat.h>

struct ProbeBudget { atomic_bool canceled; int64_t deadline, byteLimit; AVIOContext *io; };
static int interrupted(void *opaque) {
    struct ProbeBudget *b=opaque;
    return atomic_load(&b->canceled) || av_gettime_relative()>b->deadline || (b->io && b->io->bytes_read>=b->byteLimit);
}
static int blockNested(AVFormatContext *s, AVIOContext **p, const char *u, int flags, AVDictionary **o) { return AVERROR(EACCES); }
@implementation RemoteMediaProbe { struct ProbeBudget _budget; }
- (void)cancel { atomic_store(&_budget.canceled,true); }
- (NSDictionary *)readFile:(NSString *)path cover:(BOOL)cover {
    struct stat info;
    if(!path.isAbsolutePath || stat(path.fileSystemRepresentation,&info)!=0 || !S_ISREG(info.st_mode))return @{};
    return [self readMedia:path options:@{} cover:cover local:YES];
}
- (nullable NSData *)readAttachedCover:(NSString *)path {
    struct stat info;
    if(!path.isAbsolutePath || stat(path.fileSystemRepresentation,&info)!=0 || !S_ISREG(info.st_mode))return nil;
    if(atomic_load(&_budget.canceled))return nil;
    _budget.deadline=av_gettime_relative()+1500000;
    _budget.byteLimit=16*1024*1024;
    AVIOInterruptCB interrupt={interrupted,&_budget};
    AVDictionary *opts=NULL;AVIOContext *io=NULL;AVFormatContext *fmt=NULL;
    NSData *coverData=nil;
    av_dict_set(&opts,"protocol_whitelist","file",0);
    av_dict_set(&opts,"rw_timeout","1500000",0);
    if(avio_open2(&io,path.UTF8String,AVIO_FLAG_READ,&interrupt,&opts)<0)goto cleanup;
    av_dict_free(&opts);_budget.io=io;
    fmt=avformat_alloc_context();if(!fmt)goto cleanup;
    fmt->pb=io;fmt->flags|=AVFMT_FLAG_CUSTOM_IO;fmt->interrupt_callback=interrupt;fmt->io_open=blockNested;
    fmt->probesize=512*1024;fmt->max_analyze_duration=AV_TIME_BASE/4;fmt->max_streams=32;
    av_dict_set(&opts,"format_whitelist","mov,matroska,webm,avi,mpegts,mpeg,asf,flv,mp3,flac,wav,aac,ogg,aiff,caf",0);
    if(avformat_open_input(&fmt,NULL,NULL,&opts)<0)goto cleanup;
    for(unsigned int i=0;i<fmt->nb_streams;i++) {
        AVStream *stream=fmt->streams[i];
        if((stream->disposition&AV_DISPOSITION_ATTACHED_PIC) &&
           stream->attached_pic.data && stream->attached_pic.size>0 &&
           stream->attached_pic.size<=32*1024*1024) {
            coverData=[NSData dataWithBytes:stream->attached_pic.data length:(NSUInteger)stream->attached_pic.size];
            break;
        }
    }
cleanup:
    avformat_close_input(&fmt);_budget.io=NULL;avio_closep(&io);av_dict_free(&opts);
    return atomic_load(&_budget.canceled)?nil:coverData;
}
- (NSDictionary *)readURL:(NSString *)url options:(NSDictionary<NSString *,NSString *> *)options cover:(BOOL)cover {
    return [self readMedia:url options:options cover:cover local:NO];
}
- (NSDictionary *)readMedia:(NSString *)url options:(NSDictionary<NSString *,NSString *> *)options cover:(BOOL)cover local:(BOOL)local {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    if(atomic_load(&_budget.canceled))return result;
    // Only requests already resolved and constrained as a direct media file.
    if(!local && (!options[@"demuxer-lavf-format"] || ![options[@"stream-lavf-o"] isEqual:@"max_redirects=0"]))return result;
    _budget.deadline=av_gettime_relative()+(cover?6000000:3000000);
    _budget.byteLimit=(cover?(local?32:8):2)*1024*1024;
    AVIOInterruptCB interrupt={interrupted,&_budget};
    AVDictionary *opts=NULL;AVIOContext *io=NULL;AVFormatContext *fmt=NULL;
    AVCodecContext *decoder=NULL;AVPacket *pkt=NULL;AVFrame *frame=NULL;struct SwsContext *sws=NULL;
    av_dict_set(&opts,"protocol_whitelist",local?"file":"http,https,tcp,tls",0);
    av_dict_set(&opts,"tls_verify","1",0);av_dict_set(&opts,"max_redirects","0",0);
    if([NSBundle.mainBundle URLForResource:@"RuntimeDependencies" withExtension:@"json"])
        av_dict_set(&opts,"ca_file","/etc/ssl/cert.pem",0);
    av_dict_set(&opts,"rw_timeout","4000000",0);
    if(options[@"http-header-fields"])av_dict_set(&opts,"headers",[[options[@"http-header-fields"] stringByAppendingString:@"\r\n"] UTF8String],0);
    if(avio_open2(&io,url.UTF8String,AVIO_FLAG_READ,&interrupt,&opts)<0)goto done;
    av_dict_free(&opts);_budget.io=io;
    fmt=avformat_alloc_context();if(!fmt)goto done;
    fmt->pb=io;fmt->flags|=AVFMT_FLAG_CUSTOM_IO;fmt->interrupt_callback=interrupt;fmt->io_open=blockNested;
    fmt->probesize=(cover?512:128)*1024;fmt->max_analyze_duration=cover?AV_TIME_BASE:AV_TIME_BASE/4;fmt->max_streams=32;
    const AVInputFormat *input=local?NULL:av_find_input_format(options[@"demuxer-lavf-format"].UTF8String);
    if(local)av_dict_set(&opts,"format_whitelist","mov,matroska,webm,avi,mpegts,mpeg,asf,flv,mp3,flac,wav,aac,ogg,aiff,caf",0);
    if((!local && !input) || avformat_open_input(&fmt,NULL,input,&opts)<0)goto done;
    // Many containers already declare duration in the header. Duration-only
    // rows need neither packet analysis nor a decoder in that case.
    BOOL streamsInspected=NO;
    if(cover || fmt->duration<=0 || fmt->duration==AV_NOPTS_VALUE)
        streamsInspected=avformat_find_stream_info(fmt,NULL)>=0;
    if(fmt->duration>0 && fmt->duration!=AV_NOPTS_VALUE)result[@"duration"]=@((double)fmt->duration/AV_TIME_BASE);
    if(!result[@"duration"]) {
        for(unsigned i=0;i<fmt->nb_streams;i++) {
            AVStream *stream=fmt->streams[i];
            if((stream->codecpar->codec_type==AVMEDIA_TYPE_VIDEO || stream->codecpar->codec_type==AVMEDIA_TYPE_AUDIO) &&
               !(stream->disposition&AV_DISPOSITION_ATTACHED_PIC) && stream->duration>0 && stream->duration!=AV_NOPTS_VALUE) {
                double duration=stream->duration*av_q2d(stream->time_base);
                if(isfinite(duration) && duration>[result[@"duration"] doubleValue])result[@"duration"]=@(duration);
            }
        }
    }
    // A positive count is conclusive even when a bounded probe was incomplete.
    int subtitleCount=0;
    for(unsigned int si=0;si<fmt->nb_streams;si++)
        if(fmt->streams[si]->codecpar->codec_type==AVMEDIA_TYPE_SUBTITLE)subtitleCount++;
    if(subtitleCount>0 || streamsInspected)result[@"subtitleCount"]=@(subtitleCount);
    if(!cover || interrupted(&_budget))goto done;
    int index=av_find_best_stream(fmt,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
    if(index<0)goto done;
    AVCodecParameters *par=fmt->streams[index]->codecpar;
    if(par->color_trc==AVCOL_TRC_SMPTE2084 || par->color_trc==AVCOL_TRC_ARIB_STD_B67)goto done;
    if(par->width<=0 || par->height<=0 || (int64_t)par->width*par->height>16777216)goto done;
    const AVCodec *codec=avcodec_find_decoder(par->codec_id);if(!codec)goto done;
    decoder=avcodec_alloc_context3(codec);if(!decoder)goto done;
    if(avcodec_parameters_to_context(decoder,par)<0)goto done;
    decoder->thread_count=1;decoder->max_pixels=16777216;decoder->skip_frame=AVDISCARD_NONKEY;
    if(avcodec_open2(decoder,codec,NULL)<0)goto done;
    pkt=av_packet_alloc();frame=av_frame_alloc();if(!pkt || !frame)goto done;
    // Opening keyframes are often black (studio fades / chapter leaders).
    // Local files can seek cheaply; remote probes retain their strict transfer budget.
    BOOL attached=(fmt->streams[index]->disposition&AV_DISPOSITION_ATTACHED_PIC)!=0;
    double duration=[result[@"duration"] doubleValue];
    const double fractions[3]={0.10,0.35,0.65};
    const double caps[3]={30.0,120.0,300.0};
    int seekAttempt=0;
    if(local && !attached && duration>1 && (io->seekable&AVIO_SEEKABLE_NORMAL)) {
        double seconds=MIN(caps[0],duration*fractions[0]);
        int64_t start=fmt->streams[index]->start_time==AV_NOPTS_VALUE?0:fmt->streams[index]->start_time;
        int64_t timestamp=start+av_rescale_q((int64_t)(seconds*AV_TIME_BASE),AV_TIME_BASE_Q,fmt->streams[index]->time_base);
        if(av_seek_frame(fmt,index,timestamp,AVSEEK_FLAG_BACKWARD)>=0)avcodec_flush_buffers(decoder);
        seekAttempt=1;
    }
    for(int count=0;count<1024 && !interrupted(&_budget);count++) {
        int read=av_read_frame(fmt,pkt);
        if(read<0)avcodec_send_packet(decoder,NULL);
        else if(pkt->stream_index==index)avcodec_send_packet(decoder,pkt);
        av_packet_unref(pkt);
        if(avcodec_receive_frame(decoder,frame)==0) {
            if(frame->color_trc==AVCOL_TRC_SMPTE2084 || frame->color_trc==AVCOL_TRC_ARIB_STD_B67)break;
            double scale=MIN(1.0,MIN(320.0/frame->width,180.0/frame->height));
            int w=MAX(1,(int)(frame->width*scale)),h=MAX(1,(int)(frame->height*scale));
            NSMutableData *pixels=[NSMutableData dataWithLength:w*h*4];
            uint8_t *dst[4]={pixels.mutableBytes,NULL,NULL,NULL};int strides[4]={w*4,0,0,0};
            sws=sws_getCachedContext(sws,frame->width,frame->height,frame->format,w,h,AV_PIX_FMT_RGBA,SWS_BILINEAR,NULL,NULL,NULL);
            if(!sws)break;
            const int *coef=sws_getCoefficients(frame->colorspace==AVCOL_SPC_BT709?SWS_CS_ITU709:SWS_CS_DEFAULT);
            sws_setColorspaceDetails(sws,coef,frame->color_range==AVCOL_RANGE_JPEG,coef,1,0,1<<16,1<<16);
            if(sws_scale(sws,(const uint8_t *const *)frame->data,frame->linesize,0,frame->height,dst,strides)<=0)break;
            unsigned samples=0, visible=0;
            double luminance=0;
            const uint8_t *rgba=pixels.bytes;
            // Sample the center as well as edges; letterboxing must not classify a normal frame as black.
            for(int y=0;y<h;y+=4)for(int x=0;x<w;x+=4) {
                const uint8_t *p=rgba+(y*w+x)*4;
                double luma=0.2126*p[0]+0.7152*p[1]+0.0722*p[2];
                luminance+=luma;samples++;if(luma>20)visible++;
            }
            BOOL black=!attached && samples && luminance/samples<8 && visible*100<samples*2;
            if(black) {
                av_frame_unref(frame);
                if(local && seekAttempt<3 && duration>1 && (io->seekable&AVIO_SEEKABLE_NORMAL)) {
                    double seconds=MIN(caps[seekAttempt],duration*fractions[seekAttempt]);seekAttempt++;
                    int64_t start=fmt->streams[index]->start_time==AV_NOPTS_VALUE?0:fmt->streams[index]->start_time;
                    int64_t timestamp=start+av_rescale_q((int64_t)(seconds*AV_TIME_BASE),AV_TIME_BASE_Q,fmt->streams[index]->time_base);
                    if(av_seek_frame(fmt,index,timestamp,AVSEEK_FLAG_BACKWARD)>=0)avcodec_flush_buffers(decoder);
                }
                if(read<0)break;
                continue;
            }
            CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context=CGBitmapContextCreate(pixels.mutableBytes,w,h,8,w*4,space,(CGBitmapInfo)kCGImageAlphaNoneSkipLast);
            CGImageRef image=context?CGBitmapContextCreateImage(context):NULL;
            if(image) {
                NSMutableData *data=[NSMutableData data];
                CGImageDestinationRef out=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,NULL);
                if(out){CGImageDestinationAddImage(out,image,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@0.72});if(CGImageDestinationFinalize(out))result[@"cover"]=data;CFRelease(out);}
                CGImageRelease(image);
            }
            if(context)CGContextRelease(context);CGColorSpaceRelease(space);break;
        }
        if(read<0)break;
    }
done:
    sws_freeContext(sws);av_frame_free(&frame);av_packet_free(&pkt);avcodec_free_context(&decoder);
    avformat_close_input(&fmt);_budget.io=NULL;avio_closep(&io);av_dict_free(&opts);
    return atomic_load(&_budget.canceled)?@{}:result;
}
@end
