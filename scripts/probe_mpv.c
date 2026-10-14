#include <stdio.h>
#include <mpv/client.h>
int main(void) {
 mpv_handle *m=mpv_create(); if(!m) return 1;
 mpv_set_option_string(m,"config","no"); mpv_set_option_string(m,"vo","null"); mpv_set_option_string(m,"ao","null");
 if(mpv_initialize(m)<0) return 2;
 const char *p[]={"mpv-version","ffmpeg-version","mpv-configuration","option-info/vf","option-info/glsl-shaders",NULL};
 for(int i=0;p[i];i++){char *v=mpv_get_property_string(m,p[i]); printf("%s: %s\n",p[i],v?v:"N/A");mpv_free(v);}
 const char *cmd[]={"vf","add","@probe:vapoursynth=~~/nonexistent.vpy",NULL}; printf("vapoursynth filter command result: %d\n",mpv_command(m,cmd));
 const char *mc[]={"vf","add","@probe:lavfi=[minterpolate=fps=48:mi_mode=mci]",NULL};printf("minterpolate filter command result: %d\n",mpv_command(m,mc));
 mpv_terminate_destroy(m);
}
