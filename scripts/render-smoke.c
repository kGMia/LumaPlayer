/* SPDX-License-Identifier: GPL-3.0-or-later
 * Offscreen libmpv OpenGL render-API smoke; not a display-FPS benchmark. */
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <dlfcn.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
static atomic_bool dirty = true;
static void wake(void *ctx) {atomic_store(&dirty, true);}
static void *resolve(void *ctx, const char *name) {return dlsym(RTLD_DEFAULT, name);}
int main(int argc, char **argv) {
 if (argc != 3) {fprintf(stderr,"usage: render-smoke input.mov 48|60\n");return 2;}
 CGLPixelFormatAttribute attrs[] = {kCGLPFAOpenGLProfile,(CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAccelerated,0};
 CGLPixelFormatObj format;GLint count;CGLContextObj gl;
 if(CGLChoosePixelFormat(attrs,&format,&count) || CGLCreateContext(format,NULL,&gl))return 3;
 CGLDestroyPixelFormat(format);CGLSetCurrentContext(gl);
 GLuint texture,fbo;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
 glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,1280,720,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
 glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
 glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
 if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)return 4;
 mpv_handle *m=mpv_create();
 mpv_set_option_string(m,"config","no");mpv_set_option_string(m,"vo","libmpv");
 mpv_set_option_string(m,"ao","null");mpv_set_option_string(m,"hwdec","no");
 mpv_set_option_string(m,"terminal","yes");mpv_set_option_string(m,"msg-level","iive-rife=v");
 char filter[100];snprintf(filter,sizeof(filter),"iive-rife=fps=%s:tier=fast:fallback=no",argv[2]);
 mpv_set_option_string(m,"vf",filter);
 if(mpv_initialize(m)<0)return 5;
 mpv_opengl_init_params init={.get_proc_address=resolve};
 mpv_render_param params[]={{MPV_RENDER_PARAM_API_TYPE,MPV_RENDER_API_TYPE_OPENGL},{MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&init},{0}};
 mpv_render_context *render;
 if(mpv_render_context_create(&render,m,params)<0)return 6;
 mpv_render_context_set_update_callback(render,wake,NULL);
 const char *cmd[]={"loadfile",argv[1],NULL};mpv_command(m,cmd);
 int renders=0,nonblack=0,success=0;
 for(int n=0;n<12000;n++) {
  mpv_event *ev=mpv_wait_event(m,0.005);
  if(ev->event_id==MPV_EVENT_END_FILE){success=((mpv_event_end_file*)ev->data)->reason==MPV_END_FILE_REASON_EOF;break;}
  if(atomic_exchange(&dirty,false) && (mpv_render_context_update(render)&MPV_RENDER_UPDATE_FRAME)) {
   mpv_opengl_fbo target={.fbo=(int)fbo,.w=1280,.h=720,.internal_format=GL_RGBA8};int block=0;
   mpv_render_param args[]={{MPV_RENDER_PARAM_OPENGL_FBO,&target},{MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},{0}};
   if(mpv_render_context_render(render,args)<0)break;
   glBindFramebuffer(GL_FRAMEBUFFER,fbo);unsigned char sample[4]={0};
   glReadPixels(320,180,1,1,GL_RGBA,GL_UNSIGNED_BYTE,sample);
   nonblack+=sample[0]+sample[1]+sample[2]>0;renders++;
   mpv_render_context_report_swap(render);
  }
 }
 printf("{\"kind\":\"offscreen_libmpv_opengl\",\"render_calls\":%d,\"nonblack_readbacks\":%d,\"eof\":%s,\"display_fps\":null}\n",renders,nonblack,success?"true":"false");
 mpv_render_context_free(render);mpv_terminate_destroy(m);
 glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&texture);CGLSetCurrentContext(NULL);CGLDestroyContext(gl);
 return success&&renders>0&&nonblack>0?0:7;
}
