/* Thunar-only label overrides (preloaded by thunar-fm): "File System" -> Computer, home folder display name (user name) -> Home. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <glib.h>
#include <gio/gio.h>
#include <unistd.h>

const gchar *g_dgettext(const gchar *domain, const gchar *msgid) {
    static const gchar *(*real)(const gchar *, const gchar *);
    if (!real) real = dlsym(RTLD_NEXT, "g_dgettext");
    if (msgid && !strcmp(msgid, "File System")) return "Computer";
    return real(domain, msgid);
}

const char *g_file_info_get_display_name(GFileInfo *info) {
    static const char *(*real)(GFileInfo *);
    if (!real) real = dlsym(RTLD_NEXT, "g_file_info_get_display_name");
    const char *n = real(info);
    if (n && !strcmp(n, g_get_user_name())) {
        const char *name = g_file_info_get_name(info);   /* basename: only the home folder has the user's name AND is called this... best effort */
        if (name && !strcmp(name, g_get_user_name()) && g_file_info_get_file_type(info) == G_FILE_TYPE_DIRECTORY) return "Home";
    }
    return n;
}

/* ---- Ctrl+Right = copy selection to the other split-view pane, Ctrl+Shift+Right = move ----
   Runs Thunar's own copy/cut -> switch pane -> paste -> switch back through its accelerators, so progress/conflict dialogs are Thunar's.
   Needs a split view (>=2 mapped file views) and focus in a file view (not the location entry), else the key falls through.
   Relies on accel <Primary>grave = ThunarWindow/switch-focused-split-view-pane (set in ~/.config/Thunar/accels.scm). */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
typedef struct { int type; void *window; signed char send_event; unsigned time; unsigned state; unsigned keyval; } KeyEv;
extern unsigned long gtk_container_get_type(void), gtk_tree_view_get_type(void), gtk_icon_view_get_type(void);
extern GList *gtk_window_list_toplevels(void);
extern GList *gtk_container_get_children(void *);
extern void *gtk_widget_get_parent(void *), *gtk_widget_get_style_context(void *), *gtk_window_get_focus(void *);
extern int gtk_style_context_has_class(void *, const char *), gtk_widget_get_mapped(void *), gtk_accel_groups_activate(void *, unsigned, unsigned);
extern unsigned gtk_accelerator_get_default_mod_mask(void);

static int is_view(void *w) {
    if (!w || !(g_type_check_instance_is_a((GTypeInstance *)w, gtk_tree_view_get_type()) || g_type_check_instance_is_a((GTypeInstance *)w, gtk_icon_view_get_type()))) return 0;
    void *p = gtk_widget_get_parent(w);
    return p && gtk_style_context_has_class(gtk_widget_get_style_context(p), "standard-view");
}
static int count_views(void *w) {
    int n = (is_view(w) && gtk_widget_get_mapped(w)) ? 1 : 0;
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_container_get_type()))
        for (GList *l = gtk_container_get_children(w); l; l = l->next) n += count_views(l->data);
    return n;
}
extern unsigned long gtk_toolbar_get_type(void);
extern void gtk_widget_set_visible(void *, int), gtk_widget_set_no_show_all(void *, int);
extern int gtk_widget_get_visible(void *);
static void *find_toolbar(void *w) {
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_toolbar_get_type())) return w;
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_container_get_type()))
        for (GList *l = gtk_container_get_children(w); l; l = l->next) { void *r = find_toolbar(l->data); if (r) return r; }
    return NULL;
}
/* DEBIAN: toolbar/location row is hidden when a window is first hooked; Ctrl+T toggles it.
   Thunar falls back to showing its menubar whenever the toolbar is hidden, so the menubar is hidden along with it. Ctrl+T's stock new-tab accel is cleared in accels.scm. */
extern unsigned long gtk_menu_bar_get_type(void);
static void *find_type(void *w, unsigned long t) {
    if (g_type_check_instance_is_a((GTypeInstance *)w, t)) return w;
    void *hit = NULL;
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_container_get_type())) {
        GList *kids = gtk_container_get_children(w);
        for (GList *l = kids; l && !hit; l = l->next) hit = find_type(l->data, t);
        g_list_free(kids);
    }
    return hit;
}
static void set_toolbar(void *win, int show) {
    void *tb = find_toolbar(win), *mb = find_type(win, gtk_menu_bar_get_type());
    if (!tb) return;
    gtk_widget_set_no_show_all(tb, 1);
    gtk_widget_set_visible(tb, show);
    if (mb) gtk_widget_set_visible(mb, 0);
}

/* ---- Shift+Up/Down/Home/End range select ----
   Thunar bug (upstream #1500): with "Expandable Folders" ON, Shift+Up/Down only moves the cursor. Done here with the selection API instead: keep an
   anchor row, select anchor..new in visible-row order (expanded children included). Only in the file list's GtkTreeView; the anchor is dropped as soon as
   the cursor is somewhere other than where we last put it (click, plain arrow, folder change). */
typedef struct { int stamp; void *u1, *u2, *u3; } TIter;
extern void *gtk_tree_view_get_model(void *), *gtk_tree_view_get_selection(void *), *gtk_tree_path_copy(const void *), *gtk_tree_row_reference_new(void *, void *), *gtk_tree_row_reference_get_path(void *);
extern void gtk_tree_view_get_cursor(void *, void **, void **), gtk_tree_view_set_cursor(void *, void *, void *, int), gtk_tree_path_free(void *), gtk_tree_path_append_index(void *, int),
            gtk_tree_selection_unselect_all(void *), gtk_tree_selection_select_range(void *, void *, void *), gtk_tree_row_reference_free(void *);
extern int gtk_tree_view_row_expanded(void *, void *), gtk_tree_path_down(void *), gtk_tree_path_next(void *), gtk_tree_path_prev(void *), gtk_tree_path_up(void *),
           gtk_tree_path_get_depth(void *), gtk_tree_path_compare(const void *, const void *), gtk_tree_model_get_iter(void *, TIter *, void *), gtk_tree_model_iter_n_children(void *, TIter *),
           gtk_tree_row_reference_valid(void *);
extern char *gtk_tree_path_to_string(void *), *gtk_tree_path_new_first(void);
static void *ext_anchor, *ext_tv; static char *ext_last;

static void *deepest_last(void *tv, void *m, void *p) {            /* last visible row at or under p */
    TIter it;
    while (gtk_tree_view_row_expanded(tv, p) && gtk_tree_model_get_iter(m, &it, p)) {
        int n = gtk_tree_model_iter_n_children(m, &it);
        if (n <= 0) break;
        void *q = gtk_tree_path_copy(p); gtk_tree_path_append_index(q, n - 1); gtk_tree_path_free(p); p = q;
    }
    return p;
}
static void *step_row(void *tv, void *m, void *cur, int down) {   /* next/previous visible row, or NULL */
    TIter it; void *q = gtk_tree_path_copy(cur);
    if (down) {
        if (gtk_tree_view_row_expanded(tv, q)) { void *c = gtk_tree_path_copy(q); gtk_tree_path_down(c); if (gtk_tree_model_get_iter(m, &it, c)) { gtk_tree_path_free(q); return c; } gtk_tree_path_free(c); }
        for (;;) {
            void *r = gtk_tree_path_copy(q); gtk_tree_path_next(r);
            if (gtk_tree_model_get_iter(m, &it, r)) { gtk_tree_path_free(q); return r; }
            gtk_tree_path_free(r);
            if (gtk_tree_path_get_depth(q) <= 1) { gtk_tree_path_free(q); return NULL; }
            gtk_tree_path_up(q);
        }
    }
    if (gtk_tree_path_prev(q)) return deepest_last(tv, m, q);
    if (gtk_tree_path_get_depth(q) > 1) { gtk_tree_path_up(q); return q; }
    gtk_tree_path_free(q); return NULL;
}
static int shift_extend(void *win, unsigned key) {
    void *tv = gtk_window_get_focus(win);
    if (!tv || !g_type_check_instance_is_a((GTypeInstance *)tv, gtk_tree_view_get_type()) || !is_view(tv)) return 0;
    void *m = gtk_tree_view_get_model(tv), *sel = gtk_tree_view_get_selection(tv), *cur = NULL; TIter it;
    if (!m) return 0;
    gtk_tree_view_get_cursor(tv, &cur, NULL);
    void *nw = NULL;
    if (key == 0xff50 || key == 0xff57) {                            /* Home / End */
        if (key == 0xff50) nw = gtk_tree_path_new_first();
        else { int n = gtk_tree_model_iter_n_children(m, NULL); if (n > 0) { void *t = gtk_tree_path_new_first(); for (int i = 1; i < n; i++) gtk_tree_path_next(t); nw = deepest_last(tv, m, t); } }
        if (!nw || !gtk_tree_model_get_iter(m, &it, nw)) { if (cur) gtk_tree_path_free(cur); return 1; }
        if (!cur) cur = gtk_tree_path_copy(nw);
    } else {
        if (!cur) return 0;
        nw = step_row(tv, m, cur, key == 0xff54);
        if (!nw) { gtk_tree_path_free(cur); return 1; }              /* already at the end: swallow the key like GTK would */
    }
    char *cs = gtk_tree_path_to_string(cur);
    if (!(ext_tv == tv && ext_last && !strcmp(ext_last, cs) && ext_anchor && gtk_tree_row_reference_valid(ext_anchor))) {
        if (ext_anchor) gtk_tree_row_reference_free(ext_anchor);
        ext_anchor = gtk_tree_row_reference_new(m, cur); ext_tv = tv;
    }
    g_free(cs);
    void *ap = gtk_tree_row_reference_get_path(ext_anchor);
    gtk_tree_view_set_cursor(tv, nw, NULL, 0);                      /* moves + scrolls (selects only the new row) ... */
    if (ap) {
        gtk_tree_selection_unselect_all(sel);
        if (gtk_tree_path_compare(ap, nw) <= 0) gtk_tree_selection_select_range(sel, ap, nw); else gtk_tree_selection_select_range(sel, nw, ap);   /* ... then the whole range */
        gtk_tree_path_free(ap);
    }
    g_free(ext_last); ext_last = gtk_tree_path_to_string(nw);
    gtk_tree_path_free(cur); gtk_tree_path_free(nw);
    return 1;
}
extern void *thunarx_file_info_get_location(void *);
static gboolean on_key(void *win, KeyEv *e, gpointer u) {
    if (e->type == 8 && (e->state & gtk_accelerator_get_default_mod_mask()) == (4 | 1) && (e->keyval | 0x20) == 0x6e) {   /* Ctrl+Shift+N = same prompt as right-click > New Folder */
        void *cur = NULL; g_object_get(win, "current-directory", &cur, NULL);
        GFile *loc = cur ? thunarx_file_info_get_location(cur) : NULL; char *dir = loc && g_file_is_native(loc) ? g_file_get_path(loc) : NULL;
        if (loc) g_object_unref(loc);
        if (cur) g_object_unref(cur);
        if (!dir) return FALSE;                                                      /* not a local folder: leave Thunar's own action */
        char *argv[] = { "env", "-u", "LD_PRELOAD", "GTK_THEME=fm-sample", g_build_filename(g_get_home_dir(), ".local/bin/fm-newitem", NULL), "dir", NULL };
        g_spawn_async(dir, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, NULL);
        g_free(argv[4]); g_free(dir);
        return TRUE;
    }
    if (e->type == 8 && (e->state & gtk_accelerator_get_default_mod_mask()) == 4 && (e->keyval | 0x20) == 0x74) {   /* Ctrl+T */
        void *tb = find_toolbar(win);
        if (!tb) return FALSE;
        set_toolbar(win, !gtk_widget_get_visible(tb));
        return TRUE;
    }
    if (e->type == 8 && (e->keyval == 0xff52 || e->keyval == 0xff54 || e->keyval == 0xff50 || e->keyval == 0xff57) && (e->state & gtk_accelerator_get_default_mod_mask()) == 1)
        return shift_extend(win, e->keyval) ? TRUE : FALSE;                          /* Shift+Up/Down/Home/End */
    if (e->type != 8 || (e->keyval != 0xff53 && e->keyval != 0xff09)) return FALSE;   /* Right / Tab */
    unsigned m = e->state & gtk_accelerator_get_default_mod_mask();
    if (e->keyval == 0xff09) {                                                      /* plain Tab in a file view = switch to the other split pane */
        if (m != 0 || !is_view(gtk_window_get_focus(win)) || count_views(win) < 2) return FALSE;
        gtk_accel_groups_activate(win, 0x60, 4);
        return TRUE;
    }
    int move = (m == (4 | 1));
    if (m != 4 && !move) return FALSE;                                             /* Ctrl or Ctrl+Shift only */
    void *before = gtk_window_get_focus(win);
    if (!is_view(before) || count_views(win) < 2) return FALSE;
    gtk_accel_groups_activate(win, move ? 0x78 : 0x63, 4);                         /* cut / copy */
    gtk_accel_groups_activate(win, 0x60, 4);                                       /* switch pane */
    if (gtk_window_get_focus(win) != before) {
        gtk_accel_groups_activate(win, 0x76, 4);                                   /* paste into the other pane */
        gtk_accel_groups_activate(win, 0x60, 4);                                   /* back to the original pane */
    }
    return TRUE;
}

/* ---- rounded row highlight ----
   GTK3 paints a tree row's selection/hover as one rectangle per COLUMN, so CSS cannot round the row ends. After the view has painted, mask the four outer
   corners of every selected / hovered row with the view background (a square minus a quarter circle). Each row rounds on its own.
   Rows end at the visible edge when the columns are wider than the pane. Radius: env FM_ROW_RADIUS (default 5); row gap: env FM_ROW_GAP (px per side, default 1). */
typedef struct { int x, y, w, h; } Rect;
typedef struct { double r, g, b, a; } RGBA;
extern int gtk_tree_view_get_visible_range(void *, void **, void **);
extern void gtk_tree_view_get_background_area(void *, void *, void *, Rect *), gtk_tree_view_convert_bin_window_to_widget_coords(void *, int, int, int *, int *),
            gtk_style_context_get_background_color(void *, int, RGBA *), gdk_window_get_device_position(void *, void *, int *, int *, unsigned *);
extern void *gtk_tree_view_get_bin_window(void *), *gdk_display_get_default(void), *gdk_display_get_default_seat(void *), *gdk_seat_get_pointer(void *);
extern int gtk_tree_selection_path_is_selected(void *, void *), gtk_tree_view_get_path_at_pos(void *, int, int, void **, void **, int *, int *), gtk_widget_get_allocated_width(void *);
extern void cairo_save(void *), cairo_restore(void *), cairo_translate(void *, double, double), cairo_scale(void *, double, double), cairo_move_to(void *, double, double), cairo_line_to(void *, double, double),
            cairo_arc_negative(void *, double, double, double, double, double), cairo_close_path(void *), cairo_set_source_rgba(void *, double, double, double, double), cairo_fill(void *), cairo_rectangle(void *, double, double, double, double);
