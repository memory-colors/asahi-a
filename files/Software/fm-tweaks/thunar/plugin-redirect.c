/* Redirects Thunar's extension dir /usr/lib64/thunarx-3 to a private dir (Fedora builds ignore THUNARX_DIRS).
 * Build: gcc -shared -fPIC -O2 -o ~/.local/libexec/thunar-fm/plugin-redirect.so plugin-redirect.c -ldl
 * Env PLUGIN_REDIRECT_TO=<dir>. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#define SYS "/usr/lib64/thunarx-3"
static char *fix(const char *p){
  const char *to=getenv("PLUGIN_REDIRECT_TO"); char *r;
  if(!p||!to||strncmp(p,SYS,strlen(SYS))) return NULL;
  r=malloc(strlen(to)+strlen(p)); sprintf(r,"%s%s",to,p+strlen(SYS)); return r;
}
void *g_dir_open(const char *p,unsigned f,void **e){
  static void*(*real)(const char*,unsigned,void**); char*q=fix(p); void*v;
  if(!real) real=dlsym(RTLD_NEXT,"g_dir_open");
  v=real(q?q:p,f,e); free(q); return v;
}
void *g_module_open(const char *p,int f){
  static void*(*real)(const char*,int); char*q=fix(p); void*v;
  if(!real) real=dlsym(RTLD_NEXT,"g_module_open");
  v=real(q?q:p,f); free(q); return v;
}
