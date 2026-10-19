// tools/grab.cpp - TEST HELPER (not installed). Preload into a throwaway Dolphin run on QT_QPA_PLATFORM=offscreen: a few seconds after the
// event loop starts it saves a PNG of the main window to $GRAB_OUT (default ./window.png) and quits. Used by tests/render.sh for golden-image comparisons.
// Hooks QCoreApplication::exec (as the old dye harness did); never loads into child processes because the shim scrubs LD_PRELOAD.
#include <QApplication>
#include <QTimer>
#include <QWidget>
#include <dlfcn.h>
#include <cstdlib>
#include <cstdio>

extern "C" int grab_exec() __asm__("_ZN16QCoreApplication4execEv");
extern "C" int grab_exec()
{
    using Fn = int (*)();
    static Fn orig = reinterpret_cast<Fn>(dlsym(RTLD_NEXT, "_ZN16QCoreApplication4execEv"));
    if (QCoreApplication::instance() && qobject_cast<QApplication *>(QCoreApplication::instance())) {
        const int ms = getenv("GRAB_MS") ? atoi(getenv("GRAB_MS")) : 4000;
        QTimer::singleShot(ms, qApp, [] {
            const QString out = getenv("GRAB_OUT") ? QString::fromLocal8Bit(getenv("GRAB_OUT")) : QStringLiteral("window.png");
            for (QWidget *top : QApplication::topLevelWidgets()) {
                if (top->inherits("DolphinMainWindow")) {
                    int w = 1100, h = 700;
                    if (getenv("GRAB_SIZE")) { sscanf(getenv("GRAB_SIZE"), "%dx%d", &w, &h); }
                    top->resize(w, h);
                    if (getenv("GRAB_EDIT")) {   // put the path bar into edit mode (exported KUrlNavigator::setUrlEditable(bool))
                        using F = void (*)(void *, bool);
                        auto f = reinterpret_cast<F>(dlsym(RTLD_DEFAULT, "_ZN13KUrlNavigator14setUrlEditableEb"));
                        for (QWidget *c : top->findChildren<QWidget *>()) {
                            if (f && c->inherits("KUrlNavigator")) {
                                f(c, true);
                                fprintf(stderr, "GRAB editable on\n");
                                if (getenv("GRAB_DUMP")) { for (QWidget *k : c->findChildren<QWidget *>()) { QString chain; for (const QMetaObject *m = k->metaObject(); m; m = m->superClass()) chain += QString::fromLatin1(m->className()) + " > "; fprintf(stderr, "GRAB child %s\n", qPrintable(chain)); } }
                            }
                        }
                    }
                    QTimer::singleShot(800, top, [top, out] {
                        top->grab().save(out);
                        qApp->quit();
                    });
                    return;
                }
            }
            qApp->quit();
        });
    }
    return orig ? orig() : 1;
}