static void corner(void *cr, double x, double y, double sx, double sy, double r) {
    cairo_save(cr); cairo_translate(cr, x, y); cairo_scale(cr, sx, sy);
    cairo_move_to(cr, 0, 0); cairo_line_to(cr, r, 0); cairo_arc_negative(cr, r, r, r, -1.5707963267949, 3.14159265358979); cairo_close_path(cr); cairo_fill(cr);
    cairo_restore(cr);
}
extern void *gtk_tree_view_get_expander_column(void *);
extern void gtk_tree_view_get_cell_area(void *, void *, void *, Rect *), gtk_style_context_save(void *), gtk_style_context_restore(void *), gtk_style_context_add_class(void *, const char *),
            gtk_style_context_set_state(void *, int), gtk_render_expander(void *, void *, double, double, double, double);
extern int gtk_tree_model_iter_has_child(void *, TIter *);
#ifndef CHEV_DX
#define CHEV_DX 17      /* expander cell: [cell_area.x - CHEV_DX, cell_area.x) - calibrated against the stock chevron's pixels */
#endif
static void mask_row(void *cr, void *tv, void *path, double r, int wwidth, int hovered) {
    Rect rc; int wx, wy; gtk_tree_view_get_background_area(tv, path, NULL, &rc);
    gtk_tree_view_convert_bin_window_to_widget_coords(tv, rc.x, rc.y, &wx, &wy);
    static double gap = -1; if (gap < 0) { const char *e = getenv("FM_ROW_GAP"); gap = e ? atof(e) : 1.0; if (gap > 4) gap = 4; }   /* px cut from the top AND bottom of every highlighted row: adjacent rows are 2*gap apart */
    double xl = 0, xr = wwidth, yt = wy, yb = wy + rc.h;   /* get_background_area(NULL column) gives x=0,w=0: a row spans the whole visible width */
    { Rect ca; gtk_tree_view_get_cell_area(tv, path, gtk_tree_view_get_expander_column(tv), &ca);   /* cell area starts at the folder icon, right of the chevron */
      if (ca.w > 0) { int cx, cy; gtk_tree_view_convert_bin_window_to_widget_coords(tv, ca.x, ca.y, &cx, &cy);
        double lx = cx - 1;                                                  /* highlight starts here = midpoint between the chevron's right edge and the icon (measured at depth 0 and 1) */
        if (lx > xl) {
            cairo_rectangle(cr, xl, yt, lx - xl, rc.h); cairo_fill(cr); xl = lx;
            /* the fill also wiped the row's chevron: draw it again with the theme's own expander renderer */
            void *m = gtk_tree_view_get_model(tv); TIter it;
            if (m && gtk_tree_model_get_iter(m, &it, path) && gtk_tree_model_iter_has_child(m, &it)) {
                void *ctx = gtk_widget_get_style_context(tv);
                int fl = (gtk_tree_view_row_expanded(tv, path) ? 2048 : 0) | (gtk_tree_selection_path_is_selected(gtk_tree_view_get_selection(tv), path) ? 4 : 0) | (hovered ? 2 : 0);
                gtk_style_context_save(ctx); gtk_style_context_add_class(ctx, "expander"); gtk_style_context_set_state(ctx, fl | 128);
                gtk_render_expander(ctx, cr, cx - CHEV_DX, yt, CHEV_DX, rc.h);
                gtk_style_context_restore(ctx);
            } } } }
    if (gap > 0) { cairo_rectangle(cr, xl, yt, xr - xl, gap); cairo_rectangle(cr, xl, yb - gap, xr - xl, gap); cairo_fill(cr); yt += gap; yb -= gap; }
    if (xr - xl < 2 * r || yb - yt < 2 * r) return;
    corner(cr, xl, yt, 1, 1, r); corner(cr, xr, yt, -1, 1, r); corner(cr, xl, yb, 1, -1, r); corner(cr, xr, yb, -1, -1, r);
}
static gboolean on_draw_rows(void *tv, void *cr, gpointer u) {
    void *s0 = NULL, *e0 = NULL;
    if (!gtk_tree_view_get_visible_range(tv, &s0, &e0) || !s0 || !e0) { if (s0) gtk_tree_path_free(s0); if (e0) gtk_tree_path_free(e0); return FALSE; }
    static double radius; if (radius == 0) { const char *e = getenv("FM_ROW_RADIUS"); radius = e ? atof(e) : 5.0; if (radius < 0.5) radius = 0.5; }
    void *m = gtk_tree_view_get_model(tv), *sel = gtk_tree_view_get_selection(tv);
    RGBA bg; gtk_style_context_get_background_color(gtk_widget_get_style_context(tv), 0, &bg);
    int ww = gtk_widget_get_allocated_width(tv), hx = 0, hy = 0; unsigned mk; void *hp = NULL, *bw = gtk_tree_view_get_bin_window(tv);
    if (bw) { gdk_window_get_device_position(bw, gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_display_get_default())), &hx, &hy, &mk);
              if (hx < 0 || hx > ww || !gtk_tree_view_get_path_at_pos(tv, hx, hy, &hp, NULL, NULL, NULL)) hp = NULL; }
    cairo_save(cr); cairo_set_source_rgba(cr, bg.r, bg.g, bg.b, 1.0);
    void *p = s0; s0 = NULL;
    for (int guard = 0; p && guard < 400; guard++) {
        if (gtk_tree_selection_path_is_selected(sel, p) || (hp && !gtk_tree_path_compare(p, hp))) mask_row(cr, tv, p, radius, ww, hp && !gtk_tree_path_compare(p, hp));
        if (gtk_tree_path_compare(p, e0) >= 0) { gtk_tree_path_free(p); p = NULL; break; }
        void *n = step_row(tv, m, p, 1); gtk_tree_path_free(p); p = n;
    }
    if (p) gtk_tree_path_free(p);
    cairo_restore(cr);
    if (hp) gtk_tree_path_free(hp);
    gtk_tree_path_free(e0);
    return FALSE;
}

/* ---- keep the scroll position when a folder is expanded ----
   Expanding a row (with the view scrolled down) snapped it to the top. Remember the vertical scroll value when expansion starts; if the view is at 0 afterwards while it was
   scrolled before, put it back (right away and a few times over ~0.7 s, since Thunar loads the children asynchronously). Only a jump to the very top is undone. */
extern void *gtk_scrolled_window_get_vadjustment(void *);
extern double gtk_adjustment_get_value(void *), gtk_adjustment_get_upper(void *), gtk_adjustment_get_page_size(void *);
extern void gtk_adjustment_set_value(void *, double);
extern unsigned g_timeout_add(unsigned, int (*)(void *), void *);
static void *scroll_adj(void *tv) { void *p = gtk_widget_get_parent(tv); return p ? gtk_scrolled_window_get_vadjustment(p) : NULL; }
static gboolean on_test_expand(void *tv, void *iter, void *path, gpointer u) {
    void *adj = scroll_adj(tv); if (adj) { double *v = g_object_get_data(tv, "fm-scroll"); if (!v) { v = g_new0(double, 1); g_object_set_data_full(tv, "fm-scroll", v, g_free); } *v = gtk_adjustment_get_value(adj); }
    return FALSE;
}
typedef struct { void *tv; double want; } Restore;
static gboolean do_restore(gpointer d) {
    Restore *r = d; void *adj = scroll_adj(r->tv);
    if (adj && r->want > 1 && gtk_adjustment_get_value(adj) < 1) {
        double max = gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj); gtk_adjustment_set_value(adj, r->want < max ? r->want : max); }
    g_free(r); return FALSE;
}
static void on_row_expanded(void *tv, void *iter, void *path, gpointer u) {
    double *v = g_object_get_data(tv, "fm-scroll"); if (!v || *v < 1) return;
    static const unsigned delays[] = { 0, 40, 120, 250, 450, 700 };
    for (int i = 0; i < 6; i++) { Restore *r = g_new(Restore, 1); r->tv = tv; r->want = *v; g_timeout_add(delays[i], (int (*)(void *))do_restore, r); }
}

/* ---- rubber band from the blank part of the Name cell ----
   In the list view a press anywhere inside the Name cell (even the empty space right of the file name) selects that row and starts a file DRAG, so you can't lasso several
   files with the trackpad; a press in any other column already rubber-bands. Make a press in the blank part of the Name cell behave like one in the next column:
   move the event's x into that column before GTK's own handler sees it. Blank = right of the name text, or left of the chevron (indentation / left padding). The chevron, icon and name
   itself are untouched (expand / select / drag as before). The rubber band's drawn start corner is the shifted x, a cosmetic quirk; the selection is row-based so it still selects the right rows. */
typedef struct { int type; void *window; signed char send_event; unsigned time; double x, y; double *axes; unsigned state, button; } PressEv;
extern void *gtk_tree_view_get_columns(void *), *gtk_cell_layout_get_cells(void *), *gtk_widget_create_pango_layout(void *, const char *);
extern void pango_layout_get_pixel_size(void *, int *, int *);
extern unsigned long gtk_cell_renderer_text_get_type(void);
extern void gtk_tree_view_column_cell_set_cell_data(void *, void *, TIter *, int, int), gtk_tree_view_column_cell_get_position(void *, void *, int *, int *), gtk_cell_renderer_get_preferred_width(void *, void *, int *, int *);
static gboolean on_press_blank_name(void *tv, void *ev, gpointer u) {
    PressEv *e = ev; void *path = NULL, *col = NULL; int cx, cy, ok = 0;
    if (e->type != 4 /* GDK_BUTTON_PRESS */ || e->window != gtk_tree_view_get_bin_window(tv)) return FALSE;
    if (!gtk_tree_view_get_path_at_pos(tv, (int)e->x, (int)e->y, &path, &col, &cx, &cy)) return FALSE;
    GList *cols = gtk_tree_view_get_columns(tv); GList *first = cols;
    if (col && first && first->data == col && first->next) {
        void *next = first->next->data, *m = gtk_tree_view_get_model(tv); TIter it; Rect ca, na;
        if (gtk_tree_model_get_iter(m, &it, path)) {
            gtk_tree_view_column_cell_set_cell_data(col, m, &it, 0, 0);
            int text_end = -1;
            for (GList *c = gtk_cell_layout_get_cells(col); c; c = c->next) {
                if (!g_type_check_instance_is_a((GTypeInstance *)c->data, gtk_cell_renderer_text_get_type())) continue;
                int off = 0, w = 0, mn = 0, nat = 0; gtk_tree_view_column_cell_get_position(col, c->data, &off, &w);
                gtk_cell_renderer_get_preferred_width(c->data, tv, &mn, &nat);
                gtk_tree_view_get_cell_area(tv, path, col, &ca);
                char *txt = NULL; g_object_get(c->data, "text", &txt, NULL);
                int tw = nat < w ? nat : w;
                if (txt) { void *lay = gtk_widget_create_pango_layout(tv, txt); int pw = 0, ph = 0; pango_layout_get_pixel_size(lay, &pw, &ph); g_object_unref(lay); if (pw + 8 < tw) tw = pw + 8; g_free(txt); }
                text_end = ca.x + off + tw;
            }
            gtk_tree_view_get_cell_area(tv, path, next, &na);
            if (text_end > 0 && na.w > 8 && ((int)e->x > text_end + 6 || (int)e->x < ca.x - CHEV_DX)) { e->x = na.x + 4; ok = 1; }
        }
    }
    g_list_free(cols); gtk_tree_path_free(path); (void)ok;
    return FALSE;
}
extern unsigned long gtk_widget_get_type(void);
/* emission hooks run before every handler (Thunar's own press handler included) */
/* ---- slow second click on the name of the only selected row = inline rename (like Nautilus). Armed from the press hook (selection state is still pre-click there); fires after the
   double-click interval unless another press / a drag-begin bumped rn_gen. Thunar's name renderer is not editable by default, so it is flipped on for the one edit and back off after. ---- */
extern int gtk_tree_selection_count_selected_rows(void *);
extern void *gtk_settings_get_default(void);
extern void gtk_tree_row_reference_free(void *);
static unsigned rn_gen;
static void sb_record(void *tv, void *ev); static void hook_sidebar(void *w);
static gint64 sb_press_us; static void *sb_press_view;   /* last right-click in the sidebar (the sidebar's menu is Thunar's general file menu with no attach widget) */
typedef struct { void *tv; void *ref; unsigned gen; } RnJob;
extern int gtk_tree_model_get_iter_from_string(void *, TIter *, const char *);
extern int gtk_tree_model_get_n_columns(void *);
extern unsigned long gtk_tree_model_get_column_type(void *, int);
extern void gtk_tree_model_get_value(void *, TIter *, int, GValue *);
extern void *thunarx_file_info_get_location(void *);
/* ---- after an inline rename the row re-sorts to its new place, usually off-screen, and Thunar does not follow it: the file looks like it vanished until the folder is re-entered. Once the model reports
   the renamed row (row-changed / rows-reordered, event driven), select it and scroll it into view. ---- */
