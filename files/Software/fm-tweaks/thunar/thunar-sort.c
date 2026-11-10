/* thunar-sort.c - standalone LD_PRELOAD for Thunar: Name/Type sorts go Folders > Hidden Folders > Files > Hidden Files; Size and Date sorts are left to Thunar.
   Extracted from hooks.c (sort block) for the Debian port; works on Thunar 4.20.x (Asahi: 4.20.9, user-confirmed).
   BUILD  gcc -shared -fPIC -o thunar-sort.so thunar-sort.c $(pkg-config --cflags glib-2.0 gio-2.0) -ldl
   RUN    LD_PRELOAD=$PWD/thunar-sort.so thunar      (restart Thunar by PID; `thunar -q` can leave the old process)
   TEST   mkdir t; cd t; mkdir b .a; touch c .d; open it in Thunar sorted by Name: expect b, .a, c, .d
   DEBUG  TSORT_DEBUG=1 prints each interposed call and why a row was skipped to stderr.
   If nothing changes: the usual cause is from_thunar() (caller path must contain "thunar" and not "libthunarx"); with TSORT_DEBUG=1 look at the printed dli_fname. */
#define _GNU_SOURCE
#include <glib.h>
#include <gio/gio.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char *thunarx_file_info_get_name(void *) __attribute__((weak));
extern int thunarx_file_info_is_directory(void *) __attribute__((weak));
extern int gtk_tree_sortable_get_sort_column_id(void *, int *, int *) __attribute__((weak));
typedef struct { GCompareDataFunc cmp; gpointer data; } SortWrap;
static int dbg(void) { static int d = -1; if (d < 0) d = getenv("TSORT_DEBUG") != NULL; return d; }

/* Thunar's list rows are structs whose FIRST field is the ThunarFile*; recognise one by comparing that object's class pointer (no blind GObject deref).
   Returns the group 0 folder, 1 hidden folder, 2 file, 3 hidden file, or -1 if the pointer is not a Thunar row. */
static int row_group(gconstpointer row) {
    static void *cls; static int init;
    if (!init) { GType tf = g_type_from_name("ThunarFile"); cls = tf ? g_type_class_peek(tf) : NULL; init = 1; if (dbg()) fprintf(stderr, "tsort: ThunarFile class %p\n", cls); }
    if (!cls || !row || !thunarx_file_info_get_name || !thunarx_file_info_is_directory) return -1;
    void *file = *(void *const *)row;
    if (!file || ((uintptr_t)file & 7) || *(void **)file != cls) return -1;
    char *n = thunarx_file_info_get_name(file);
    int h = n && n[0] == '.'; g_free(n);
    return (thunarx_file_info_is_directory(file) ? 0 : 2) + h;
}

static gint wrap_cmp(gconstpointer a, gconstpointer b, gpointer d) {
    SortWrap *w = d; int ga = row_group(a), gb = row_group(b), col, ord;
    /* Size (11/12) and the Date columns (0-3) sort purely by value, no grouping */
    int bysd = w->data && gtk_tree_sortable_get_sort_column_id && gtk_tree_sortable_get_sort_column_id(w->data, &col, &ord) && (col <= 3 || col == 11 || col == 12);
    if (!bysd && ga >= 0 && gb >= 0 && ga != gb) return ga < gb ? -1 : 1;
    return w->cmp(a, b, w->data);
}

/* only calls made by Thunar's own code (other libraries sort unrelated sequences) */
static int from_thunar(void *ra) {
    Dl_info di; int ok = dladdr(ra, &di) && di.dli_fname && strstr(di.dli_fname, "thunar") && !strstr(di.dli_fname, "libthunarx");
    if (dbg()) fprintf(stderr, "tsort: caller %s -> %s\n", di.dli_fname ? di.dli_fname : "?", ok ? "wrapped" : "passed through");
    return ok;
}
void g_sequence_sort(GSequence *s, GCompareDataFunc f, gpointer d) {
    static void (*real)(GSequence *, GCompareDataFunc, gpointer); if (!real) real = dlsym(RTLD_NEXT, "g_sequence_sort");
    if (!from_thunar(__builtin_return_address(0))) { real(s, f, d); return; }
    SortWrap w = { f, d }; real(s, wrap_cmp, &w);
}
GSequenceIter *g_sequence_insert_sorted(GSequence *s, gpointer data, GCompareDataFunc f, gpointer d) {
    static GSequenceIter *(*real)(GSequence *, gpointer, GCompareDataFunc, gpointer); if (!real) real = dlsym(RTLD_NEXT, "g_sequence_insert_sorted");
    if (!from_thunar(__builtin_return_address(0))) return real(s, data, f, d);
    SortWrap w = { f, d }; return real(s, data, wrap_cmp, &w);
}
void g_sequence_sort_changed(GSequenceIter *i, GCompareDataFunc f, gpointer d) {
    static void (*real)(GSequenceIter *, GCompareDataFunc, gpointer); if (!real) real = dlsym(RTLD_NEXT, "g_sequence_sort_changed");
    if (!from_thunar(__builtin_return_address(0))) { real(i, f, d); return; }
    SortWrap w = { f, d }; real(i, wrap_cmp, &w);
}
