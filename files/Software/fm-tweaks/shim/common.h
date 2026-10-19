// common.h - shared by every shim translation unit: Qt includes, the HOOK macro, runtime-config + version-gate API.
//
// HOW THE SHIM WORKS: libdolphin-tweaks.so is LD_PRELOADed into Dolphin. Every `HOOK(...)` below defines a function whose symbol name is the
// mangled name of an exported libdolphinprivate / KF6 function, so Dolphin's own calls (made through the PLT / vtable relocations) land here
// first; the hook calls the real implementation with `nextSym` (dlsym RTLD_NEXT) when it wants stock behavior.
// A wrong mangled name builds fine and silently hooks nothing: always run tests/verify.sh (it checks every hook against LD_DEBUG=bindings).
#pragma once
#include <QAbstractScrollArea>
#include <QApplication>
#include <QByteArray>
#include <QColor>
#include <QCursor>
#include <QDir>
#include <QElapsedTimer>
#include <QEvent>
#include <QFile>
#include <QGraphicsOpacityEffect>
#include <QGraphicsWidget>
#include <QGuiApplication>
#include <QHash>
#include <QImage>
#include <QLabel>
#include <QList>
#include <QPaintEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPalette>
#include <QPixmap>
#include <QPointF>
#include <QPointer>
#include <QScrollBar>
#include <QSettings>
#include <QStaticText>
#include <QString>
#include <QStyleOption>
#include <QTimer>
#include <QVariant>
#include <QWheelEvent>
#include <QWindow>
#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <dlfcn.h>
#include <vector>

// HOOK(ret, name, "mangled", params...) { body }  - the mangled name appears exactly once; name##_sym is the same string for nextSym().
#define HOOK(RET, NAME, MANGLED, ...)                                                                                                         \
    static const char *const NAME##_sym = MANGLED;                                                                                           \
    extern "C" RET NAME(__VA_ARGS__) __asm__(MANGLED);                                                                                        \
    extern "C" RET NAME(__VA_ARGS__)

template<class Fn>
static inline Fn nextSym(const char *sym)
{
    return reinterpret_cast<Fn>(dlsym(RTLD_NEXT, sym));   // the implementation this hook replaced; nullptr if the symbol is gone (callers must check)
}

// Inactive split pane state, shared by the pane / arrow code (core.cpp).
double paneKeep();                          // share of text/icon strength kept in an inactive pane (runtime conf `inactivetext`)
extern thread_local bool g_inactivePaint;   // set while an item of an inactive pane paints

// Runtime values written by `dolphin-tweaks apply` into <out>/breeze-colors.conf (key=value lines; read once, cached).
QColor rtColor(const char *key);                      // invalid QColor when missing
double rtDouble(const char *key, double fallback);

// Version gate: hooks that touch Dolphin's private class layout (compiled against kitemviews headers of ONE Dolphin version) run only when
// the running Dolphin is on the tested list (DT_TESTED_VERSIONS, set by build.sh); otherwise they pass through to stock behavior and say so once
// on stderr. DOLPHIN_TWEAKS_FORCE=1 overrides.
bool shimOk();