extern char *thunarx_file_info_get_name(void *) __attribute__((weak));
extern int gtk_tree_model_iter_next(void *, TIter *);
extern int gtk_tree_model_get_iter_first(void *, TIter *);
extern void gtk_tree_selection_select_path(void *, void *);
extern void *gtk_tree_model_get_path(void *, TIter *);
static char *rn_want, *rn_want_last; static void *rn_want_tv, *rn_want_model; static int rn_want_idle;
extern void gtk_tree_view_convert_bin_window_to_tree_coords(void *, int, int, int *, int *);
extern void *gtk_scrollable_get_vadjustment(void *), *gtk_scrollable_get_hadjustment(void *);
/* gtk_tree_view_scroll_to_cell() goes through a row reference that does not survive Thunar's reorder events (it landed ~30 rows short), so move the adjustment directly. */
static void rn_reveal_scroll(void *tv, void *path) {
    Rect r; int tx, ty; gtk_tree_view_get_background_area(tv, path, NULL, &r); gtk_tree_view_convert_bin_window_to_tree_coords(tv, 0, r.y, &tx, &ty);
    void *adj = gtk_scrollable_get_vadjustment(tv); double v = gtk_adjustment_get_value(adj), page = gtk_adjustment_get_page_size(adj);
    if (ty < v) gtk_adjustment_set_value(adj, ty); else if (ty + r.h > v + page) gtk_adjustment_set_value(adj, ty + r.h - page);
    /* the Name column never shrinks after a long name is renamed short, so a view that was scrolled right keeps its offset and the start of the new name sits off the left edge: snap back to the left */
    void *hadj = gtk_scrollable_get_hadjustment(tv);
    if (hadj && gtk_adjustment_get_value(hadj) > 0) gtk_adjustment_set_value(hadj, 0);
}
static void rn_reveal_stop(void) {
    if (rn_want_model) { g_signal_handlers_disconnect_matched(rn_want_model, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, &rn_want); g_object_remove_weak_pointer(rn_want_model, &rn_want_model); }
    g_free(rn_want); rn_want = NULL; g_free(rn_want_last); rn_want_last = NULL; rn_want_tv = NULL; rn_want_model = NULL;
}
static gboolean rn_reveal_idle(gpointer d) {
    rn_want_idle = 0;
    if (!rn_want || !rn_want_tv || !rn_want_model) return G_SOURCE_REMOVE;
    void *m = rn_want_model; int fcol = -1; TIter it;
    for (int i = 0, n = gtk_tree_model_get_n_columns(m); i < n; i++) if (!strcmp(g_type_name(gtk_tree_model_get_column_type(m, i)), "ThunarFile")) fcol = i;
    if (fcol < 0 || !thunarx_file_info_get_name || !gtk_tree_model_get_iter_first(m, &it)) return G_SOURCE_REMOVE;
    do {
        GValue v = G_VALUE_INIT; gtk_tree_model_get_value(m, &it, fcol, &v);
        void *f = G_VALUE_HOLDS_OBJECT(&v) ? g_value_get_object(&v) : NULL; char *n = f ? thunarx_file_info_get_name(f) : NULL; int hit = n && !strcmp(n, rn_want); g_free(n); g_value_unset(&v);
        if (hit) {
            void *path = gtk_tree_model_get_path(m, &it), *sel = gtk_tree_view_get_selection(rn_want_tv);
            char *ps = gtk_tree_path_to_string(path);
            /* the model re-sorts in several steps: follow the row until an event leaves its position unchanged */
            if (rn_want_last && !strcmp(rn_want_last, ps)) { g_free(ps); gtk_tree_path_free(path); rn_reveal_stop(); break; }
            g_free(rn_want_last); rn_want_last = ps;
            gtk_tree_selection_unselect_all(sel); gtk_tree_selection_select_path(sel, path);
            rn_reveal_scroll(rn_want_tv, path);
            gtk_tree_path_free(path); break;
        }
    } while (gtk_tree_model_iter_next(m, &it));
    return G_SOURCE_REMOVE;
}
static void rn_reveal_kick(void) { if (!rn_want_idle) { rn_want_idle = 1; g_idle_add(rn_reveal_idle, NULL); } }
static void rn_reveal_changed(void *m, void *p, TIter *it, gpointer u) { rn_reveal_kick(); }
static void rn_reveal_reordered(void *m, void *p, TIter *it, void *o, gpointer u) { rn_reveal_kick(); }
static void rn_reveal_arm(void *tv, const char *name) {
    void *m = gtk_tree_view_get_model(tv); rn_reveal_stop();
    if (!m) return;
    rn_want = g_strdup(name); rn_want_tv = tv; rn_want_model = m; g_object_add_weak_pointer(m, &rn_want_model);
    g_signal_connect_data(m, "row-changed", G_CALLBACK(rn_reveal_changed), &rn_want, NULL, 0);
    g_signal_connect_data(m, "rows-reordered", G_CALLBACK(rn_reveal_reordered), &rn_want, NULL, 0);
    g_signal_connect_data(m, "row-inserted", G_CALLBACK(rn_reveal_changed), &rn_want, NULL, 0);
}
/* Thunar's file views have no "edited" handler (its own rename is a dialog), so the commit is done here: rename through GIO, the file monitor refreshes the row. */
static void rn_done(void *r, const char *pathstr, const char *text, gpointer b) {
    g_object_set(r, "editable", FALSE, NULL);
    void *tv = g_object_get_data(r, "fm-rn-tv"); void *m = tv ? gtk_tree_view_get_model(tv) : NULL; TIter it;
    if (!m || !text || !*text || strchr(text, '/') || !gtk_tree_model_get_iter_from_string(m, &it, pathstr)) return;
    for (int i = 0, n = gtk_tree_model_get_n_columns(m); i < n; i++) if (!strcmp(g_type_name(gtk_tree_model_get_column_type(m, i)), "ThunarFile")) {
        GValue v = G_VALUE_INIT; gtk_tree_model_get_value(m, &it, i, &v);
        void *file = G_VALUE_HOLDS_OBJECT(&v) ? g_value_get_object(&v) : NULL; GFile *loc = file ? thunarx_file_info_get_location(file) : NULL;
        if (loc) {
            char *old = g_file_get_basename(loc);
            if (old && strcmp(old, text)) { GError *e = NULL; GFile *nf = g_file_set_display_name(loc, text, NULL, &e); if (nf) { g_object_unref(nf); rn_reveal_arm(tv, text); } else { g_warning("rename failed: %s", e->message); g_error_free(e); } }
            g_free(old); g_object_unref(loc);
        }
        g_value_unset(&v); break;
    }
}
static void rn_done2(void *r, gpointer b) { g_object_set(r, "editable", FALSE, NULL); }
static int rn_ours;
extern void gtk_editable_set_position(void *, int), gtk_editable_select_region(void *, int, int);
extern const char *gtk_entry_get_text(void *);
extern void gtk_style_context_remove_provider(void *, void *), gtk_style_context_add_provider(void *, void *, unsigned), gtk_style_context_get_border(void *, int, void *), gtk_widget_get_allocation(void *, Rect *);
extern void *gtk_css_provider_new(void), *gtk_tree_path_new_from_string(const char *);
extern int thunarx_file_info_is_directory(void *);
extern void gtk_widget_queue_draw(void *), gtk_widget_queue_resize(void *);
extern int gtk_css_provider_load_from_data(void *, const char *, long, void **), gtk_widget_get_state_flags(void *);
extern void gtk_cell_renderer_get_padding(void *, int *, int *), gtk_tree_view_column_focus_cell(void *, void *);
/* is the row at this path a folder (the whole name is selected for folders, only the base name for files) */
static int rn_is_dir(void *tv, const char *ps) {
    void *m = gtk_tree_view_get_model(tv); TIter it; int dir = 0;
    if (!m || !gtk_tree_model_get_iter_from_string(m, &it, ps)) return 0;
    for (int i = 0, n = gtk_tree_model_get_n_columns(m); i < n; i++) if (!strcmp(g_type_name(gtk_tree_model_get_column_type(m, i)), "ThunarFile")) {
        GValue v = G_VALUE_INIT; gtk_tree_model_get_value(m, &it, i, &v);
        void *f = G_VALUE_HOLDS_OBJECT(&v) ? g_value_get_object(&v) : NULL; dir = f && thunarx_file_info_is_directory(f); g_value_unset(&v); break;
    }
    return dir;
}
/* Where GTK puts the editor: x = name text x (cell_area.x + renderer offset), width = cell_area.w - offset, BUT when that would overhang the visible part of the view (view narrower than the Name column) GTK slides it left until
   its right edge fits, down to the view's left edge. There it covers the icon and its text is no longer under the neighbouring names. Predict that x at "editing-started" (before the first draw, so nothing flashes) and make the
   entry's own left padding cover the difference; the part of the entry over the icon cell is transparent so the icon stays visible. rn_align (first real allocation) only re-applies if the prediction was wrong. */
static void rn_apply(void *ent, int x_actual) {
    void *tv = g_object_get_data(ent, "fm-rn-tv"), *r = g_object_get_data(ent, "fm-rn-r"); const char *ps = g_object_get_data(ent, "fm-rn-path");
    void *path = ps ? gtk_tree_path_new_from_string(ps) : NULL; GList *cols = tv ? gtk_tree_view_get_columns(tv) : NULL;
    if (path && cols && r) {
        Rect ca; int off = 0, w = 0, xp = 0, yp = 0; short bd[4] = {0, 0, 0, 0};          /* GtkBorder: left, right, top, bottom */
        gtk_tree_view_get_cell_area(tv, path, cols->data, &ca);                            /* starts at this row's icon (depth/chevron already included) */
        gtk_tree_view_column_cell_get_position(cols->data, r, &off, &w); gtk_cell_renderer_get_padding(r, &xp, &yp);
        int x = x_actual;
        if (x < 0) {
            void *ha = gtk_scrollable_get_hadjustment(tv); double hv = ha ? gtk_adjustment_get_value(ha) : 0, page = ha ? gtk_adjustment_get_page_size(ha) : 1e9;
            x = ca.x + off; int ew = ca.w - off;
            if (x + ew > hv + page) { x = (int)(hv + page) - ew; if (x < hv) x = (int)hv; }
        }
        void *ctx = gtk_widget_get_style_context(ent); gtk_style_context_get_border(ctx, gtk_widget_get_state_flags(ent), bd);
        int pad = ca.x + off + xp - x - bd[0]; if (pad < 0) pad = 0;
        if (pad != GPOINTER_TO_INT(g_object_get_data(ent, "fm-rn-pad")) + 0 || !g_object_get_data(ent, "fm-rn-prov")) {
            void *old = g_object_get_data(ent, "fm-rn-prov"); if (old) { gtk_style_context_remove_provider(ctx, old); g_object_unref(old); g_object_set_data(ent, "fm-rn-prov", NULL); }
            if (pad > 0) { char css[192]; void *cp = gtk_css_provider_new();
                g_snprintf(css, sizeof css, "entry { padding-left: %dpx; background-color: transparent; background-image: linear-gradient(to right, transparent %dpx, @view_bg_color %dpx); }", pad, pad + bd[0], pad + bd[0]);
                gtk_css_provider_load_from_data(cp, css, -1, NULL); gtk_style_context_add_provider(ctx, cp, 601); g_object_set_data(ent, "fm-rn-prov", cp);   /* keeps the one reference */ }
            g_object_set_data(ent, "fm-rn-pad", GINT_TO_POINTER(pad));
            if (x_actual >= 0) { gtk_widget_queue_resize(ent); gtk_widget_queue_draw(ent); gtk_widget_queue_draw(tv); }   /* a late correction needs its own repaint */
        }
    }
    g_list_free(cols); if (path) gtk_tree_path_free(path);
}
static void rn_align(void *ent, void *alloc, gpointer u) {
    void *tv = g_object_get_data(ent, "fm-rn-tv"); const char *ps = g_object_get_data(ent, "fm-rn-path");
    if (!tv || !ps || g_object_get_data(ent, "fm-rn-aligned")) return;
    g_object_set_data(ent, "fm-rn-aligned", (gpointer)1);
    Rect al; gtk_widget_get_allocation(ent, &al); rn_apply(ent, al.x);                       /* no-op when the prediction was right */
    const char *t = gtk_entry_get_text(ent); const char *dot = t ? strrchr(t, '.') : NULL;
    int pos = (dot && dot != t) ? (int)g_utf8_pointer_to_offset(t, dot) : -1;
    /* select the base name (the whole name for folders); typing replaces it, Right collapses the selection to its end and further Right moves into the extension. The insertion point stays at the START: GtkEntry scrolls to keep it visible, so an insertion point at the end scrolled a long name left by several characters (the original "name shifts left" symptom). */
    gtk_editable_select_region(ent, rn_is_dir(tv, ps) ? -1 : pos, 0);   /* (start, end): the insertion point is END = 0 */
}
extern int gtk_widget_get_realized(void *);
static gboolean rn_select_new_idle(gpointer d) {                                          /* one idle after the first allocation: GTK / Thunar finish placing the cursor first */
    void *ent = d;
    if (gtk_widget_get_realized(ent)) {
        const char *t = gtk_entry_get_text(ent); const char *dot = t ? strrchr(t, '.') : NULL;
        gtk_editable_select_region(ent, (dot && dot != t) ? (int)g_utf8_pointer_to_offset(t, dot) : -1, 0);
    }
    g_object_unref(ent); return G_SOURCE_REMOVE;
}
static void rn_select_new(void *ent, void *alloc, gpointer u) {
    if (g_object_get_data(ent, "fm-rn-sel")) return;
    g_object_set_data(ent, "fm-rn-sel", (gpointer)1); g_idle_add(rn_select_new_idle, g_object_ref(ent));
}
static void rn_started(void *r, void *ent, const char *path, gpointer u) {
    if (rn_ours && G_TYPE_CHECK_INSTANCE_TYPE(ent, g_type_from_name("GtkEntry"))) {
        g_object_set_data(ent, "fm-rn-tv", g_object_get_data(r, "fm-rn-tv")); g_object_set_data(ent, "fm-rn-r", r); g_object_set_data_full(ent, "fm-rn-path", g_strdup(path), g_free);
        rn_apply(ent, -1);                                                                   /* predicted placement, before the first draw */
        g_signal_connect_after(ent, "size-allocate", G_CALLBACK(rn_align), NULL);
    } else if (G_TYPE_CHECK_INSTANCE_TYPE(ent, g_type_from_name("GtkEntry")))
        g_signal_connect_after(ent, "size-allocate", G_CALLBACK(rn_select_new), NULL);   /* Thunar's own edit (right-click New File / New Folder): select the whole base name */
    rn_ours = 0;
}
static gboolean rn_fire(gpointer d) {
    RnJob *j = d;
    if (j->gen == rn_gen) {
        void *path = gtk_tree_row_reference_get_path(j->ref);
        if (path) {
            if (gtk_tree_selection_path_is_selected(gtk_tree_view_get_selection(j->tv), path) && gtk_tree_selection_count_selected_rows(gtk_tree_view_get_selection(j->tv)) == 1) {
                GList *cols = gtk_tree_view_get_columns(j->tv);
                if (cols) {
                    void *col = cols->data;
                    for (GList *c = gtk_cell_layout_get_cells(col); c; c = c->next)
                        if (g_type_check_instance_is_a((GTypeInstance *)c->data, gtk_cell_renderer_text_get_type())) {
                            g_object_set(c->data, "editable", TRUE, NULL); g_object_set_data(c->data, "fm-rn-tv", j->tv);
                            if (!g_object_get_data(c->data, "fm-rn")) {
                                g_object_set_data(c->data, "fm-rn", (gpointer)1);
                                g_signal_connect(c->data, "edited", G_CALLBACK(rn_done), NULL);
                                g_signal_connect(c->data, "editing-canceled", G_CALLBACK(rn_done2), NULL);
                                g_signal_connect_after(c->data, "editing-started", G_CALLBACK(rn_started), NULL);
                            }
                            rn_ours = 1;
                            gtk_tree_view_column_focus_cell(col, c->data);   /* GTK edits the FOCUS cell; a remapped click may have focused the icon cell */
                            gtk_tree_view_set_cursor(j->tv, path, col, TRUE);
                            break;
                        }
                    g_list_free(cols);
                }
            }
            gtk_tree_path_free(path);
        }
    }
    gtk_tree_row_reference_free(j->ref); g_free(j); return G_SOURCE_REMOVE;
}
static void rn_bump(void *w, gpointer a) { rn_gen++; }
static int rn_any;   /* set by row_click: the press was remapped onto the selected row, arm the rename even though x is not on the text */
static void rn_arm(void *tv, PressEv *e) {
    void *path = NULL, *col = NULL; int cx, cy;
    rn_gen++;
    if (e->type != 4 || e->button != 1 || (e->state & 13) || e->window != gtk_tree_view_get_bin_window(tv)) return;
    if (!gtk_tree_view_get_path_at_pos(tv, (int)e->x, (int)e->y, &path, &col, &cx, &cy)) return;
    GList *cols = gtk_tree_view_get_columns(tv); void *sel = gtk_tree_view_get_selection(tv);
    if (cols && cols->data == col && gtk_tree_selection_path_is_selected(sel, path) && gtk_tree_selection_count_selected_rows(sel) == 1) {
        int hit = 0; Rect ca; gtk_tree_view_get_cell_area(tv, path, col, &ca);
        void *m = gtk_tree_view_get_model(tv); TIter it;
        if (gtk_tree_model_get_iter(m, &it, path)) {
            gtk_tree_view_column_cell_set_cell_data(col, m, &it, 0, 0);
            for (GList *c = gtk_cell_layout_get_cells(col); c; c = c->next) {
                if (!g_type_check_instance_is_a((GTypeInstance *)c->data, gtk_cell_renderer_text_get_type())) continue;
                int off = 0, w = 0, mn = 0, nat = 0; gtk_tree_view_column_cell_get_position(col, c->data, &off, &w);
                gtk_cell_renderer_get_preferred_width(c->data, tv, &mn, &nat);
                int tw = nat < w ? nat : w; char *txt = NULL; g_object_get(c->data, "text", &txt, NULL);
                if (txt) { void *lay = gtk_widget_create_pango_layout(tv, txt); int pw = 0, ph = 0; pango_layout_get_pixel_size(lay, &pw, &ph); g_object_unref(lay); if (pw + 8 < tw) tw = pw + 8; g_free(txt); }
                hit = (int)e->x >= ca.x + off && (int)e->x <= ca.x + off + tw;
            }
            if (hit || rn_any) {
                int ms = 400; g_object_get(gtk_settings_get_default(), "gtk-double-click-time", &ms, NULL);
                RnJob *j = g_new0(RnJob, 1); j->tv = tv; j->ref = gtk_tree_row_reference_new(m, path); j->gen = rn_gen;
                g_timeout_add(ms + 60, rn_fire, j);
            }
        }
    }
    g_list_free(cols); gtk_tree_path_free(path);
}
/* ---- whole-row clicks. A blank press normally starts a rubber band (kept), but on the ONE selected row a click anywhere in the row stays on that row (x is moved into the name
   column, so Thunar neither deselects nor rubber-bands) and arms the slow-click rename; a fast double click anywhere in a row opens it: the first press of a blank double click
   rubber-banded away the selection, and Thunar's row-activated opens the SELECTION, so the double-click press selects the row first and, if GTK did not emit row-activated itself,
   it is emitted from an idle. ---- */
