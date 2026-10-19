// qt-fm.cpp - replaces qt6ct for the Qt6 apps we wrap (SMPlayer, Konsole): applies the palette, font and icon theme that fm-tweaks generates.
// LD_PRELOAD it (together with qt-noicons) and set QT_STYLE_OVERRIDE=Breeze; no QT_QPA_PLATFORMTHEME needed. Colours come from ~/.config/fm-tweaks/qt-theme.conf (override: FM_QT_THEME), written by `fm-tweaks apply`.
// build: g++ -std=c++17 -shared -fPIC -o ~/.themes/qt-fm/libqt-fm.so qt-fm.cpp $(pkg-config --cflags --libs Qt6Widgets)
#include <QApplication>
#include <QHeaderView>
#include <QTableView>
#include <QPalette>
#include <QFont>
#include <QIcon>
#include <QSettings>
#include <QStringList>
#include <QDir>
#include <QMainWindow>
#include <QMenuBar>
#include <QToolBar>
#include <QLayout>
#include <QDockWidget>
#include <QShortcut>
#include <QKeySequence>
#include <QTimer>
#include <QFileInfo>
#include <dlfcn.h>
static QColor argb(QString s) { s = s.trimmed(); if (s.startsWith('#')) s.remove(0, 1); bool ok; unsigned v = s.toUInt(&ok, 16); if (!ok) return QColor(); return s.size() <= 6 ? QColor((v >> 16) & 255, (v >> 8) & 255, v & 255) : QColor((v >> 16) & 255, (v >> 8) & 255, v & 255, (v >> 24) & 255); }
static bool applied = false;
static void apply() {
    if (applied) return; applied = true;
    QString path = qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf");
    QSettings c(path, QSettings::IniFormat); if (c.status() != QSettings::NoError || c.allKeys().isEmpty()) return;
    QPalette p = QApplication::palette();
    const QPalette::ColorGroup groups[3] = { QPalette::Active, QPalette::Inactive, QPalette::Disabled };
    const char *keys[3] = { "colors/active", "colors/inactive", "colors/disabled" };
    for (int g = 0; g < 3; g++) { QStringList l = c.value(keys[g]).toStringList(); for (int r = 0; r < l.size() && r < QPalette::NColorRoles; r++) { QColor col = argb(l[r]); if (col.isValid() && r != 17) p.setColor(groups[g], (QPalette::ColorRole)r, col); } }
    QApplication::setPalette(p);
    QString f = c.value("fonts/general").toStringList().join(","); if (!f.isEmpty()) { QStringList a = f.split(','); QFont ft(a[0]); if (a.size() > 1) ft.setPointSizeF(a[1].toDouble()); QApplication::setFont(ft); }
    QString ic = c.value("icons/theme").toString(); if (!ic.isEmpty()) QIcon::setThemeName(ic);
}
/* FM_QT_DEBUG=1: log Resize/Move/Show of top-level windows with ms timestamps (stderr) - for chasing window-size glitches */
#include <QElapsedTimer>
#include <QResizeEvent>
#include <QMoveEvent>
struct DebugFilter : QObject {
    QElapsedTimer t;
    DebugFilter() { t.start(); }
    bool eventFilter(QObject *o, QEvent *e) override {
        auto *w = qobject_cast<QWidget *>(o);
        if (w && w->isWindow() && (e->type() == QEvent::Resize || e->type() == QEvent::Move || e->type() == QEvent::Show || e->type() == QEvent::WindowStateChange)) {
            QString d = e->type() == QEvent::Resize ? QString("%1x%2").arg(static_cast<QResizeEvent *>(e)->size().width()).arg(static_cast<QResizeEvent *>(e)->size().height()) : e->type() == QEvent::Move ? QString("%1,%2").arg(static_cast<QMoveEvent *>(e)->pos().x()).arg(static_cast<QMoveEvent *>(e)->pos().y()) : QString();
            fprintf(stderr, "[fmdbg %6lld ms] %s#%s type=%d %s\n", (long long)t.elapsed(), w->metaObject()->className(), qPrintable(w->objectName()), (int)e->type(), qPrintable(d));
        }
        return false;
    }
};

/* re-hides a menu bar that the app shows on its own (e.g. when leaving fullscreen) unless the user asked for it with the toggle key */
struct MbGuard : QObject {
    QMenuBar *mb; explicit MbGuard(QMenuBar *m) : QObject(m), mb(m) {}
    bool eventFilter(QObject *o, QEvent *e) override {
        if (o == mb && e->type() == QEvent::Show && !mb->property("fm-mb-wanted").toBool()) QTimer::singleShot(0, mb, [m = mb] { if (!m->property("fm-mb-wanted").toBool()) m->setVisible(false); });
        return false;
    }
};
/* ---- per-app interface tweaks, [ui.<appname>] in qt-theme.conf: menubar_hidden=true, menubar_key=Ctrl+M, hide_dock_titles=true ----
   Checked every 500 ms (windows appear late); each main window is handled once. */
