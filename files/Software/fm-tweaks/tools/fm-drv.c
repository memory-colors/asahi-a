/* fm-drv.c - scripted Thunar driver for verification (LD_PRELOAD, dev only; NOT part of the setup).
   build: gcc -shared -fPIC -o drv.so fm-drv.c /usr/lib64/libgtk-3.so.0 /usr/lib64/libgdk-3.so.0 /usr/lib64/libglib-2.0.so.0 /usr/lib64/libgobject-2.0.so.0 /usr/lib64/libcairo.so.2
   run:   FM_LOG=out.log FM_STEPS="4000:expand:2;4500:vadj:x" LD_PRELOAD=$PWD/drv.so thunar-fm ~      (hooks.so is added by thunar-fm; steps are "ms:op[:a[:b[:c]]]")
   ops: press(x,y) motion(x,y,state) release(x,y) click(x,y in bin-window coords; sends a motion first, GTK needs the hover) key(keyval,state,keycode) sel(path) expand(path) scroll(px) vadj(label) count(label) shot(file) log(text) */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct { int type; void *window; signed char send_event; unsigned time; double x, y; double *axes; unsigned state; unsigned button; void *device; double x_root, y_root; } BEv;
extern void *gtk_tree_view_get_bin_window(void*), *gdk_seat_get_pointer(void*);
typedef struct { int type; void *window; signed char send_event; unsigned time; double x, y; double *axes; unsigned state; short is_hint; void *device; double x_root, y_root; } MEv;
typedef struct _GList { void *data; struct _GList *next; } GList;
typedef struct { int type; void *window; signed char send_event; unsigned time; unsigned state; unsigned keyval; int length; char *string; unsigned short hardware_keycode; unsigned char group; unsigned is_modifier; } KEv;
extern unsigned g_timeout_add(unsigned, int(*)(void*), void*);
extern GList *gtk_window_list_toplevels(void), *gtk_container_get_children(void*);
extern unsigned long gtk_container_get_type(void), gtk_tree_view_get_type(void);
extern int g_type_check_instance_is_a(void*, unsigned long), gtk_widget_get_mapped(void*), gtk_style_context_has_class(void*, const char*), gtk_tree_view_expand_row(void*, void*, int), gtk_widget_get_allocated_width(void*), gtk_widget_get_allocated_height(void*), gtk_tree_selection_count_selected_rows(void*);
extern void *gtk_widget_get_parent(void*), *gtk_widget_get_style_context(void*), *gtk_widget_get_window(void*), *gtk_tree_path_new_from_string(const char*), *gtk_tree_view_get_selection(void*), *gtk_scrolled_window_get_vadjustment(void*);
extern void gtk_tree_view_set_cursor(void*, void*, void*, int), gtk_widget_grab_focus(void*), gtk_widget_draw(void*, void*), gtk_adjustment_set_value(void*, double);
extern double gtk_adjustment_get_value(void*);
extern void *gdk_event_new(int), *g_object_ref(void*), *gdk_display_get_default(void), *gdk_display_get_default_seat(void*), *gdk_seat_get_keyboard(void*);
extern void gtk_main_do_event(void*), gdk_event_free(void*), gdk_event_set_device(void*, void*);
extern void *cairo_image_surface_create(int,int,int), *cairo_create(void*); extern int cairo_surface_write_to_png(void*, const char*);
static void *tv, *win; static FILE *lg;
static void find(void *w){
  if (g_type_check_instance_is_a(w, gtk_tree_view_get_type()) && gtk_widget_get_mapped(w)) { void*p=gtk_widget_get_parent(w); if(p&&gtk_style_context_has_class(gtk_widget_get_style_context(p),"standard-view")&&!tv) tv=w; }
  if (g_type_check_instance_is_a(w, gtk_container_get_type())) for (GList*l=gtk_container_get_children(w); l; l=l->next) find(l->data); }