extern void gtk_tree_view_row_activated(void *, void *, void *);
static void row_act_seen(void *tv, void *path, void *col, gpointer u) { g_object_set_data(tv, "fm-act-seen", (gpointer)1); }
typedef struct { void *tv; void *ref; } ActJob;
static gboolean row_act_idle(gpointer d) {
    ActJob *j = d; void *path = gtk_tree_row_reference_get_path(j->ref);
    if (path && !g_object_get_data(j->tv, "fm-act-seen")) {
        GList *cols = gtk_tree_view_get_columns(j->tv);
        if (cols) gtk_tree_view_row_activated(j->tv, path, cols->data);
        g_list_free(cols);
    }
    if (path) gtk_tree_path_free(path);
    gtk_tree_row_reference_free(j->ref); g_free(j); return G_SOURCE_REMOVE;
}
static void row_click(void *tv, PressEv *e) {
    void *path = NULL, *col = NULL; int cx, cy;
    rn_any = 0;
    if (e->button != 1 || (e->state & 13) || e->window != gtk_tree_view_get_bin_window(tv)) return;
    if (e->type != 4 && e->type != 5) return;
    if (!gtk_tree_view_get_path_at_pos(tv, (int)e->x, (int)e->y, &path, &col, &cx, &cy)) return;
    void *sel = gtk_tree_view_get_selection(tv);
    GList *cols = gtk_tree_view_get_columns(tv);
    if (e->type == 5) {
        if (!g_object_get_data(tv, "fm-act-conn")) { g_object_set_data(tv, "fm-act-conn", (gpointer)1); g_signal_connect(tv, "row-activated", G_CALLBACK(row_act_seen), NULL); }
        if (!gtk_tree_selection_path_is_selected(sel, path) || gtk_tree_selection_count_selected_rows(sel) != 1) { gtk_tree_selection_unselect_all(sel); gtk_tree_selection_select_path(sel, path); }
        g_object_set_data(tv, "fm-act-seen", NULL);
        ActJob *j = g_new0(ActJob, 1); j->tv = tv; j->ref = gtk_tree_row_reference_new(gtk_tree_view_get_model(tv), path);
        g_idle_add(row_act_idle, j);
    } else if (cols && gtk_tree_selection_path_is_selected(sel, path) && gtk_tree_selection_count_selected_rows(sel) == 1) {
        Rect ca; gtk_tree_view_get_cell_area(tv, path, cols->data, &ca);
        if ((int)e->x > ca.x) { e->x = ca.x + 4 > ca.x + ca.w ? ca.x : ca.x + 4; rn_any = 1; }
    }
    g_list_free(cols); gtk_tree_path_free(path);
}

static gboolean press_emission_hook(GSignalInvocationHint *ihint, guint n, const GValue *pv, gpointer d) {
    void *tv = g_value_get_object(&pv[0]), *ev = g_value_get_boxed(&pv[1]);
    if (tv && ev && g_object_get_data(tv, "fm-rows")) { row_click(tv, ev); rn_arm(tv, ev); if (!rn_any) on_press_blank_name(tv, ev, NULL); }
    if (tv && ev && ((PressEv *)ev)->type == 4 && ((PressEv *)ev)->button == 3 && (g_type_is_a(G_OBJECT_TYPE(tv), g_type_from_name("ThunarShortcutsView")) || g_type_is_a(G_OBJECT_TYPE(tv), g_type_from_name("ThunarTreeView")))) { sb_press_us = g_get_monotonic_time(); sb_press_view = tv; sb_record(tv, ev); }
    else if (ev && ((PressEv *)ev)->type == 4 && ((PressEv *)ev)->button == 3) sb_press_view = NULL;
    return TRUE;
}

/* ---- permanent-delete confirm: Thunar's two-paragraph "Are you sure you want to permanently delete ..." becomes a single "Delete permanently?" line (Left/Right switch buttons, like fm-confirm) ---- */
extern void *gtk_dialog_get_action_area(void *), *gtk_dialog_get_content_area(void *), *gtk_message_dialog_get_message_area(void *); extern void gtk_window_set_title(void *, const char *), gtk_window_resize(void *, int, int), gtk_widget_grab_focus(void *), gtk_container_set_border_width(void *, unsigned), gtk_box_set_spacing(void *, int), gtk_widget_set_margin_top(void *, int), gtk_widget_set_margin_bottom(void *, int);
static gboolean confirm_key(void *dlg, KeyEv *e, gpointer u) {
    if (e->type != 8 || (e->keyval != 0xff51 && e->keyval != 0xff53)) return FALSE;
    void *f = gtk_window_get_focus(dlg); GList *bs = NULL;
    for (GList *l = gtk_container_get_children(gtk_dialog_get_action_area(dlg)); l; l = l->next) bs = g_list_append(bs, l->data);
    GList *cur = g_list_find(bs, f);
    if (cur && g_list_length(bs) > 1) { GList *n = e->keyval == 0xff53 ? (cur->next ? cur->next : bs) : (cur->prev ? cur->prev : g_list_last(bs)); gtk_widget_grab_focus(n->data); g_list_free(bs); return TRUE; }
    g_list_free(bs); return FALSE;
}
/* "Create New File" / "Create New Folder" (right-click menu) are small dialogs with a name entry holding "untitled ..." and the cursor at its end: select the whole name so typing replaces it */
static void *dlg_find_entry(void *w) {
    if (g_type_check_instance_is_a((GTypeInstance *)w, g_type_from_name("GtkEntry"))) return w;
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_container_get_type()))
        for (GList *l = gtk_container_get_children(w); l; l = l->next) { void *r = dlg_find_entry(l->data); if (r) return r; }
    return NULL;
}
static gboolean dlg_select_idle(gpointer d) {
    void *e = dlg_find_entry(d); if (e) { gtk_widget_grab_focus(e); gtk_editable_select_region(e, 0, -1); }
    g_object_unref(d); return G_SOURCE_REMOVE;
}
static gboolean dialog_show_hook(GSignalInvocationHint *ihint, guint n, const GValue *pv, gpointer d) {
    void *w = g_value_get_object(&pv[0]);
    if (w && g_type_check_instance_is_a((GTypeInstance *)w, g_type_from_name("GtkDialog")) && !g_object_get_data(w, "fm-newsel")) {
        char *t = NULL; g_object_get(w, "title", &t, NULL);
        if (t && (!strcmp(t, "Create New File") || !strcmp(t, "Create New Folder"))) { g_object_set_data(w, "fm-newsel", (gpointer)1); g_idle_add(dlg_select_idle, g_object_ref(w)); }
        g_free(t);
    }
    if (w && g_type_check_instance_is_a((GTypeInstance *)w, g_type_from_name("GtkMessageDialog")) && !g_object_get_data(w, "fm-confirm")) {
        char *t = NULL; g_object_get(w, "text", &t, NULL);
        if (t && g_str_has_prefix(t, "Are you sure") && strstr(t, "permanently") && strstr(t, "delete")) {                  /* "Are you sure that you want to\npermanently delete ..." (Thunar 4.20 wording; also the "N selected files" variants) */
            g_object_set_data(w, "fm-confirm", (gpointer)1);
            g_object_set(w, "text", "Delete permanently?", "secondary-text", NULL, NULL);
            g_signal_connect(w, "key-press-event", G_CALLBACK(confirm_key), NULL);
            gtk_window_set_title(w, "fm-popup:delete");                                    /* the Knomadic shell extension closes windows titled fm-popup* on a click outside them */
        }
        g_free(t);
        void *ca = gtk_dialog_get_content_area(w), *aa = gtk_dialog_get_action_area(w), *ma = gtk_message_dialog_get_message_area(w);   /* GTK3 CSS cannot shrink border-width: tighten the dialog here */
        gtk_container_set_border_width(ca, 0); gtk_box_set_spacing(ca, 0); gtk_container_set_border_width(aa, 4); gtk_container_set_border_width(ma, 4);
        gtk_widget_set_margin_top(ma, 0); gtk_widget_set_margin_bottom(ma, 0); gtk_window_resize(w, 1, 1);
    }
    return TRUE;
}
static gboolean editing_started_hook(GSignalInvocationHint *ihint, guint n, const GValue *pv, gpointer d) {   /* every cell edit in the process: Thunar's own (New File / New Folder / F2) selects only the cursor end, so select the base name */
    void *ent = n > 1 && G_VALUE_HOLDS_OBJECT(&pv[1]) ? g_value_get_object(&pv[1]) : NULL;
    if (!rn_ours && ent && G_TYPE_CHECK_INSTANCE_TYPE(ent, g_type_from_name("GtkEntry")) && !g_object_get_data(ent, "fm-rn-sel")) { g_object_set_data(ent, "fm-rn-sel", (gpointer)1); g_idle_add(rn_select_new_idle, g_object_ref(ent)); }
    return TRUE;
}
extern unsigned long gtk_cell_renderer_get_type(void);
static void install_dialog_hook(void) {
    static int done; if (done) return; done = 1;
    { unsigned long crt = gtk_cell_renderer_get_type(); g_type_class_ref(crt); g_signal_add_emission_hook(g_signal_lookup("editing-started", crt), 0, editing_started_hook, NULL, NULL); }   /* the class must exist or the signal id is 0 */
    g_signal_add_emission_hook(g_signal_lookup("show", gtk_widget_get_type()), 0, dialog_show_hook, NULL, NULL);
}
static void install_press_hook(void) {
    static int done; if (done) return; done = 1;
    g_signal_add_emission_hook(g_signal_lookup("button-press-event", gtk_widget_get_type()), 0, press_emission_hook, NULL, NULL);
}
/* no pop-up tooltips in the sidebar (places + tree): the hook runs before every query-tooltip handler, turns the widget's tooltips off for good and blanks this query */
extern void gtk_widget_set_has_tooltip(void *, int);
extern void gtk_tooltip_set_text(void *, const char *);
static gboolean tooltip_emission_hook(GSignalInvocationHint *ihint, guint n, const GValue *pv, gpointer d) {
    void *w = g_value_get_object(&pv[0]);
    if (w && (g_type_is_a(G_OBJECT_TYPE(w), g_type_from_name("ThunarShortcutsView")) || g_type_is_a(G_OBJECT_TYPE(w), g_type_from_name("ThunarTreeView")))) {
        gtk_widget_set_has_tooltip(w, 0);
        if (n > 4 && G_VALUE_HOLDS_OBJECT(&pv[4])) gtk_tooltip_set_text(g_value_get_object(&pv[4]), NULL);
    }
    return TRUE;
}
static void install_tooltip_hook(void) {
    static int done; if (done) return; done = 1;
    g_signal_add_emission_hook(g_signal_lookup("query-tooltip", gtk_widget_get_type()), 0, tooltip_emission_hook, NULL, NULL);
}
/* ---- folder sizes in the list view's Size column (Thunar 4.20 shows nothing / an item count for folders). A cell-data function on the Size column's renderer runs AFTER Thunar's own
   attribute mapping, so for directory rows it replaces the text with the recursive total (g_format_size, SI units = MB like Thunar's own sizes when "binary" is off). Totals are computed
   in 2 worker threads, cached for 60 s (the old value stays visible while it refreshes, "..." the first time), and the view is redrawn when one finishes. Local paths only (not /proc, /sys, /dev);
   symlinks are counted, never followed; hard limit 3M entries per folder (then the partial total is shown). ---- */