static void ui_tweaks() {
    static QSettings *c = nullptr; static QString app;
    if (!c) { app = QFileInfo(QCoreApplication::applicationFilePath()).fileName().toLower(); c = new QSettings(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat); }
    c->sync(); QString sec = "ui." + app + "/";
    bool hideBar = c->value(sec + "menubar_hidden", false).toBool(), hideDock = c->value(sec + "hide_dock_titles", false).toBool(); QString key = c->value(sec + "menubar_key").toString();
    bool hideLogo = c->value(sec + "hide_logo", false).toBool(), hideTb = c->value(sec + "hide_playlist_toolbar", false).toBool();
    int numW = c->value(sec + "playlist_number_col_width", 0).toInt();   // px; playlist's first (number) column starts this narrow, still draggable
    auto kill = [](QWidget *x) { if (x->maximumHeight() != 0) { x->setMaximumSize(0, 0); x->hide(); } };   // max size 0 survives the app calling show() again
    for (QWidget *w : QApplication::topLevelWidgets()) {
        if (hideLogo) for (QWidget *l : w->findChildren<QWidget *>("mplayerwindowlogo")) kill(l);
        if (hideTb) for (QDockWidget *d : w->findChildren<QDockWidget *>("playlistdock")) for (QToolBar *t : d->findChildren<QToolBar *>()) kill(t);
        if (numW > 0) for (QTableView *v : w->findChildren<QTableView *>()) {
            QHeaderView *h = v->horizontalHeader(); if (!h || v->property("fm-numcol").toBool() || !v->isVisible() || h->count() < 2 || h->length() < 50) continue;
            v->setProperty("fm-numcol", true); h->setMinimumSectionSize(qMin(h->minimumSectionSize(), numW)); h->setSectionResizeMode(0, QHeaderView::Interactive); h->resizeSection(0, numW);
        }
        auto *mw = qobject_cast<QMainWindow *>(w); if (!mw) continue;
        if (hideDock) for (QDockWidget *d : mw->findChildren<QDockWidget *>()) if (!d->titleBarWidget()) {
            d->setTitleBarWidget(new QWidget(d));
            if (d->widget() && d->widget()->layout()) { QMargins m = d->widget()->layout()->contentsMargins(); d->widget()->layout()->setContentsMargins(m.left(), 0, m.right(), m.bottom()); }   // also drop the margin that was a grey strip above the content
        }
        QMenuBar *mb = mw->findChild<QMenuBar *>(); if (!mb) continue;
        if (hideBar && !mw->property("fm-ui-done").toBool()) {   // the bar is "wanted" only after the toggle key; anything else that shows it (SMPlayer does on leaving fullscreen) is undone
            mb->setProperty("fm-mb-wanted", false); mb->installEventFilter(new MbGuard(mb)); mb->setVisible(false);
        }
        if (hideBar && !mb->property("fm-mb-wanted").toBool() && mb->isVisible()) mb->setVisible(false);   // safety net (tick)
        if (mw->property("fm-ui-done").toBool()) continue;
        mw->setProperty("fm-ui-done", true);
        if (!key.isEmpty()) { auto *sc = new QShortcut(QKeySequence(key), mw); sc->setContext(Qt::ApplicationShortcut); QObject::connect(sc, &QShortcut::activated, mb, [mb, hideBar] { bool want = !mb->isVisible(); mb->setProperty("fm-mb-wanted", want); mb->setVisible(want); (void)hideBar; }); }
    }
}
/* Applies the tweaks the moment a main window is about to be shown (QShowEvent is sent before the platform window is mapped), so the menu bar / dock titles / logo
   never appear for a moment; the 500 ms tick stays for widgets that only exist later. */
struct ShowFilter : QObject {
    bool eventFilter(QObject *o, QEvent *e) override {
        if (e->type() == QEvent::Show && qobject_cast<QMainWindow *>(o) && static_cast<QWidget *>(o)->isWindow()) ui_tweaks();
        return false;
    }
};
static void install_show_filter() { static bool done = false; if (done) return; done = true; QCoreApplication::instance()->installEventFilter(new ShowFilter); }   // SMPlayer shows its main window BEFORE exec()
/* apply right after the QApplication object exists - before any widget or icon is created (qt6ct did the same via the platform theme) */
extern "C" void _ZN12QApplicationC2ERiPPci(void *self, int &argc, char **argv, int flags) {
    static void (*real)(void *, int &, char **, int) = (void (*)(void *, int &, char **, int))dlsym(RTLD_NEXT, "_ZN12QApplicationC2ERiPPci");
    real(self, argc, argv, flags);
    apply(); install_show_filter();
}
extern "C" void _ZN12QApplicationC1ERiPPci(void *self, int &argc, char **argv, int flags) {
    static void (*real)(void *, int &, char **, int) = (void (*)(void *, int &, char **, int))dlsym(RTLD_NEXT, "_ZN12QApplicationC1ERiPPci");
    real(self, argc, argv, flags);
    apply(); install_show_filter();
}
extern "C" int _ZN16QCoreApplication4execEv() {
    static int (*real)() = (int (*)())dlsym(RTLD_NEXT, "_ZN16QCoreApplication4execEv");
    if (qobject_cast<QApplication *>(QCoreApplication::instance())) { apply(); if (qEnvironmentVariableIsSet("FM_QT_DEBUG")) QCoreApplication::instance()->installEventFilter(new DebugFilter); auto *t = new QTimer(QCoreApplication::instance()); QObject::connect(t, &QTimer::timeout, [] { ui_tweaks(); }); t->start(500); }
    return real();
}