static void refresh(void){ win=0; tv=0; for(GList*l=gtk_window_list_toplevels();l;l=l->next) if(gtk_style_context_has_class(gtk_widget_get_style_context(l->data),"thunar")) win=l->data; if(win) find(win); }
static void *vadj(void){ return gtk_scrolled_window_get_vadjustment(gtk_widget_get_parent(tv)); }
static int step(void *u){ char *s=strdup((char*)u); char *op=strtok(s,":"), *a=strtok(0,":"), *b=strtok(0,":"), *c=strtok(0,":"); refresh();
  if(!strcmp(op,"key")&&win){ for(int t=8;t<=9;t++){ KEv*e=gdk_event_new(t); e->window=g_object_ref(gtk_widget_get_window(win)); e->send_event=1; e->state=atoi(b); e->keyval=strtoul(a,0,0); e->hardware_keycode=c?atoi(c):0; gdk_event_set_device(e,gdk_seat_get_keyboard(gdk_display_get_default_seat(gdk_display_get_default()))); gtk_main_do_event(e); gdk_event_free(e);} }
  else if(!strcmp(op,"click")&&tv) { gtk_widget_grab_focus(tv); { MEv*m=gdk_event_new(3); m->window=g_object_ref(gtk_tree_view_get_bin_window(tv)); m->send_event=1; m->x=atof(a); m->y=atof(b); m->x_root=300; m->y_root=300; void*d=gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_display_get_default())); gdk_event_set_device(m,d); m->device=d; gtk_main_do_event(m); gdk_event_free(m); } for(int t=4;t<=7;t+=3){ BEv*e=gdk_event_new(t); e->window=g_object_ref(gtk_tree_view_get_bin_window(tv)); e->send_event=1; e->x=atof(a); e->y=atof(b); e->button=1; e->x_root=300; e->y_root=300; void*d=gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_display_get_default())); gdk_event_set_device(e,d); e->device=d; gtk_main_do_event(e); gdk_event_free(e);} }
  else if(!strcmp(op,"press")||!strcmp(op,"release")||!strcmp(op,"motion")) { if(tv){ int motion=!strcmp(op,"motion"); int t=motion?3:(!strcmp(op,"press")?4:7); gtk_widget_grab_focus(tv); void*d=gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_display_get_default()));
      if(motion){ MEv*m=gdk_event_new(3); m->window=g_object_ref(gtk_tree_view_get_bin_window(tv)); m->send_event=1; m->x=atof(a); m->y=atof(b); m->x_root=300; m->y_root=300; m->state=c?atoi(c):0; gdk_event_set_device(m,d); m->device=d; gtk_main_do_event(m); gdk_event_free(m); }
      else { BEv*e=gdk_event_new(t); e->window=g_object_ref(gtk_tree_view_get_bin_window(tv)); e->send_event=1; e->x=atof(a); e->y=atof(b); e->button=1; e->x_root=300; e->y_root=300; e->state=t==7?256:0; gdk_event_set_device(e,d); e->device=d; gtk_main_do_event(e); gdk_event_free(e); } } }
  else if(!strcmp(op,"sel")&&tv) { gtk_widget_grab_focus(tv); gtk_tree_view_set_cursor(tv,gtk_tree_path_new_from_string(a),0,0); }
  else if(!strcmp(op,"expand")&&tv) gtk_tree_view_expand_row(tv,gtk_tree_path_new_from_string(a),0);
  else if(!strcmp(op,"scroll")&&tv) gtk_adjustment_set_value(vadj(),atof(a));
  else if(!strcmp(op,"vadj")&&tv) fprintf(lg,"vadj=%.0f (%s)\n",gtk_adjustment_get_value(vadj()),a?a:"");
  else if(!strcmp(op,"count")&&tv) fprintf(lg,"selected=%d (%s)\n",gtk_tree_selection_count_selected_rows(gtk_tree_view_get_selection(tv)),a?a:"");
  else if(!strcmp(op,"shot")&&win) { int W=gtk_widget_get_allocated_width(win),H=gtk_widget_get_allocated_height(win); void*sf=cairo_image_surface_create(0,W,H); void*cr=cairo_create(sf); gtk_widget_draw(win,cr); cairo_surface_write_to_png(sf,a); fprintf(lg,"shot %s\n",a); }
  else if(!strcmp(op,"log")) fprintf(lg,"%s\n",a);
  fflush(lg); free(s); return 0; }
__attribute__((constructor)) static void init(void){ char b[256]={0}; readlink("/proc/self/exe",b,255); if(!strstr(b,"thunar")||!getenv("FM_STEPS")) return; lg=fopen(getenv("FM_LOG")?getenv("FM_LOG"):"/dev/null","w");
  char *all=strdup(getenv("FM_STEPS")); for(char*p=strtok(all,";");p;p=strtok(0,";")){ char*col=strchr(p,':'); if(!col) continue; *col=0; g_timeout_add(atoi(p),step,strdup(col+1)); } }