extern void gtk_tree_view_column_set_cell_data_func(void *, void *, void (*)(void *, void *, void *, TIter *, gpointer), gpointer, GDestroyNotify);
extern const char *gtk_tree_view_column_get_title(void *);
extern void gtk_tree_view_column_set_min_width(void *, int);
extern int gtk_tree_model_get_n_columns(void *);
extern unsigned long gtk_tree_model_get_column_type(void *, int);
extern void gtk_tree_model_get_value(void *, TIter *, int, GValue *);
extern void *thunarx_file_info_get_location(void *);
extern int thunarx_file_info_is_directory(void *);
extern void gtk_widget_queue_draw(void *), gtk_widget_queue_resize(void *);
typedef struct { gint64 bytes, mtime; gint64 stamp; int busy; } FSize;
static GHashTable *fsizes; static GMutex fs_lock; static GThreadPool *fs_pool;
typedef struct { char *uri; void *view, *model; } FJob;
/* Sorting by Size must use the same recursive totals the column shows (Thunar sorts folders by item count). A finished total re-sorts the model once (debounced) when it is sorted by Size. */
extern int gtk_tree_sortable_get_sort_column_id(void *, int *, int *);
extern void gtk_tree_sortable_set_sort_column_id(void *, int, int);
static gboolean fs_resort(gpointer m) {
    int col, ord; g_object_set_data(m, "fm-resort", NULL);
    if (gtk_tree_sortable_get_sort_column_id(m, &col, &ord) && (col == 11 /* SIZE */ || col == 12 /* SIZE_IN_BYTES */ || col == 2 /* DATE_MODIFIED */)) gtk_tree_sortable_set_sort_column_id(m, col, ord);
    g_object_unref(m); return G_SOURCE_REMOVE;
}
static gboolean fs_redraw(gpointer d) {
    FJob *j = d;
    if (j->view) { gtk_widget_queue_draw(j->view); g_object_unref(j->view); }
    if (j->model) { if (!g_object_get_data(j->model, "fm-resort")) { g_object_set_data(j->model, "fm-resort", (gpointer)1); g_timeout_add(250, fs_resort, g_object_ref(j->model)); } g_object_unref(j->model); }
    g_free(j); return G_SOURCE_REMOVE;
}
static void fs_work(gpointer data, gpointer u) {
    FJob *j = data; gint64 total = 0, n = 0, newest = 0; GFile *root = g_file_new_for_uri(j->uri);
    { GFileInfo *ri = g_file_query_info(root, "time::modified", G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, NULL); if (ri) { newest = (gint64)g_file_info_get_attribute_uint64(ri, "time::modified"); g_object_unref(ri); } } GQueue q = G_QUEUE_INIT; g_queue_push_tail(&q, root);
    while (!g_queue_is_empty(&q) && n < 3000000) {
        GFile *d = g_queue_pop_head(&q);
        GFileEnumerator *en = g_file_enumerate_children(d, "standard::name,standard::type,standard::size,time::modified", G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, NULL);
        for (GFileInfo *fi; en && (fi = g_file_enumerator_next_file(en, NULL, NULL)); g_object_unref(fi)) {
            n++; { gint64 mt = (gint64)g_file_info_get_attribute_uint64(fi, "time::modified"); if (mt > newest) newest = mt; }
            if (g_file_info_get_file_type(fi) == G_FILE_TYPE_DIRECTORY) g_queue_push_tail(&q, g_file_get_child(d, g_file_info_get_name(fi)));
            else total += g_file_info_get_size(fi);
        }
        if (en) { g_file_enumerator_close(en, NULL, NULL); g_object_unref(en); }
        g_object_unref(d);
    }
    while (!g_queue_is_empty(&q)) g_object_unref(g_queue_pop_head(&q));
    g_mutex_lock(&fs_lock);
    FSize *e = g_hash_table_lookup(fsizes, j->uri); if (e) { e->bytes = total; e->mtime = newest; e->stamp = g_get_monotonic_time(); e->busy = 0; }
    g_mutex_unlock(&fs_lock);
    g_free(j->uri); j->uri = NULL; g_idle_add(fs_redraw, j);
}
/* 0 = not applicable (remote, /proc ...), 1 = total not known yet (job started), 2 = *bytes valid */
static int fs_get(GFile *loc, void *view, void *model, gint64 *bytes_out, gint64 *mtime_out) {
    if (!g_file_is_native(loc)) return 0;
    char *path = g_file_get_path(loc); gboolean skip = !path || g_str_has_prefix(path, "/proc") || g_str_has_prefix(path, "/sys") || g_str_has_prefix(path, "/dev"); g_free(path);
    if (skip) return 0;
    char *uri = g_file_get_uri(loc); gint64 now = g_get_monotonic_time(); int start = 0, have = 0; gint64 bytes = 0;
    g_mutex_lock(&fs_lock);
    if (!fsizes) { fsizes = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free); fs_pool = g_thread_pool_new(fs_work, NULL, 2, FALSE, NULL); }
    FSize *e = g_hash_table_lookup(fsizes, uri);
    if (!e) { e = g_new0(FSize, 1); g_hash_table_insert(fsizes, g_strdup(uri), e); start = e->busy = 1; }
    else if (!e->busy && now - e->stamp > 60 * G_USEC_PER_SEC) start = e->busy = 1;
    have = e->stamp != 0; bytes = e->bytes; if (mtime_out) *mtime_out = e->mtime;
    g_mutex_unlock(&fs_lock);
    if (start) { FJob *j = g_new0(FJob, 1); j->uri = g_strdup(uri); j->view = view ? g_object_ref(view) : NULL; j->model = model ? g_object_ref(model) : NULL; g_thread_pool_push(fs_pool, j, NULL); }
    g_free(uri); if (bytes_out) *bytes_out = bytes; return have ? 2 : 1;
}
static char *fsize_text(GFile *loc, void *view) {
    gint64 b; int st = fs_get(loc, view, gtk_tree_view_get_model(view), &b, NULL);
    return st == 0 ? NULL : st == 2 ? g_format_size(b) : g_strdup("...");
}
static void size_cell_func(void *col, void *cell, void *model, TIter *it, gpointer view) {
    int fc = GPOINTER_TO_INT(g_object_get_data(model, "fm-filecol"));
    if (!fc) {
        fc = -1; for (int i = 0, n = gtk_tree_model_get_n_columns(model); i < n; i++) if (!strcmp(g_type_name(gtk_tree_model_get_column_type(model, i)), "ThunarFile")) { fc = i + 1; break; }
        g_object_set_data(model, "fm-filecol", GINT_TO_POINTER(fc));
    }
    if (fc < 0) return;
    GValue v = G_VALUE_INIT; gtk_tree_model_get_value(model, it, fc - 1, &v);
    void *file = G_VALUE_HOLDS_OBJECT(&v) ? g_value_get_object(&v) : NULL;
    if (file && thunarx_file_info_is_directory(file)) {
        GFile *loc = thunarx_file_info_get_location(file);
        if (loc) { char *t = fsize_text(loc, view); if (t) { g_object_set(cell, "text", t, NULL); g_free(t); } g_object_unref(loc); }
    }
    g_value_unset(&v);
}
/* Date Modified of a folder = newest modification anywhere inside it (same walk as the size). Formatted with the user's custom strftime style from thunar.xml (read once); other styles keep Thunar's text. */
static char *fs_date_fmt(void) {
    static char *fmt; static int done; if (done) return fmt; done = 1;
    char *path = g_build_filename(g_get_user_config_dir(), "xfce4/xfconf/xfce-perchannel-xml/thunar.xml", NULL), *txt = NULL;
    if (g_file_get_contents(path, &txt, NULL, NULL) && strstr(txt, "name=\"misc-date-style\" type=\"string\" value=\"THUNAR_DATE_STYLE_CUSTOM\"")) {
        char *k = strstr(txt, "name=\"misc-date-custom-style\""), *v = k ? strstr(k, "value=\"") : NULL;
        if (v) { v += 7; char *end = strchr(v, '"'); if (end) { char *raw = g_strndup(v, end - v); const char *ent[][2] = { {"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""} };
            for (int i = 0; i < 4; i++) { char **parts = g_strsplit(raw, ent[i][0], -1); g_free(raw); raw = g_strjoinv(ent[i][1], parts); g_strfreev(parts); } fmt = raw; } }
    }
    g_free(txt); g_free(path); return fmt;
}
static void date_cell_func(void *col, void *cell, void *model, TIter *it, gpointer view) {
    int fc = GPOINTER_TO_INT(g_object_get_data(model, "fm-filecol"));
    if (!fc) {
        fc = -1; for (int i = 0, n = gtk_tree_model_get_n_columns(model); i < n; i++) if (!strcmp(g_type_name(gtk_tree_model_get_column_type(model, i)), "ThunarFile")) { fc = i + 1; break; }
        g_object_set_data(model, "fm-filecol", GINT_TO_POINTER(fc));
    }
    char *fmt = fs_date_fmt(); if (fc < 0 || !fmt) return;
    GValue v = G_VALUE_INIT; gtk_tree_model_get_value(model, it, fc - 1, &v);
    void *file = G_VALUE_HOLDS_OBJECT(&v) ? g_value_get_object(&v) : NULL;
    if (file && thunarx_file_info_is_directory(file)) {
        GFile *loc = thunarx_file_info_get_location(file); gint64 mt = 0;
        if (loc) { if (fs_get(loc, view, model, NULL, &mt) == 2 && mt > 0) { GDateTime *dt = g_date_time_new_from_unix_local(mt); char *t = dt ? g_date_time_format(dt, fmt) : NULL; if (t) { g_object_set(cell, "text", t, NULL); g_free(t); } if (dt) g_date_time_unref(dt); } g_object_unref(loc); }
    }
    g_value_unset(&v);
}
static void hook_size_column(void *tv) {
    for (GList *c = gtk_tree_view_get_columns(tv); c; c = c->next) {
        const char *t = gtk_tree_view_column_get_title(c->data);
        if (t && !strcmp(t, "Size")) {
            gtk_tree_view_column_set_min_width(c->data, 100);   /* "999.9 MB" must fit; the column is fixed-width otherwise */
            for (GList *r = gtk_cell_layout_get_cells(c->data); r; r = r->next) gtk_tree_view_column_set_cell_data_func(c->data, r->data, size_cell_func, tv, NULL);
        }
        if (t && !strcmp(t, "Date Modified"))
            for (GList *r = gtk_cell_layout_get_cells(c->data); r; r = r->next) gtk_tree_view_column_set_cell_data_func(c->data, r->data, date_cell_func, tv, NULL);
    }
    gtk_widget_queue_resize(tv); gtk_widget_queue_draw(tv);
}
static void hook_views(void *w) {
    hook_sidebar(w);
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_tree_view_get_type()) && is_view(w) && !g_object_get_data(w, "fm-rows")) {
        g_object_set_data(w, "fm-rows", (gpointer)1);
        install_press_hook();
        g_signal_connect(w, "drag-begin", G_CALLBACK(rn_bump), NULL);
        g_signal_connect_after(w, "draw", G_CALLBACK(on_draw_rows), NULL);
        g_signal_connect(w, "test-expand-row", G_CALLBACK(on_test_expand), NULL);
        g_signal_connect_after(w, "row-expanded", G_CALLBACK(on_row_expanded), NULL);
        hook_size_column(w);
        g_signal_connect(w, "columns-changed", G_CALLBACK(hook_size_column), NULL);   /* Thunar rebuilds its columns after startup / when they are toggled */
    }
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_container_get_type()))
        for (GList *l = gtk_container_get_children(w); l; l = l->next) hook_views(l->data);
}
/* Per-window setup: key handler + toolbar/menubar hidden. Runs from the gtk_widget_show interpose below, i.e. BEFORE the window's first map (no flash of the bars);
   scan() calls it too as a fallback for windows that were already shown. */
static void hook_window(void *w) {
    if (g_object_get_data(w, "fm-hook")) return;
    if (!gtk_style_context_has_class(gtk_widget_get_style_context(w), "thunar") || !find_toolbar(w)) return;   /* not a built Thunar window yet */
    g_object_set_data(w, "fm-hook", (gpointer)1);
    g_signal_connect(w, "key-press-event", G_CALLBACK(on_key), NULL);
    set_toolbar(w, 0);
}
extern int gtk_widget_is_toplevel(void *);
void gtk_widget_show(void *w) {
    static void (*real)(void *); if (!real) real = dlsym(RTLD_NEXT, "gtk_widget_show");
    if (gtk_widget_is_toplevel(w) && !gtk_widget_get_visible(w)) hook_window(w);
    real(w);
}
static gboolean scan(gpointer u) {
    install_tooltip_hook(); install_dialog_hook();
    for (GList *l = gtk_window_list_toplevels(); l; l = l->next) {
        void *w = l->data;
        if (!gtk_style_context_has_class(gtk_widget_get_style_context(w), "thunar")) continue;
        hook_views(w);
        hook_window(w);
    }
    return TRUE;
}
/* Apps Thunar launches (Open With, double-click) must not inherit thunar-fm's private environment: GTK_THEME=fm-sample made GTK4 apps (Text Editor) fall back to a white Adwaita titlebar,
   XDG_CONFIG_HOME/GSETTINGS_BACKEND/FONTCONFIG_FILE point at the private config farm. Strip them from the launch context. */
extern void *gdk_display_get_app_launch_context(void *);
void *gdk_display_get_app_launch_context(void *display) {
    static void *(*real)(void *); if (!real) real = dlsym(RTLD_NEXT, "gdk_display_get_app_launch_context");
    void *ctx = real(display);
    if (ctx) { static const char *drop[] = { "GTK_THEME", "GSETTINGS_BACKEND", "XDG_CONFIG_HOME", "FONTCONFIG_FILE", "LD_PRELOAD", NULL }; for (int i = 0; drop[i]; i++) g_app_launch_context_unsetenv(ctx, drop[i]); }
    return ctx;
}
__attribute__((constructor)) static void init(void) {
    char b[256] = {0};
    if (readlink("/proc/self/exe", b, 255) > 0 && strstr(b, "thunar")) { g_timeout_add(1000, scan, NULL); unsetenv("LD_PRELOAD"); }   /* already loaded here; children (Open With -> GTK4 apps like Text Editor) must not inherit this GTK3 library ("GTK 2/3 symbols detected") */
}

/* ---- context-menu pruning: hide any menu item whose label is listed in ~/.config/fm-menu-hide.txt (one label per line,
   case-insensitive, mnemonic underscores ignored, '#' comments). Applies at every popup (also inside submenus); stray separators are collapsed.
   Re-read on every popup, so edits need no rebuild or restart. ---- */
#include <dlfcn.h>
extern unsigned long gtk_menu_item_get_type(void), gtk_separator_menu_item_get_type(void);
extern const char *gtk_menu_item_get_label(void *);
extern void *gtk_menu_item_get_submenu(void *);
extern int gtk_widget_get_visible(void *);
extern void gtk_widget_hide(void *), gtk_widget_set_no_show_all(void *, int);

static char **hide_list; static int hide_n;
static char *norm(const char *s) {
    char *o = g_malloc(strlen(s) + 1); int j = 0;
    for (const char *p = s; *p; p++) if (*p != '_') o[j++] = g_ascii_tolower(*p);
    o[j] = 0; return g_strstrip(o);
}
static void load_hide_list(void) {
    for (int i = 0; i < hide_n; i++) g_free(hide_list[i]);
    g_free(hide_list); hide_list = NULL; hide_n = 0;
    gchar *path = g_build_filename(g_get_home_dir(), ".config", "fm-menu-hide.txt", NULL), *txt = NULL;
    if (g_file_get_contents(path, &txt, NULL, NULL)) {
        gchar **lines = g_strsplit(txt, "\n", -1);
        for (int i = 0; lines[i]; i++) {
            char *l = g_strstrip(lines[i]);
            if (!*l || *l == '#') continue;
            hide_list = g_realloc(hide_list, sizeof(char *) * (hide_n + 1));
            hide_list[hide_n++] = norm(l);
        }
        g_strfreev(lines); g_free(txt);
    }
    g_free(path);
}
static int listed(const char *label) {
    char *n = norm(label); int hit = 0;
    for (int i = 0; i < hide_n && !hit; i++) hit = !strcmp(n, hide_list[i]);
    g_free(n); return hit;
}
static int is_sep(void *w) { return g_type_check_instance_is_a((GTypeInstance *)w, gtk_separator_menu_item_get_type()); }
static int is_item(void *w) { return g_type_check_instance_is_a((GTypeInstance *)w, gtk_menu_item_get_type()); }
static void prune_menu(void *menu) {
    GList *kids = gtk_container_get_children(menu);
    for (GList *l = kids; l; l = l->next) {
        void *w = l->data;
        if (!is_item(w) || is_sep(w)) continue;
        const char *t = gtk_menu_item_get_label(w);
        if (t && listed(t)) { gtk_widget_set_no_show_all(w, 1); gtk_widget_hide(w); continue; }
        void *sub = gtk_menu_item_get_submenu(w);
        if (sub) prune_menu(sub);
    }
    int prev_sep = 1;                                   /* drop leading / doubled separators */
    void *last_sep = NULL;
    for (GList *l = kids; l; l = l->next) {
        void *w = l->data;
        if (!gtk_widget_get_visible(w)) continue;
        if (is_sep(w)) { if (prev_sep) { gtk_widget_set_no_show_all(w, 1); gtk_widget_hide(w); } else { prev_sep = 1; last_sep = w; } }
        else { prev_sep = 0; last_sep = NULL; }
    }
    if (last_sep) { gtk_widget_set_no_show_all(last_sep, 1); gtk_widget_hide(last_sep); }   /* trailing separator */
    g_list_free(kids);
}

