#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#define SETATTR "_ZN16QCoreApplication12setAttributeEN2Qt20ApplicationAttributeEb"

/* Qt6: QMenu (QtWidgets) checks QAction::isIconVisibleInMenu() per-action; force it off. */
int _ZNK7QAction19isIconVisibleInMenuEv(void *self) { (void)self; return 0; }

/* Qt6: also hide the right-aligned shortcut text in context menus (QAction::isShortcutVisibleInContextMenu(), Qt 5.10+) -
 * it was widening every menu for an accelerator hint nobody uses from the mouse. */
int _ZNK7QAction30isShortcutVisibleInContextMenuEv(void *self) { (void)self; return 0; }

/* Qt5: Widgets honors the app-wide AA_DontShowIconsInMenus (2) attribute; force it on even if
 * an app tries to flip it back off (e.g. SMPlayer). */
void _ZN16QCoreApplication12setAttributeEN2Qt20ApplicationAttributeEb(int attr, int on) {
    static void (*real)(int, int);
    if (!real) real = dlsym(RTLD_NEXT, SETATTR);
    if (attr == 2) on = 1;
    if (real) real(attr, on);
}

/* Children (shells in Konsole, apps launched from it) must not inherit the preload. */
__attribute__((constructor)) static void noicons_init(void) {
    void (*real)(int, int) = dlsym(RTLD_NEXT, SETATTR);
    if (real) real(2, 1);
    unsetenv("LD_PRELOAD");
}
