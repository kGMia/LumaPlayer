// SPDX-License-Identifier: GPL-3.0-or-later
#import "LocalVideoPreview.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <math.h>

@implementation IIVELocalPreviewFrame
- (instancetype)initWithImage:(CGImageRef)image seconds:(double)seconds {
    if((self=[super init])){_image=CGImageRetain(image);_seconds=seconds;}return self;
}
- (void)dealloc { CGImageRelease(_image); }
@end

struct LocalBudget { atomic_bool canceled; int64_t deadline; };
static int interrupted(void *opaque) {
    struct LocalBudget *b=opaque;
    return atomic_load(&b->canceled) || av_gettime_relative()>=b->deadline;
}
static int blockNested(AVFormatContext *s, AVIOContext **p, const char *u, int flags, AVDictionary **o) {return AVERROR(EACCES);}
static bool hdr(enum AVColorTransferCharacteristic trc) {return trc==AVCOL_TRC_SMPTE2084 || trc==AVCOL_TRC_ARIB_STD_B67;}

@implementation IIVELocalVideoPreview {
    struct LocalBudget _budget;
    AVFormatContext *_format;
    AVIOContext *_io;
    AVCodecContext *_decoder;
    struct SwsContext *_scale;
    NSString *_path;
    struct stat _stamp;
    int _stream;
}
- (void)cancel {atomic_store(&_budget.canceled,true);}
- (void)close {
    sws_freeContext(_scale);_scale=NULL;
    avcodec_free_context(&_decoder);avformat_close_input(&_format);avio_closep(&_io);_path=nil;
}
- (void)dealloc {[self close];}
- (BOOL)openPath:(NSString *)path stamp:(struct stat)stamp {
    if(_format && [_path isEqual:path] && _stamp.st_dev==stamp.st_dev && _stamp.st_ino==stamp.st_ino &&
       _stamp.st_size==stamp.st_size && _stamp.st_mtimespec.tv_sec==stamp.st_mtimespec.tv_sec &&
       _stamp.st_mtimespec.tv_nsec==stamp.st_mtimespec.tv_nsec)return YES;
    [self close];
    _format=avformat_alloc_context();if(!_format)return NO;
    _format->interrupt_callback=(AVIOInterruptCB){interrupted,&_budget};_format->io_open=blockNested;
    _format->probesize=512*1024;_format->max_analyze_duration=AV_TIME_BASE;_format->max_streams=64;
    AVDictionary *options=NULL;av_dict_set(&options,"protocol_whitelist","file",0);
    int status=avio_open2(&_io,path.fileSystemRepresentation,AVIO_FLAG_READ,&_format->interrupt_callback,&options);
    av_dict_free(&options);
    if(status<0){[self close];return NO;}
    _format->pb=_io;_format->flags|=AVFMT_FLAG_CUSTOM_IO;
    // Force a direct Matroska demuxer: no playlists or nested/network resources.
    status=avformat_open_input(&_format,NULL,av_find_input_format("matroska"),NULL);
    if(status<0 || avformat_find_stream_info(_format,NULL)<0)goto failed;
    _stream=-1;
    for(unsigned i=0;i<_format->nb_streams;i++) {
        AVStream *s=_format->streams[i];
        if(s->codecpar->codec_type==AVMEDIA_TYPE_VIDEO && !(s->disposition&AV_DISPOSITION_ATTACHED_PIC)) {_stream=i;break;}
    }
    if(_stream<0)goto failed;
    AVStream *stream=_format->streams[_stream];AVCodecParameters *p=stream->codecpar;
    // Delegate rotation, anamorphic pixels and HDR to the established path.
    AVRational sar=av_guess_sample_aspect_ratio(_format,stream,NULL);
    if(hdr(p->color_trc) || (sar.num>0 && sar.den>0 && sar.num!=sar.den) ||
       av_dict_get(stream->metadata,"rotate",NULL,0) ||
       av_packet_side_data_get(p->coded_side_data,p->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX) ||
       av_packet_side_data_get(p->coded_side_data,p->nb_coded_side_data,AV_PKT_DATA_DOVI_CONF) ||
       p->width<=0 || p->height<=0 || (int64_t)p->width*p->height>16777216)goto failed;
    const AVCodec *codec=avcodec_find_decoder(p->codec_id);if(!codec)goto failed;
    _decoder=avcodec_alloc_context3(codec);if(!_decoder)goto failed;
    if(avcodec_parameters_to_context(_decoder,p)<0)goto failed;
    _decoder->thread_count=1;_decoder->max_pixels=16777216;
    if(avcodec_open2(_decoder,codec,NULL)<0)goto failed;
    _path=[path copy];_stamp=stamp;return YES;
failed:
    [self close];return NO;
}
- (IIVELocalPreviewFrame *)imageFromFrame:(AVFrame *)frame seconds:(double)seconds {
    if(hdr(frame->color_trc) || av_frame_get_side_data(frame,AV_FRAME_DATA_DISPLAYMATRIX) ||
       frame->width<=0 || frame->height<=0 ||
       (int64_t)frame->width*frame->height>16777216 ||
       (frame->sample_aspect_ratio.num>0 && frame->sample_aspect_ratio.den>0 &&
        frame->sample_aspect_ratio.num!=frame->sample_aspect_ratio.den))return nil;
    double factor=MIN(320.0/frame->width,180.0/frame->height);
    int w=MAX(1,(int)lrint(frame->width*factor)),h=MAX(1,(int)lrint(frame->height*factor));
    _scale=sws_getCachedContext(_scale,frame->width,frame->height,frame->format,w,h,AV_PIX_FMT_RGBA,SWS_BICUBIC,NULL,NULL,NULL);
    if(!_scale)return nil;
    int matrix=frame->colorspace==AVCOL_SPC_BT709?SWS_CS_ITU709:
        frame->colorspace==AVCOL_SPC_BT2020_NCL?SWS_CS_BT2020:SWS_CS_DEFAULT;
    const int *coefficients=sws_getCoefficients(matrix);
    if(sws_setColorspaceDetails(_scale,coefficients,frame->color_range==AVCOL_RANGE_JPEG,coefficients,1,0,1<<16,1<<16)<0)return nil;
    NSMutableData *pixels=[NSMutableData dataWithLength:w*h*4];
    uint8_t *out[4]={pixels.mutableBytes};int strides[4]={w*4};
    if(sws_scale(_scale,(const uint8_t *const *)frame->data,frame->linesize,0,frame->height,out,strides)!=h)return nil;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image=CGImageCreate(w,h,8,32,w*4,space,(CGBitmapInfo)((uint32_t)kCGBitmapByteOrder32Big|(uint32_t)kCGImageAlphaLast),
                                  provider,NULL,false,kCGRenderingIntentDefault);
    IIVELocalPreviewFrame *result=image?[[IIVELocalPreviewFrame alloc]initWithImage:image seconds:seconds]:nil;
    if(image)CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(space);return result;
}
- (IIVELocalPreviewFrame *)readPath:(NSString *)path seconds:(double)seconds {
    if(atomic_load(&_budget.canceled) || !isfinite(seconds) || seconds<0 || seconds>1e9 ||
       ![path hasPrefix:@"/"] || ![@[@"mkv",@"webm"] containsObject:path.pathExtension.lowercaseString])return nil;
    struct stat stamp;if(stat(path.fileSystemRepresentation,&stamp) || !S_ISREG(stamp.st_mode))return nil;
    _budget.deadline=av_gettime_relative()+2000000;
    if(![self openPath:path stamp:stamp])return nil;
    AVStream *stream=_format->streams[_stream];
    double start=_format->start_time!=AV_NOPTS_VALUE?(double)_format->start_time/AV_TIME_BASE:
        stream->start_time!=AV_NOPTS_VALUE?stream->start_time*av_q2d(stream->time_base):0;
    double target=(seconds+start)/av_q2d(stream->time_base);
    if(!isfinite(target) || target>=0x1p63 || target<=-0x1p63){[self close];return nil;}
    if(av_seek_frame(_format,_stream,(int64_t)floor(target),AVSEEK_FLAG_BACKWARD)<0){[self close];return nil;}
    avcodec_flush_buffers(_decoder);
    AVPacket *packet=av_packet_alloc();AVFrame *frame=av_frame_alloc();
    IIVELocalPreviewFrame *result=nil;bool eof=false;
    if(!packet || !frame)goto done;
    for(int count=0;count<4096 && !interrupted(&_budget);count++) {
        int status=avcodec_receive_frame(_decoder,frame);
        if(status==0) {
            int64_t pts=frame->best_effort_timestamp;
            double actual=pts==AV_NOPTS_VALUE?NAN:pts*av_q2d(stream->time_base)-start;
            if(isfinite(actual) && actual>=0 && actual+0.000001>=seconds) {
                if(actual-seconds<=1.75)result=[self imageFromFrame:frame seconds:actual];
                break;
            }
            av_frame_unref(frame);continue;
        }
        if(status!=AVERROR(EAGAIN) || eof)break;
        int read=av_read_frame(_format,packet);
        if(read<0) {eof=true;if(read==AVERROR_EOF)avcodec_send_packet(_decoder,NULL);else break;}
        else if(packet->stream_index==_stream && avcodec_send_packet(_decoder,packet)<0) {av_packet_unref(packet);break;}
        av_packet_unref(packet);
    }
done:
    av_packet_free(&packet);av_frame_free(&frame);
    if(interrupted(&_budget)){[self close];return nil;}
    if(!result)[self close];
    return result;
}
@end