/* ---- right-click menu layout ----
   File / folder / background context menus show ONLY, in this order: Menu >, Open With >, New Folder, New File, Copy Location, Open in Terminal,
   Rename, Delete, Shred, Properties...   (New Folder/New File/Copy Location/Open in Terminal/Rename/Shred are custom actions in ~/.config/Thunar/uca.xml.)
   Everything else is hidden. "Menu >" holds Thunar's own (hidden) menu bar menus: File, Edit, View, Go, Bookmarks, Help - the SAME GtkMenu widgets,
   borrowed for the lifetime of the popup and handed back when it closes/is destroyed. Detected by: has "Properties..." and ("Open With" or "New Folder"). */
extern unsigned long gtk_menu_bar_get_type(void), gtk_menu_get_type(void);
extern void *gtk_menu_item_new_with_label(const char *), *gtk_menu_new(void), *gtk_separator_menu_item_new(void);
extern void gtk_container_remove(void *, void *);
extern void g_signal_emit_by_name(void *, const char *, ...);
extern void gtk_menu_item_set_submenu(void *, void *), gtk_menu_item_set_label(void *, const char *), gtk_menu_reorder_child(void *, void *, int), gtk_menu_shell_insert(void *, void *, int),
            gtk_menu_shell_append(void *, void *), gtk_widget_show(void *);
typedef struct { void *orig, *proxy, *sub; } Loan;

static void loan_return(Loan *ln) {
    if (!ln->sub) return;
    g_object_ref(ln->sub);
    gtk_menu_item_set_submenu(ln->proxy, NULL);
    gtk_menu_item_set_submenu(ln->orig, ln->sub);
    g_object_unref(ln->sub); ln->sub = NULL;
}
static void on_proxy_destroy(void *proxy, gpointer data) { loan_return(data); }
static void on_loan_free(gpointer data) { g_free(data); }
static void on_ctx_deactivate(void *menu, gpointer data) { GPtrArray *a = g_object_get_data(menu, "fm-loans"); if (a) for (guint i = 0; i < a->len; i++) loan_return(a->pdata[i]); }
static void *find_menubar(void *w) {
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_menu_bar_get_type())) return w;
    if (g_type_check_instance_is_a((GTypeInstance *)w, gtk_container_get_type()))
        for (GList *l = gtk_container_get_children(w); l; l = l->next) { void *r = find_menubar(l->data); if (r) return r; }
    return NULL;
}
static void *thunar_toplevel(void) {
    for (GList *l = gtk_window_list_toplevels(); l; l = l->next)
        if (gtk_style_context_has_class(gtk_widget_get_style_context(l->data), "thunar")) return l->data;
    return NULL;
}
static const char *WANT[] = { "menu", "open with", "new file", "new folder", "copy location", "copy", "paste", "open in terminal", "rename", "delete", "shred", "properties...", NULL };
static int want_rank(const char *label) { char *n = norm(label); int r = -1; for (int i = 0; WANT[i]; i++) if (!strcmp(n, WANT[i])) r = i; if (!strcmp(n, "paste into folder")) r = 6; g_free(n); return r; }
static const char *PRETTY[] = { "Menu", "Open With", "New File", "New Folder", "Copy Location", "Copy", "Paste", "Open in Terminal", "Rename", "Delete", "Shred", "Properties...", NULL };
static int rank_group(int r) { return r <= 1 ? 0 : r <= 7 ? 1 : r <= 10 ? 2 : 3; }          /* separator groups: {Menu, Open With} | {New.., Copy.., Paste, Terminal} | {Rename, Delete, Shred} | {Properties} */
static int bg_hidden(int r) { return r == 5 || (r >= 8 && r <= 10); }                           /* blank space: nothing selected, so no Copy / Rename / Delete / Shred */

/* ---- sidebar (Places / Devices): right-click Hide, right-click empty space for "Show All" (hidden items then show dimmed), right-click a dimmed item for "Show". ----
   Thunar already hides items from the xfconf lists /hidden-bookmarks (URIs) and the ThunarDevice "hidden" property (-> /hidden-devices) and its model reacts live; column 2 of the
   ThunarShortcutsModel is "visible". The view sits on a GtkTreeModelFilter: its visible func is replaced by one that also lets hidden rows through while "Show All" is on
   (xfconf /fm-sidebar-show-all), and a draw handler fades those rows. Model columns: 0 header, 1 item, 2 visible, 6 GFile, 8 ThunarDevice, 11 group type. */
extern void *xfconf_channel_get(const char *);
extern char **xfconf_channel_get_string_list(void *, const char *);
extern int xfconf_channel_set_string_list(void *, const char *, const char *const *), xfconf_channel_get_bool(void *, const char *, int), xfconf_channel_set_bool(void *, const char *, int);
extern void gtk_tree_model_filter_set_visible_func(void *, int (*)(void *, TIter *, gpointer), gpointer, GDestroyNotify), gtk_tree_model_filter_refilter(void *);
extern unsigned long gtk_tree_model_filter_get_type(void);
extern void *gtk_tree_model_filter_new(void *, void *);
extern void gtk_tree_view_set_model(void *, void *);
extern void *gtk_check_menu_item_new_with_label(const char *);
extern void gtk_widget_show_all(void *);
extern void gtk_check_menu_item_set_active(void *, int), gtk_menu_popup_at_pointer(void *, const void *), gtk_tree_view_get_background_area(void *, void *, void *, Rect *),
            gtk_tree_view_convert_bin_window_to_widget_coords(void *, int, int, int *, int *);
static int sb_show_all; static GList *sb_views;
static struct { int valid, is_item, hidden; unsigned type; char *uri; void *dev; } sb_row;
static void sb_view_gone(gpointer d, GObject *o) { sb_views = g_list_remove(sb_views, o); }
static int sb_col_bool(void *m, TIter *it, int c) { GValue v = G_VALUE_INIT; gtk_tree_model_get_value(m, it, c, &v); int r = g_value_get_boolean(&v); g_value_unset(&v); return r; }
static int sb_visible(void *m, TIter *it, gpointer u) { return sb_col_bool(m, it, 2) || sb_show_all; }
static gboolean sb_draw(void *tv, void *cr, gpointer u) {
    void *s0 = NULL, *e0 = NULL;
    if (!sb_show_all || !gtk_tree_view_get_visible_range(tv, &s0, &e0) || !s0 || !e0) { if (s0) gtk_tree_path_free(s0); if (e0) gtk_tree_path_free(e0); return FALSE; }
    void *m = gtk_tree_view_get_model(tv); RGBA bg = {0}; void *w = tv;
    for (; w; w = gtk_widget_get_parent(w)) { gtk_style_context_get_background_color(gtk_widget_get_style_context(w), 0, &bg); if (bg.a > 0.5) break; }
    if (!w) { bg.r = 0.196; bg.g = 0.196; bg.b = 0.227; }
    cairo_save(cr); cairo_set_source_rgba(cr, bg.r, bg.g, bg.b, 0.6);
    void *p = s0; s0 = NULL;
    for (int guard = 0; p && guard < 200; guard++) {
        TIter it;
        if (gtk_tree_model_get_iter(m, &it, p) && sb_col_bool(m, &it, 1) && !sb_col_bool(m, &it, 2)) {
            Rect r; int wx, wy; gtk_tree_view_get_background_area(tv, p, NULL, &r); gtk_tree_view_convert_bin_window_to_widget_coords(tv, r.x, r.y, &wx, &wy);
            cairo_rectangle(cr, wx, wy, gtk_widget_get_allocated_width(tv), r.h); cairo_fill(cr); }
        if (gtk_tree_path_compare(p, e0) >= 0) { gtk_tree_path_free(p); p = NULL; break; }
        void *n = gtk_tree_path_copy(p); gtk_tree_path_next(n); gtk_tree_path_free(p); p = n;
    }
    if (p) gtk_tree_path_free(p);
    cairo_restore(cr); gtk_tree_path_free(e0);
    return FALSE;
}

/* ---- sidebar drops: a file/folder dropped ON the middle of a sidebar row is moved INTO that folder/device (Thunar's default) - that silently moved a whole Software folder into Downloads.
   Instead the drop position snaps to the gap above (pointer in the upper half of the row) or below (lower half) the row: adding a bookmark / reordering is quick and nothing is ever moved into a row.
   Implemented by re-emitting drag-motion / drag-drop / drag-data-received with the y coordinate nudged into the row's top or bottom edge zone, then stopping the original emission. ---- */
extern int gtk_tree_view_get_dest_row_at_pos(void *, int, int, void **, int *);
extern void gtk_tree_view_convert_widget_to_bin_window_coords(void *, int, int, int *, int *);
extern int gtk_tree_model_get_iter_first(void *, TIter *), gtk_tree_model_iter_next(void *, TIter *);
extern void *gtk_tree_model_get_path(void *, TIter *);
static int sb_snap_y(void *tv, int *xp, int y) {
    /* Thunar only accepts a drop BETWEEN two bookmark rows (or before the first / after the last). Whatever the pointer is over - a row middle, Home, a header, Devices, empty space - the drop is redirected to the
       NEAREST such gap (y is moved into the edge zone of the neighbouring bookmark row; x is clamped inside the view). Returns the new widget y, or -1 when there are no bookmark rows. */
    void *m = gtk_tree_view_get_model(tv); TIter it; int n = 0, ys[64], hs[64], wx, wy, bx, by;
    gtk_tree_view_convert_widget_to_bin_window_coords(tv, *xp, y, &bx, &by);
    for (int ok = gtk_tree_model_get_iter_first(m, &it); ok && n < 64; ok = gtk_tree_model_iter_next(m, &it)) {
        GValue v = G_VALUE_INIT; gtk_tree_model_get_value(m, &it, 11, &v); unsigned type = g_value_get_uint(&v); g_value_unset(&v);
        if (type != 32 || !sb_col_bool(m, &it, 1)) continue;
        void *path = gtk_tree_model_get_path(m, &it); Rect r; gtk_tree_view_get_background_area(tv, path, NULL, &r); gtk_tree_path_free(path);
        ys[n] = r.y; hs[n] = r.h; n++;
    }
    if (!n) return -1;
    int best = 0, bd = 1 << 30;                                                           /* gap g < n: just above row g; gap n: just below the last row */
    for (int g = 0; g <= n; g++) { int gy = g < n ? ys[g] : ys[n - 1] + hs[n - 1]; int d = abs(by - gy); if (d < bd) { bd = d; best = g; } }
    int ny = best < n ? ys[best] + 1 : ys[n - 1] + hs[n - 1] - 2;
    int w = gtk_widget_get_allocated_width(tv); if (*xp < 4) *xp = 4; if (*xp > w - 4) *xp = w - 4;
    gtk_tree_view_convert_bin_window_to_widget_coords(tv, bx, ny, &wx, &wy);
    return wy;
}
static int sb_reentry;
/* 2026-10-19: a drop on the MIDDLE of an item row (Home, a bookmark, a device) is no longer refused/redirected: Thunar handles it as "drop INTO that folder", but the action is forced to ASK, i.e. Thunar's
   own Copy Here / Move Here / (Link Here, hidden via fm-menu-hide.txt) / Cancel menu, so nothing is ever moved silently. If the source does not offer ASK it falls back to COPY, never MOVE. */
