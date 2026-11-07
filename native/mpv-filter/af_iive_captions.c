/* SPDX-License-Identifier: GPL-3.0-or-later
 * Read-only audio tap. Playback frames pass through unchanged; only the side
 * branch is downmixed/resampled. A bounded queue is drained via af-metadata.
 */
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <libavutil/base64.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include "audio/aframe.h"
#include "common/common.h"
#include "common/tags.h"
#include "filters/filter_internal.h"
#include "filters/user_filters.h"

#define RATE 16000
#define CAPACITY (RATE * 2)
struct priv {
    SwrContext *swr;
    AVChannelLayout layout;
    int format, rate, count;
    float samples[CAPACITY];
    double pts, expected;
    uint64_t serial, dropped;
    const char *state;
};
static void reset(struct mp_filter *f) {
    struct priv *p=f->priv;
    swr_free(&p->swr); av_channel_layout_uninit(&p->layout);
    p->count=0; p->expected=MP_NOPTS_VALUE; p->serial++; p->state="waiting";
}
static void tap(struct mp_filter *f, struct mp_aframe *frame) {
    struct priv *p=f->priv;
    AVFrame *av=mp_aframe_get_raw_avframe(frame);
    double pts=mp_aframe_get_pts(frame);
    if (!av || pts==MP_NOPTS_VALUE || !isfinite(pts) || av->sample_rate<=0 ||
        !av_channel_layout_check(&av->ch_layout)) {p->state="unsupported-audio";return;}
    bool changed=p->swr && (p->format!=av->format || p->rate!=av->sample_rate ||
        av_channel_layout_compare(&p->layout,&av->ch_layout));
    if(changed || (p->expected!=MP_NOPTS_VALUE && fabs(pts-p->expected)>0.1))reset(f);
    p->expected=pts+(double)av->nb_samples/av->sample_rate;
    if(!p->swr) {
        AVChannelLayout mono=AV_CHANNEL_LAYOUT_MONO;
        if(swr_alloc_set_opts2(&p->swr,&mono,AV_SAMPLE_FMT_FLT,RATE,
            &av->ch_layout,av->format,av->sample_rate,0,NULL)<0 || swr_init(p->swr)<0) {
            swr_free(&p->swr);p->state="conversion-unavailable";return;
        }
        if(av_channel_layout_copy(&p->layout,&av->ch_layout)<0) {swr_free(&p->swr);return;}
        p->format=av->format;p->rate=av->sample_rate;
    }
    int needed=swr_get_out_samples(p->swr,av->nb_samples);
    if(needed<0 || needed>CAPACITY) {p->dropped++;reset(f);p->state="overrun";return;}
    if(p->count+needed>CAPACITY) {p->count=0;p->serial++;p->dropped++;}
    if(!p->count)p->pts=pts-(double)swr_get_delay(p->swr,av->sample_rate)/av->sample_rate;
    uint8_t *out=(uint8_t *)(p->samples+p->count);
    int n=swr_convert(p->swr,&out,CAPACITY-p->count,(const uint8_t **)av->extended_data,av->nb_samples);
    if(n<0) {reset(f);p->state="conversion-error";return;}
    p->count+=n;p->state="active";
}
static void process(struct mp_filter *f) {
    if(!mp_pin_can_transfer_data(f->ppins[1],f->ppins[0]))return;
    struct mp_frame frame=mp_pin_out_read(f->ppins[0]);
    if(frame.type==MP_FRAME_AUDIO)tap(f,frame.data);
    if(frame.type==MP_FRAME_EOF) {
        struct priv *p=f->priv;
        if(p->swr && p->count<CAPACITY) {
            uint8_t *out=(uint8_t *)(p->samples+p->count);
            if(!p->count)p->pts=p->expected-(double)swr_get_delay(p->swr,RATE)/RATE;
            int n=swr_convert(p->swr,&out,CAPACITY-p->count,NULL,0);
            if(n>0)p->count+=n;
        }
        p->state="finished";
    }
    // A recognition failure must never break or change playback audio.
    mp_pin_in_write(f->ppins[1],frame);
}
static bool command(struct mp_filter *f,struct mp_filter_command *cmd) {
    struct priv *p=f->priv;
    if(cmd->type==MP_FILTER_COMMAND_TEXT && !strcmp(cmd->cmd,"ack")) {
        unsigned long long serial;int count;char extra;
        if(!cmd->arg || sscanf(cmd->arg,"%llu:%d%c",&serial,&count,&extra)!=2 || count<0)return false;
        if(serial==p->serial && count<=p->count) {
            memmove(p->samples,p->samples+count,(p->count-count)*sizeof(float));
            p->count-=count;p->pts+=(double)count/RATE;
        }
        return true; // A reset may make an otherwise valid acknowledgment stale.
    }
    if(cmd->type!=MP_FILTER_COMMAND_GET_META)return false;
    struct mp_tags *tags=talloc_zero(NULL,struct mp_tags);
    mp_tags_set_str(tags,"state",p->state?p->state:"waiting");
    mp_tags_set_str(tags,"serial",mp_tprintf(32,"%llu",(unsigned long long)p->serial));
    mp_tags_set_str(tags,"dropped",mp_tprintf(32,"%llu",(unsigned long long)p->dropped));
    if(p->count) {
        int size=p->count*sizeof(float),capacity=AV_BASE64_SIZE(size);
        char *encoded=talloc_size(tags,capacity);
        if(encoded && av_base64_encode(encoded,capacity,(uint8_t *)p->samples,size)) {
            mp_tags_set_str(tags,"samples",mp_tprintf(32,"%d",p->count));
            mp_tags_set_str(tags,"pts",mp_tprintf(40,"%.9f",p->pts));
            mp_tags_set_str(tags,"pcm",encoded);
        }
        // Metadata reads are pure: mpv may query the same property multiple times
        // while converting its type. Only an explicit ACK consumes the samples.
    }
    *(struct mp_tags **)cmd->res=tags;return true;
}
static void destroy(struct mp_filter *f) {reset(f);}
static const struct mp_filter_info info={.name="iive-captions",.priv_size=sizeof(struct priv),
    .process=process,.reset=reset,.destroy=destroy,.command=command};
static struct mp_filter *create(struct mp_filter *parent,void *options) {
    talloc_free(options);
    struct mp_filter *f=mp_filter_create(parent,&info);if(!f)return NULL;
    mp_filter_add_pin(f,MP_PIN_IN,"in");mp_filter_add_pin(f,MP_PIN_OUT,"out");reset(f);return f;
}
const struct mp_user_filter_entry af_iive_captions={
    .desc={.name="iive-captions",.description="Bounded PCM side tap for local captions"},.create=create};
