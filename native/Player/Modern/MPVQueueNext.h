// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <mpv/client.h>
#include <string.h>
// Client-queue only. Capture the live list after appends, then update its indices
// after each successful move. Lazy keys do not resolve download URLs here.
static NSArray<NSDictionary *> *iive_next_playlist(mpv_handle *mpv) {
    mpv_node node={0};
    if(mpv_get_property(mpv,"playlist",MPV_FORMAT_NODE,&node)<0)return nil;
    NSMutableArray *result=[NSMutableArray array];
    if(node.format==MPV_FORMAT_NODE_ARRAY)for(int i=0;i<node.u.list->num;i++) {
        mpv_node *entry=&node.u.list->values[i];if(entry->format!=MPV_FORMAT_NODE_MAP)continue;
        NSMutableDictionary *item=[NSMutableDictionary dictionary];
        for(int j=0;j<entry->u.list->num;j++) {
            const char *key=entry->u.list->keys[j];mpv_node *v=&entry->u.list->values[j];
            if(!strcmp(key,"filename") && v->format==MPV_FORMAT_STRING)item[@"filename"]=@(v->u.string);
            if(!strcmp(key,"id") && v->format==MPV_FORMAT_INT64)item[@"id"]=@(v->u.int64);
            if(!strcmp(key,"current") && v->format==MPV_FORMAT_FLAG)item[@"current"]=@(v->u.flag!=0);
        }
        [result addObject:item];
    }
    mpv_free_node_contents(&node);return result;
}
static int iive_queue_next(mpv_handle *mpv, NSArray<NSString *> *keys) {
    NSArray *initial=iive_next_playlist(mpv);if(!initial)return MPV_ERROR_GENERIC;
    NSNumber *anchor=nil;NSString *current=nil;
    NSMutableSet *known=[NSMutableSet set],*seen=[NSMutableSet set];NSMutableArray *selected=[NSMutableArray array];
    for(NSDictionary *item in initial) {
        if(item[@"filename"])[known addObject:item[@"filename"]];
        if([item[@"current"] boolValue]){anchor=item[@"id"];current=item[@"filename"];}
    }
    int idle=0;
    if(mpv_get_property(mpv,"idle-active",MPV_FORMAT_FLAG,&idle)>=0 && idle){anchor=nil;current=nil;}
    for(NSString *key in keys) {
        if(![key hasPrefix:@"iive-media://"] || [key isEqual:current] || [seen containsObject:key])continue;
        [seen addObject:key];
        if(![known containsObject:key]) {
            const char *args[]={"loadfile",key.UTF8String,"append",NULL};
            int status=mpv_command(mpv,args);
            if(status<0)return status;
            [known addObject:key];
        }
        [selected addObject:key];
    }
    NSMutableArray *list=[iive_next_playlist(mpv) mutableCopy];if(!list)return MPV_ERROR_GENERIC;
    for(NSString *key in selected.reverseObjectEnumerator) {
        NSInteger source=NSNotFound,anchorIndex=NSNotFound;
        for(NSUInteger i=0;i<list.count;i++) {
            if([list[i][@"filename"] isEqual:key])source=i;
            if(anchor && [list[i][@"id"] isEqual:anchor])anchorIndex=i;
        }
        if(source==NSNotFound || (anchor && anchorIndex==NSNotFound))return MPV_ERROR_GENERIC;
        NSInteger target=anchorIndex==NSNotFound?0:anchorIndex+1;
        if(source<target)target--;
        if(source==target)continue;
        NSString *from=@(source).stringValue,*to=@(source<target?target+1:target).stringValue;
        const char *args[]={"playlist-move",from.UTF8String,to.UTF8String,NULL};
        int status=mpv_command(mpv,args);if(status<0)return status;
        NSDictionary *moved=list[source];[list removeObjectAtIndex:source];[list insertObject:moved atIndex:target];
    }
    return 0;
}