extern int gtk_tree_model_get_iter(void *, TIter *, void *);
extern void gdk_drag_status(void *, int, unsigned);
extern int gdk_drag_context_get_actions(void *);
static int sb_mid(void *tv, int x, int y) {
    void *path = NULL; int pos = 0, ok = 0; TIter it;
    if (!gtk_tree_view_get_dest_row_at_pos(tv, x, y, &path, &pos) || !path) return 0;
    void *m = gtk_tree_view_get_model(tv);
    if (pos >= 2 /* GTK_TREE_VIEW_DROP_INTO_OR_BEFORE / _AFTER */ && gtk_tree_model_get_iter(m, &it, path)) ok = sb_col_bool(m, &it, 1);   /* col 1 = item row (not a group header) */
    gtk_tree_path_free(path); return ok;
}
static gboolean sb_drag_motion(void *tv, void *ctx, int x, int y, unsigned time, gpointer u) {
    int ny; gboolean ret = FALSE; if (sb_reentry || sb_mid(tv, x, y)) return FALSE;        /* a row middle: Thunar's own "drop into" acceptance */
    if ((ny = sb_snap_y(tv, &x, y)) < 0) return FALSE;
    sb_reentry = 1; g_signal_emit_by_name(tv, "drag-motion", ctx, x, ny, time, &ret); sb_reentry = 0;
    g_signal_stop_emission_by_name(tv, "drag-motion"); return ret;
}
static void sb_showall_done(void *menu, gpointer u);
typedef struct { void *tv, *ctx; int x, y; unsigned time; int act, picked; } SbAsk;
extern void gtk_drag_finish(void *, int, int, unsigned);
extern void gtk_menu_attach_to_widget(void *, void *, void *);
static int sb_ask_done;                                                                  /* set while the chosen action is being replayed through Thunar's drop handler */
static void *sb_copy_ctx;                                                                 /* drag context of a picked "Copy Here": the data-received step hands the copy to Thunar's file-manager service instead */
static void sb_ask_replay(SbAsk *a) {
    gboolean ret = FALSE; sb_ask_done = 1; g_signal_emit_by_name(a->tv, "drag-drop", a->ctx, a->x, a->y, a->time, &ret); sb_ask_done = 0;
    if (!ret) { sb_copy_ctx = NULL; gtk_drag_finish(a->ctx, FALSE, FALSE, a->time); }
}
static void sb_ask_pick(void *item, gpointer d) {
    SbAsk *a = d;
    a->picked = 1;
    if (!a->act) { gtk_drag_finish(a->ctx, FALSE, FALSE, a->time); return; }
    g_object_ref(a->ctx); gdk_drag_status(a->ctx, a->act, a->time);
    /* Wayland confirms a changed action only asynchronously and never after the drop, so Thunar would still see its default (MOVE on one drive): a Copy is therefore done by Thunar's own CopyInto service call (own progress window) */
    if (a->act == 2) sb_copy_ctx = a->ctx;
    sb_ask_replay(a);
}
static void sb_ask_free(void *menu, gpointer d) { SbAsk *a = d; if (a->picked && a->act) g_object_unref(a->ctx); g_free(a); }   /* the item owns its job: freed once with the menu (a picked Copy/Move also holds a context ref) */
static gboolean sb_drag_drop(void *tv, void *ctx, int x, int y, unsigned time, gpointer u) {
    int ny; gboolean ret = FALSE; if (sb_reentry || sb_ask_done) return FALSE;
    if (sb_mid(tv, x, y)) {
        /* Copy Here / Move Here / Cancel before anything happens (the source only offers COPY/MOVE on a left-button drag, so Thunar would act silently) */
        int acts = gdk_drag_context_get_actions(ctx); void *menu = gtk_menu_new(); const char *lab[3] = {"Copy Here", "Move Here", "Cancel"}; int val[3] = {2, 4, 0};
        for (int i = 0; i < 3; i++) {
            if (i == 1 && !(acts & 4)) continue;
            SbAsk *a = g_new0(SbAsk, 1); a->tv = tv; a->ctx = ctx; a->x = x; a->y = y; a->time = time; a->act = val[i];
            void *it = gtk_menu_item_new_with_label(lab[i]); g_signal_connect(it, "activate", G_CALLBACK(sb_ask_pick), a); g_signal_connect(it, "destroy", G_CALLBACK(sb_ask_free), a); /* free with the item */
            gtk_menu_shell_append(menu, it); gtk_widget_show(it);
        }
        gtk_menu_attach_to_widget(menu, tv, NULL); gtk_widget_show_all(menu); g_object_set_data(menu, "fm-laid", (gpointer)1);
        g_signal_connect(menu, "deactivate", G_CALLBACK(sb_showall_done), NULL);
        gtk_menu_popup_at_pointer(menu, NULL); g_signal_stop_emission_by_name(tv, "drag-drop"); return TRUE;
    }
    if ((ny = sb_snap_y(tv, &x, y)) < 0) return FALSE;
    sb_reentry = 1; g_signal_emit_by_name(tv, "drag-drop", ctx, x, ny, time, &ret); sb_reentry = 0;
    g_signal_stop_emission_by_name(tv, "drag-drop"); return ret;
}
extern char **gtk_selection_data_get_uris(void *);
static int sb_reentry_recv;                                                              /* own guard: GTK delivers the data (with the ORIGINAL pointer y) from inside the drag-drop re-emission, so it must not share sb_reentry */
static void sb_drag_received(void *tv, void *ctx, int x, int y, void *sel, unsigned info, unsigned time, gpointer u) {
    if (ctx && ctx == sb_copy_ctx) {
        sb_copy_ctx = NULL; char **uris = gtk_selection_data_get_uris(sel); void *path = NULL; int pos = 0; TIter it; char *tgt = NULL;
        if (gtk_tree_view_get_dest_row_at_pos(tv, x, y, &path, &pos) && path) {
            void *m = gtk_tree_view_get_model(tv);
            if (gtk_tree_model_get_iter(m, &it, path)) { GValue v = G_VALUE_INIT; gtk_tree_model_get_value(m, &it, 6, &v); if (G_VALUE_HOLDS_OBJECT(&v) && g_value_get_object(&v)) tgt = g_file_get_uri(g_value_get_object(&v)); g_value_unset(&v); }
            gtk_tree_path_free(path);
        }
        if (uris && tgt) {
            GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
            if (bus) { g_dbus_connection_call(bus, "org.xfce.FileManager", "/org/xfce/FileManager", "org.xfce.FileManager", "CopyInto", g_variant_new("(s^ass" "ss)", "/", uris, tgt, "", ""), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL); g_object_unref(bus); }
        }
        gtk_drag_finish(ctx, uris && tgt, FALSE, time); g_strfreev(uris); g_free(tgt);
        g_signal_stop_emission_by_name(tv, "drag-data-received"); return;
    }
    int ny; if (sb_reentry_recv || sb_mid(tv, x, y) || (ny = sb_snap_y(tv, &x, y)) < 0) return;
    sb_reentry_recv = 1; g_signal_emit_by_name(tv, "drag-data-received", ctx, x, ny, sel, info, time); sb_reentry_recv = 0;
    g_signal_stop_emission_by_name(tv, "drag-data-received");
}
static gboolean sb_press_block(void *tv, void *ev, gpointer u) {                           /* right-click on empty space / a group header: Thunar's own "Places / Devices / Network" section menu must not open next to ours (two grabs = a menu that sticks open) */
    PressEv *e = ev; return e->type == 4 && e->button == 3 && !sb_row.is_item;   /* true empty space leaves sb_row invalid, so do not require valid */
}
static void hook_sidebar(void *w) {
    if (!g_type_is_a(G_OBJECT_TYPE(w), g_type_from_name("ThunarShortcutsView")) || g_object_get_data(w, "fm-sb")) return;
    void *m = gtk_tree_view_get_model(w); if (!m || !g_type_check_instance_is_a((GTypeInstance *)m, gtk_tree_model_filter_get_type())) return;
    g_object_set_data(w, "fm-sb", (gpointer)1);
    static int init; if (!init) { init = 1; sb_show_all = xfconf_channel_get_bool(xfconf_channel_get("thunar"), "/fm-sidebar-show-all", 0); }
    /* a GtkTreeModelFilter accepts its visibility rule once (Thunar already set its column): put a new filter over the same model */
    void *child = NULL; g_object_get(m, "child-model", &child, NULL);
    if (!child) return;
    void *nf = gtk_tree_model_filter_new(child, NULL);
    gtk_tree_model_filter_set_visible_func(nf, sb_visible, NULL, NULL);
    gtk_tree_view_set_model(w, nf); g_object_unref(nf); g_object_unref(child);
    g_signal_connect_after(w, "draw", G_CALLBACK(sb_draw), NULL);
    g_signal_connect(w, "button-press-event", G_CALLBACK(sb_press_block), NULL);
    g_signal_connect(w, "drag-motion", G_CALLBACK(sb_drag_motion), NULL); g_signal_connect(w, "drag-drop", G_CALLBACK(sb_drag_drop), NULL); g_signal_connect(w, "drag-data-received", G_CALLBACK(sb_drag_received), NULL);
    sb_views = g_list_prepend(sb_views, w); g_object_weak_ref(w, sb_view_gone, NULL);
    install_press_hook();
}
static void sb_clear_row(void) { g_free(sb_row.uri); if (sb_row.dev) g_object_unref(sb_row.dev); memset(&sb_row, 0, sizeof sb_row); }
static void sb_toggle_showall(void *item, gpointer u) {
    sb_show_all = !sb_show_all; xfconf_channel_set_bool(xfconf_channel_get("thunar"), "/fm-sidebar-show-all", sb_show_all);
    for (GList *l = sb_views; l; l = l->next) { gtk_tree_model_filter_refilter(gtk_tree_view_get_model(l->data)); gtk_widget_queue_draw(l->data); }
}
static char *sb_dev_id(void *dev) {                                                      /* the string Thunar keeps in /hidden-devices: UUID, else the volume / mount name */
    GObject *o = NULL; char *id = NULL; g_object_get(dev, "device", &o, NULL); if (!o) return NULL;
    if (G_IS_VOLUME(o)) { id = g_volume_get_identifier(G_VOLUME(o), G_VOLUME_IDENTIFIER_KIND_UUID); if (!id) id = g_volume_get_name(G_VOLUME(o)); }
    else if (G_IS_MOUNT(o)) { id = g_mount_get_uuid(G_MOUNT(o)); if (!id) id = g_mount_get_name(G_MOUNT(o)); }
    g_object_unref(o); return id;
}
static void sb_list_update(const char *prop, const char *val, int hide) {
    void *ch = xfconf_channel_get("thunar"); char **old = xfconf_channel_get_string_list(ch, prop); GPtrArray *a = g_ptr_array_new(); int found = 0;
    for (int i = 0; old && old[i]; i++) { if (!strcmp(old[i], val)) { found = 1; if (!hide) continue; } g_ptr_array_add(a, old[i]); }
    if (hide && !found) g_ptr_array_add(a, (gpointer)val);
    g_ptr_array_add(a, NULL); xfconf_channel_set_string_list(ch, prop, (const char *const *)a->pdata);
    g_ptr_array_free(a, TRUE); g_strfreev(old);
}
static void sb_set_hidden(void *item, gpointer hide) {
    int h = GPOINTER_TO_INT(hide);
    if (sb_row.dev) { char *id = sb_dev_id(sb_row.dev); if (id) { sb_list_update("/hidden-devices", id, h); g_free(id); } }
    else if (sb_row.uri) sb_list_update("/hidden-bookmarks", sb_row.uri, h);
    for (GList *l = sb_views; l; l = l->next) gtk_widget_queue_draw(l->data);
}
extern void gtk_widget_destroy(void *);
static gboolean gtk_widget_destroy_idle(gpointer w) { gtk_widget_destroy(w); g_object_unref(w); return G_SOURCE_REMOVE; }
typedef struct { void *menu, *view, *ev; } SbPop;
extern void *gdk_event_copy(const void *); extern void gdk_event_free(void *), gtk_menu_attach_to_widget(void *, void *, void *), gtk_menu_popdown(void *);
static void sb_showall_done(void *menu, gpointer u) { g_idle_add((GSourceFunc)gtk_widget_destroy_idle, g_object_ref(menu)); }   /* the Show All menu is single-use: let go of it (and its grab) when it closes */
static void sb_menu_done(void *menu, gpointer u) { g_idle_add((GSourceFunc)gtk_widget_destroy_idle, menu); }
static gboolean sb_popup_idle(gpointer d) {
    SbPop *p = d; gtk_menu_attach_to_widget(p->menu, p->view, NULL); gtk_menu_popup_at_pointer(p->menu, p->ev); gdk_event_free(p->ev); g_free(p); return G_SOURCE_REMOVE;
}
static void sb_record(void *tv, void *ev) {
    PressEv *e = ev; void *path = NULL; TIter it; void *m = gtk_tree_view_get_model(tv);
    sb_clear_row();
    if (gtk_tree_view_get_path_at_pos(tv, (int)e->x, (int)e->y, &path, NULL, NULL, NULL) && gtk_tree_model_get_iter(m, &it, path)) {
        GValue v = G_VALUE_INIT; sb_row.valid = 1; sb_row.is_item = sb_col_bool(m, &it, 1); sb_row.hidden = !sb_col_bool(m, &it, 2);
        gtk_tree_model_get_value(m, &it, 11, &v); sb_row.type = g_value_get_uint(&v); g_value_unset(&v);
        gtk_tree_model_get_value(m, &it, 6, &v); if (G_VALUE_HOLDS_OBJECT(&v) && g_value_get_object(&v)) sb_row.uri = g_file_get_uri(g_value_get_object(&v)); g_value_unset(&v);
        gtk_tree_model_get_value(m, &it, 8, &v); if (G_VALUE_HOLDS_OBJECT(&v) && g_value_get_object(&v)) sb_row.dev = g_object_ref(g_value_get_object(&v)); g_value_unset(&v);
    }
    if (path) gtk_tree_path_free(path);
    if (!sb_row.is_item && e->button == 3) {                                              /* empty space or a group header: Thunar shows nothing, so show our own menu */
        void *menu = gtk_menu_new(), *it2 = gtk_check_menu_item_new_with_label("Show All");
        gtk_check_menu_item_set_active(it2, sb_show_all); g_signal_connect(it2, "activate", G_CALLBACK(sb_toggle_showall), NULL);
        gtk_menu_shell_append(menu, it2); gtk_widget_show_all(menu); g_object_set_data(menu, "fm-laid", (gpointer)1);
        gtk_menu_attach_to_widget(menu, tv, NULL); g_signal_connect(menu, "deactivate", G_CALLBACK(sb_showall_done), NULL); gtk_menu_popup_at_pointer(menu, ev); sb_press_view = NULL;                             /* inline, as before the idle experiment: the pointer grab also keeps Thunar's own section menu from opening */
    }
}
static void sb_menu_extras(void *menu) {
    if (!sb_row.valid || !sb_row.is_item || sb_row.type == 0) return;
    void *sp = gtk_separator_menu_item_new(); gtk_menu_shell_append(menu, sp); gtk_widget_show(sp);
    void *it;
    if (sb_row.hidden) { it = gtk_check_menu_item_new_with_label("Show"); gtk_check_menu_item_set_active(it, 0); g_signal_connect(it, "activate", G_CALLBACK(sb_set_hidden), GINT_TO_POINTER(0)); }
    else { it = gtk_menu_item_new_with_label("Hide"); g_signal_connect(it, "activate", G_CALLBACK(sb_set_hidden), GINT_TO_POINTER(1)); }
    gtk_menu_shell_append(menu, it); gtk_widget_show(it);
}
static int is_sidebar_menu(void *menu) { return sb_press_view && g_get_monotonic_time() - sb_press_us < 2000000; }
/* sidebar menu: only what makes sense for a Places / Devices / tree entry */
static const char *SB_KEEP[] = { "open", "open in new tab", "open in new window", "mount", "unmount", "eject", "disconnect", "safely remove", "remove shortcut", "rename shortcut", "properties...", NULL };
static void sidebar_menu_fix(void *menu) {
    GList *kids = gtk_container_get_children(menu); int prev_sep = 1;
    for (GList *l = kids; l; l = l->next) {
        void *w = l->data; int keep = 0;
        if (is_item(w) && !is_sep(w)) { const char *t = gtk_menu_item_get_label(w); if (t) { char *n = norm(t); for (int i = 0; SB_KEEP[i]; i++) if (!strcmp(n, SB_KEEP[i])) keep = 1; g_free(n); } }
        else if (is_sep(w)) keep = 2;
        if (keep == 2) { if (prev_sep) keep = 0; else prev_sep = 1; } else if (keep) prev_sep = 0;
        if (!keep) { gtk_widget_set_no_show_all(w, 1); gtk_widget_hide(w); }
    }
    g_list_free(kids);
    sb_menu_extras(menu);
}
static int relayout_context_menu(void *menu) {
    if (is_sidebar_menu(menu)) { sidebar_menu_fix(menu); return 1; }
    GList *kids = gtk_container_get_children(menu);
    int has_props = 0, has_key = 0, is_bg = 0;
    for (GList *l = kids; l; l = l->next) {
        if (!is_item(l->data) || is_sep(l->data)) continue;
        const char *t = gtk_menu_item_get_label(l->data); if (!t) continue;
        char *n = norm(t); if (!strcmp(n, "properties...")) has_props = 1; if (!strcmp(n, "open with") || !strcmp(n, "new folder")) has_key = 1; if (!strcmp(n, "create folder...")) is_bg = 1; g_free(n);
    }
    if (!has_props || !has_key) { g_list_free(kids); return 0; }
    void *slot[12] = {0};
    int exact_ow = 0;                                                                     /* folders / several files: a real "Open With" submenu exists */
    for (GList *l = kids; l; l = l->next) if (is_item(l->data) && !is_sep(l->data)) { const char *t = gtk_menu_item_get_label(l->data); if (t && want_rank(t) == 1) exact_ow = 1; }
    GList *flat_ow = NULL;                                                                /* a single file: Thunar only has flat 'Open With "App"' / 'Open With Other Application...' items */
    for (GList *l = kids; l; l = l->next) {
        void *w = l->data; int r = -1;
        if (is_item(w) && !is_sep(w)) { const char *t = gtk_menu_item_get_label(w); if (t) r = want_rank(t);
            if (r < 0 && t && !exact_ow) { char *n = norm(t); if (g_str_has_prefix(n, "open with")) { flat_ow = g_list_append(flat_ow, w); g_free(n); continue; } g_free(n); } }
        if (r > 0 && !slot[r]) { slot[r] = w; gtk_menu_item_set_label(w, PRETTY[r]); }
        else { gtk_widget_set_no_show_all(w, 1); gtk_widget_hide(w); }                   /* everything else (and duplicates) */
    }
    if (flat_ow) {                                                                        /* group them under one "Open With >" */
        void *ow = gtk_menu_item_new_with_label("Open With"), *ows = gtk_menu_new();
        for (GList *l = flat_ow; l; l = l->next) { void *w = l->data; g_object_ref(w); gtk_container_remove(menu, w); gtk_menu_shell_append(ows, w); gtk_widget_set_no_show_all(w, 0); gtk_widget_show(w); g_object_unref(w); }
        gtk_menu_item_set_submenu(ow, ows); gtk_widget_show(ows); gtk_widget_show(ow);
        gtk_menu_shell_append(menu, ow); slot[1] = ow; g_list_free(flat_ow);
    }
    /* "Menu >": proxies for the hidden menu bar's items, carrying the real submenus */
    void *win = thunar_toplevel(), *bar = win ? find_menubar(win) : NULL;
    if (bar) {
        void *mi = gtk_menu_item_new_with_label("Menu"), *sm = gtk_menu_new();
        GPtrArray *loans = g_ptr_array_new_with_free_func(on_loan_free);
        for (GList *l = gtk_container_get_children(bar); l; l = l->next) {
            void *orig = l->data;
            /* Thunar fills each menu bar submenu lazily, when the item gets "select"; do that now (while the submenu is still attached), then cancel the popup it starts */
            if (is_item(orig) && gtk_menu_item_get_submenu(orig)) { g_signal_emit_by_name(orig, "select"); g_signal_emit_by_name(orig, "deselect"); }
            void *sub = is_item(orig) ? gtk_menu_item_get_submenu(orig) : NULL; const char *t = is_item(orig) ? gtk_menu_item_get_label(orig) : NULL;
            if (!sub || !t) continue;
            char *nm = norm(t); if (nm[0]) nm[0] = g_ascii_toupper(nm[0]);
            void *proxy = gtk_menu_item_new_with_label(nm); g_free(nm);
            Loan *ln = g_new0(Loan, 1); ln->orig = orig; ln->proxy = proxy; ln->sub = sub;
            g_object_ref(sub); gtk_menu_item_set_submenu(orig, NULL); gtk_menu_item_set_submenu(proxy, sub); g_object_unref(sub);
            g_signal_connect(proxy, "destroy", G_CALLBACK(on_proxy_destroy), ln);
            g_ptr_array_add(loans, ln);
            gtk_menu_shell_append(sm, proxy); gtk_widget_show(proxy);
        }
        gtk_menu_item_set_submenu(mi, sm); gtk_widget_show(sm); gtk_widget_show(mi);
        g_object_set_data_full(menu, "fm-loans", loans, (GDestroyNotify)g_ptr_array_unref);
        g_signal_connect(menu, "deactivate", G_CALLBACK(on_ctx_deactivate), NULL);
        g_signal_connect(menu, "hide", G_CALLBACK(on_ctx_deactivate), NULL);                      /* popdown hides the menu: the reliable "closed" signal */
        g_signal_connect(menu, "unmap", G_CALLBACK(on_ctx_deactivate), NULL);
        g_signal_connect(menu, "destroy", G_CALLBACK(on_ctx_deactivate), NULL);
        slot[0] = mi; gtk_menu_shell_insert(menu, mi, 0);
    }
    int pos = 0, prevg = -1;
    for (int r = 0; r < 12; r++) if (slot[r]) {
        if (is_bg && bg_hidden(r)) { gtk_widget_set_no_show_all(slot[r], 1); gtk_widget_hide(slot[r]); continue; }
        int g = rank_group(r);
        if (prevg >= 0 && g != prevg) {
            void *sp = gtk_separator_menu_item_new(); gtk_menu_shell_insert(menu, sp, pos); gtk_widget_show(sp); gtk_menu_reorder_child(menu, sp, pos++); }
        prevg = g;
        gtk_menu_reorder_child(menu, slot[r], pos++); gtk_widget_set_no_show_all(slot[r], 0); gtk_widget_show(slot[r]);
    }
    g_list_free(kids);
    return 1;
}
/* ---- context menus do not "stick": once the pointer has been off the menu (and every submenu) for 50 ms, the whole menu closes. Event-driven: leave-notify on any menu in the tree arms a one-shot
   50 ms timeout, enter-notify on any of them (moving into a submenu) cancels it. ---- */
typedef struct { int type; void *window; signed char send_event; void *subwindow; unsigned time; double x, y, xr, yr; int mode, detail; } CrossEv;
extern void gtk_menu_shell_cancel(void *);
extern unsigned g_timeout_add(unsigned, int (*)(void *), void *);
extern int g_source_remove(unsigned);
#define AC_LEAVE_MS 1000  /* pointer off the whole menu tree this long -> the menu closes */
#define AC_FIRST_MS 1000  /* grace for the pointer to get onto a freshly opened menu (no enter event is delivered until it moves) */
static unsigned ac_id; static void *ac_top;
extern void *gtk_widget_get_window(void *);
extern int gtk_widget_get_allocated_height(void *);
static int ac_fire(void *u) { ac_id = 0; if (ac_top) gtk_menu_shell_cancel(ac_top); return 0; }
static void ac_cancel(void) { if (ac_id) { g_source_remove(ac_id); ac_id = 0; } }
typedef struct { int type; void *window; signed char send_event; unsigned time; double x, y; } MotEv;
extern void *gdk_device_get_window_at_position(void *, int *, int *), *gdk_window_get_toplevel(void *);
/* Wayland keeps sending motion to the popup after the pointer has left it, but with the PARENT window's coordinates (which can fall inside the menu's rectangle), so coordinates are useless:
   ask GDK which surface really has the pointer and compare its toplevel with this menu's own. */
static void ac_judge(void *w, double x, double y) {
    void *dev = gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_display_get_default())), *at = dev ? gdk_device_get_window_at_position(dev, NULL, NULL) : NULL, *mine = gtk_widget_get_window(w);
    int in = at && mine && gdk_window_get_toplevel(at) == gdk_window_get_toplevel(mine);
    if (in) ac_cancel(); else if (!ac_id) ac_id = g_timeout_add(AC_LEAVE_MS, ac_fire, NULL);
}
static gboolean ac_motion(void *w, void *ev, gpointer u) { MotEv *m = ev; ac_judge(w, m->x, m->y); return FALSE; }
static gboolean ac_enter(void *w, void *ev, gpointer u) { CrossEv *c = ev; ac_judge(w, c->x, c->y); return FALSE; }
/* a popup gets no further motion after the pointer leaves it: arm on a normal crossing that is not into a child window; enter/motion on any menu of the tree cancels via ac_judge */
static gboolean ac_leave(void *w, void *ev, gpointer u) { CrossEv *c = ev; if (c->mode == 0 && c->detail != 2 /* GDK_NOTIFY_INFERIOR */ && !ac_id) ac_id = g_timeout_add(AC_LEAVE_MS, ac_fire, NULL); return FALSE; }
static void ac_gone(void *w, gpointer u) { ac_cancel(); if (ac_top == w) ac_top = NULL; }
static void ac_attach(void *menu, int top) {
    if (g_object_get_data(menu, "fm-ac")) { if (top) { ac_top = menu; ac_cancel(); ac_id = g_timeout_add(AC_FIRST_MS, ac_fire, NULL); } return; }   /* menu reused: re-arm only */
    g_object_set_data(menu, "fm-ac", (gpointer)1);
    g_signal_connect(menu, "enter-notify-event", G_CALLBACK(ac_enter), NULL); g_signal_connect(menu, "motion-notify-event", G_CALLBACK(ac_motion), NULL);   /* Wayland popups often get motion but no enter */
    g_signal_connect(menu, "leave-notify-event", G_CALLBACK(ac_leave), NULL);
    if (top) { ac_top = menu; ac_cancel(); ac_id = g_timeout_add(AC_FIRST_MS, ac_fire, NULL);   /* the pointer may never enter the menu (no leave event then): arm now, an enter cancels it */
    g_signal_connect(menu, "unmap", G_CALLBACK(ac_gone), NULL); g_signal_connect(menu, "destroy", G_CALLBACK(ac_gone), NULL); }
    for (GList *l = gtk_container_get_children(menu); l; l = l->next) if (is_item(l->data) && !is_sep(l->data)) { void *s = gtk_menu_item_get_submenu(l->data); if (s) ac_attach(s, 0); }
}
#define POPUP_HOOK(name, sig, call) \
    void name sig { static void (*real) sig; if (!real) real = dlsym(RTLD_NEXT, #name); load_hide_list(); if (!g_object_get_data(menu, "fm-laid")) { g_object_set_data(menu, "fm-laid", (gpointer)1); if (relayout_context_menu(menu)) { ac_attach(menu, 1); real call; return; } } if (hide_n) prune_menu(menu); ac_attach(menu, 1); real call; }
POPUP_HOOK(gtk_menu_popup_at_pointer, (void *menu, const void *ev), (menu, ev))
POPUP_HOOK(gtk_menu_popup_at_rect, (void *menu, void *w, const void *r, int a, int b, const void *ev), (menu, w, r, a, b, ev))
POPUP_HOOK(gtk_menu_popup_at_widget, (void *menu, void *w, int a, int b, const void *ev), (menu, w, a, b, ev))

/* ---- sort hidden (dot) files/folders after everything else (Thunar has no such option) ----
   Wraps the comparator Thunar passes to GSequence sort/insert: hidden-ness first, then Thunar's own order (folders-first etc. stays inside each group). */
extern char *thunarx_file_info_get_name(void *) __attribute__((weak));
typedef struct { GCompareDataFunc cmp; gpointer data; } SortWrap;
extern void *g_type_class_peek(GType);
/* Thunar's list rows are structs whose FIRST field is the ThunarFile*; recognise one by comparing that object's class pointer (no blind GObject deref). */
static int is_hidden_item(gconstpointer row) {
    static void *cls; static int init;
    if (!init) { GType tf = g_type_from_name("ThunarFile"); cls = tf ? g_type_class_peek(tf) : NULL; init = 1; }
    if (!cls || !row) return -1;
    void *file = *(void *const *)row;
    if (!file || ((uintptr_t)file & 7) || *(void **)file != cls) return -1;
    char *n = thunarx_file_info_get_name ? thunarx_file_info_get_name(file) : NULL;
    int h = n && n[0] == '.'; g_free(n); return h;
}
/* two folders while sorting by Size / Date Modified: compare the recursive totals / newest inner modification time (unknown = smallest until the job finishes and re-sorts). 0 = not handled, use Thunar's comparator. */
static int size_dir_cmp(gconstpointer a, gconstpointer b, gpointer model, gint *res) {
    int col, ord; void *fa = *(void *const *)a, *fb = *(void *const *)b;
    if (!model || !thunarx_file_info_is_directory(fa) || !thunarx_file_info_is_directory(fb)) return 0;
    if (!gtk_tree_sortable_get_sort_column_id(model, &col, &ord) || (col != 11 && col != 12 && col != 2)) return 0;
    GFile *la = thunarx_file_info_get_location(fa), *lb = thunarx_file_info_get_location(fb); gint64 ba = -1, bb = -1, ma = 0, mb = 0; int sa = la ? fs_get(la, NULL, model, &ba, &ma) : 0, sb = lb ? fs_get(lb, NULL, model, &bb, &mb) : 0;
    if (col == 2) { ba = ma; bb = mb; }
    if (la) g_object_unref(la); if (lb) g_object_unref(lb);
    if (!sa || !sb) return 0;
    if (sa == 1) ba = -1; if (sb == 1) bb = -1;
    if (ba == bb) return 0;
    *res = (ba < bb ? -1 : 1) * (ord == 0 /* GTK_SORT_ASCENDING */ ? 1 : -1); return 1;
}
static gint wrap_cmp(gconstpointer a, gconstpointer b, gpointer d) {
    SortWrap *w = d; int ha = is_hidden_item(a), hb = is_hidden_item(b);
    if (ha >= 0 && hb >= 0 && ha != hb) return ha ? 1 : -1;
    if (ha >= 0 && hb >= 0) { gint r; if (size_dir_cmp(a, b, w->data, &r)) return r; }
    return w->cmp(a, b, w->data);
}
/* only calls made by Thunar's own code (other libraries sort unrelated sequences) */
static int from_thunar(void *ra) { Dl_info di; return dladdr(ra, &di) && di.dli_fname && strstr(di.dli_fname, "thunar") && !strstr(di.dli_fname, "libthunarx"); }
void g_sequence_sort(GSequence *s, GCompareDataFunc f, gpointer d) {
    static void (*real)(GSequence *, GCompareDataFunc, gpointer); if (!real) real = dlsym(RTLD_NEXT, "g_sequence_sort");
    if (!from_thunar(__builtin_return_address(0))) { real(s, f, d); return; } SortWrap w = { f, d }; real(s, wrap_cmp, &w);
}
GSequenceIter *g_sequence_insert_sorted(GSequence *s, gpointer data, GCompareDataFunc f, gpointer d) {
    static GSequenceIter *(*real)(GSequence *, gpointer, GCompareDataFunc, gpointer); if (!real) real = dlsym(RTLD_NEXT, "g_sequence_insert_sorted");
    if (!from_thunar(__builtin_return_address(0))) return real(s, data, f, d); SortWrap w = { f, d }; return real(s, data, wrap_cmp, &w);
}
void g_sequence_sort_changed(GSequenceIter *i, GCompareDataFunc f, gpointer d) {
    static void (*real)(GSequenceIter *, GCompareDataFunc, gpointer); if (!real) real = dlsym(RTLD_NEXT, "g_sequence_sort_changed");
    if (!from_thunar(__builtin_return_address(0))) { real(i, f, d); return; } SortWrap w = { f, d }; real(i, wrap_cmp, &w);
}

/* Thunar's icon renderer paints hidden items (dot-files / dot-folders) at alpha 0.75 (found with a cairo_paint_with_alpha tracer: thunar +57280, 0.75 for hidden, 1.00 for the rest). Paint them at full opacity:
   the only dimming wanted is the inactive split-view pane (CSS opacity). Only Thunar's own call sites; exactly 0.75, so any other fade (e.g. cut files) is untouched. */
void cairo_paint_with_alpha(void *cr, double a) {
    static void (*real)(void *, double); if (!real) real = dlsym(RTLD_NEXT, "cairo_paint_with_alpha");
    if (a > 0.74 && a < 0.76 && from_thunar(__builtin_return_address(0))) a = 1.0;
    real(cr, a);
}

/* ---- bookmarks persistence: thunar-fm runs Thunar with a private XDG_CONFIG_HOME farm that is rebuilt at every start; gtk-3.0/bookmarks in it is a symlink to the real file, but Thunar saves
   it by writing a temp file and rename()-ing it over the link, which replaces the link with a plain file in the throw-away farm. After such a rename, copy the new content to the real file. ---- */
int rename(const char *from, const char *to) {
    static int (*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "rename");
    int r = real(from, to);
    if (r == 0 && to && g_str_has_suffix(to, "/fm-cfg/gtk-3.0/bookmarks")) {
        char *data = NULL; gsize len = 0; char *dst = g_build_filename(g_get_home_dir(), ".config", "gtk-3.0", "bookmarks", NULL);
        if (g_file_get_contents(to, &data, &len, NULL)) { g_file_set_contents(dst, data, len, NULL); g_free(data); }
        g_free(dst);
    }
    return r;
}
