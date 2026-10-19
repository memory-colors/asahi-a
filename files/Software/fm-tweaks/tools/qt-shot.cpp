// qt-shot.cpp - drive a Qt6 widget app from outside and screenshot its windows (GNOME blocks real screenshots). DEV TOOL, not part of the setup.
// build: g++ -std=c++17 -shared -fPIC -o qt-shot.so qt-shot.cpp $(pkg-config --cflags --libs Qt6Widgets)
// run:   QT_QPA_PLATFORM=offscreen LD_PRELOAD=$PWD/qt-shot.so QTSHOT_CMD=cmds.txt QTSHOT_OUT=outdir <app>
// cmds.txt: one command per line, executed one per ~400 ms tick, new lines are picked up while running:
//   dump                      -> outdir/dump.txt: top-level widgets, menubar tree, QActions
//   shot NAME [idx]           -> grab top-level #idx (default 0 = first visible) to outdir/NAME.png
//   shotall NAME              -> grab every visible top-level to outdir/NAME-<n>-<class>.png
//   menu TITLE NAME           -> popup the menubar menu with that title (text without &), grab it
//   trigger ACTIONNAME        -> QAction::trigger() by objectName (opens dialogs)
//   key KEY                   -> send a key to the active window (e.g. Escape)
//   widgets NAME              -> dump the widget tree of the active/top window to outdir/NAME.txt (class, objectName, palette role colours)
//   tree NAME                 -> widget tree of the main window (top-level #0) to outdir/NAME.txt
//   pages NAME                -> in the active dialog: select every row of its first QListWidget (settings pages) and grab the dialog as NAME-<row>.png
//   tabs NAME                 -> same for the first QTabWidget (tab pages)
//   wait                      -> no-op tick
//   close                     -> close the active modal/top window (not the main one)
//   quit
#include <QApplication>
#include <QWidget>
#include <QMenuBar>
#include <QMenu>
#include <QAction>
#include <QTimer>
#include <QFile>
#include <QTextStream>
#include <QPixmap>
#include <QDir>
#include <QKeyEvent>
#include <QTabWidget>
#include <QDialog>
#include <QListWidget>
#include <QWindow>
#include <QKeySequence>
#include <QtTest/QtTest>
#include <dlfcn.h>
static QStringList lines; static int done = 0; static QString outdir;
static QList<QWidget*> tops() { QList<QWidget*> r; for (QWidget *w : QApplication::topLevelWidgets()) if (w->isVisible() && w->width() > 20) r << w; return r; }
static void dumpTree(QTextStream &o, QWidget *w, int d) {
    o << QString(d * 2, ' ') << w->metaObject()->className() << "#" << w->objectName() << " " << w->width() << "x" << w->height() << (w->isVisible() ? "" : " (hidden)") << "\n";
    for (QObject *c : w->children()) if (auto *cw = qobject_cast<QWidget *>(c)) dumpTree(o, cw, d + 1);
}
static void dumpMenu(QTextStream &o, QMenu *m, int d) {
    for (QAction *a : m->actions()) { o << QString(d * 2, ' ') << (a->isSeparator() ? "-----" : a->text()) << "  [" << a->objectName() << "]" << (a->menu() ? " >" : "") << "\n"; if (a->menu()) dumpMenu(o, a->menu(), d + 1); }
}
static QWidget *dlg() {   /* the open dialog: modal one, else the first visible top-level that isn't the main window */
    if (QApplication::activeModalWidget()) return QApplication::activeModalWidget();
    for (QWidget *w : tops()) if (QString(w->metaObject()->className()) != "DefaultGui" && !w->inherits("QMenu") && !w->inherits("QMainWindow")) return w;
    return nullptr;
}
static void tick() {
    QDir().mkpath(outdir);
    QFile f(qgetenv("QTSHOT_CMD")); if (f.open(QIODevice::ReadOnly)) { lines = QString::fromUtf8(f.readAll()).split('\n', Qt::SkipEmptyParts); }
    if (done >= lines.size()) return;
    QStringList a = lines[done++].split(' ', Qt::SkipEmptyParts); if (a.isEmpty()) return;
    QString op = a[0];
    auto T = tops();
    if (op == "dump") {
        QFile o(outdir + "/dump.txt"); o.open(QIODevice::WriteOnly | QIODevice::Truncate); QTextStream s(&o);
        for (QWidget *w : QApplication::topLevelWidgets()) if (w->isVisible()) { s << "== TOP " << w->metaObject()->className() << "#" << w->objectName() << " " << w->width() << "x" << w->height() << "\n"; if (auto *mw = w->findChild<QMenuBar *>()) { s << "-- menubar\n"; for (QAction *ac : mw->actions()) { s << ac->text() << "  [" << ac->objectName() << "]\n"; if (ac->menu()) dumpMenu(s, ac->menu(), 1); } } }
        s << "== ALL ACTIONS\n"; for (QAction *ac : QApplication::activeWindow() ? QApplication::activeWindow()->findChildren<QAction *>() : (T.isEmpty() ? QList<QAction *>() : T[0]->findChildren<QAction *>())) s << ac->objectName() << " | " << ac->text() << "\n";
    } else if (op == "shot" && a.size() >= 2) {
        int i = a.size() > 2 ? a[2].toInt() : 0; if (i < T.size()) T[i]->grab().save(outdir + "/" + a[1] + ".png");
    } else if (op == "shotall" && a.size() >= 2) {
        int n = 0; for (QWidget *w : T) w->grab().save(outdir + "/" + a[1] + "-" + QString::number(n++) + "-" + w->metaObject()->className() + ".png");
    } else if (op == "menu" && a.size() >= 3) {
        QString title = a[1].replace('_', ' '); QWidget *mw = T.isEmpty() ? nullptr : T[0];
        if (auto *bar = mw ? mw->findChild<QMenuBar *>() : nullptr) for (QAction *ac : bar->actions()) if (ac->text().remove('&') == title && ac->menu()) { QMenu *m = ac->menu(); m->popup(mw->mapToGlobal(QPoint(40, 30))); QApplication::processEvents(); if (m->actions().size() > 1) m->setActiveAction(m->actions().at(m->actions().size() > 2 ? 1 : 0)); QApplication::processEvents(); m->grab().save(outdir + "/" + a[2] + ".png"); m->hide(); }
    } else if (op == "trigger" && a.size() >= 2) {
        QWidget *w = T.isEmpty() ? nullptr : T[0]; if (w) for (QAction *ac : w->findChildren<QAction *>()) if (ac->objectName() == a[1]) { QTimer::singleShot(0, ac, [ac] { ac->trigger(); }); break; }
    } else if (op == "key" && a.size() >= 2) {
        QWidget *w = QApplication::activeWindow(); if (w) { int k = a[1] == "Escape" ? Qt::Key_Escape : Qt::Key_Return; QKeyEvent p(QEvent::KeyPress, k, Qt::NoModifier), r(QEvent::KeyRelease, k, Qt::NoModifier); QApplication::sendEvent(w, &p); QApplication::sendEvent(w, &r); }
    } else if (op == "widgets" && a.size() >= 2) {
        QWidget *w = dlg(); if (w) { QFile o(outdir + "/" + a[1] + ".txt"); o.open(QIODevice::WriteOnly | QIODevice::Truncate); QTextStream s(&o); dumpTree(s, w, 0); }
    } else if (op == "tree" && a.size() >= 2) {   /* widget tree of top-level #0 (the main window) */
        if (!T.isEmpty()) { QFile o(outdir + "/" + a[1] + ".txt"); o.open(QIODevice::WriteOnly | QIODevice::Truncate); QTextStream s(&o); dumpTree(s, T[0], 0); }
    } else if (op == "pages" && a.size() >= 2) {
        QWidget *w = dlg();
        if (w) if (auto *lw = w->findChild<QListWidget *>()) for (int r = 0; r < lw->count(); r++) { lw->setCurrentRow(r); QApplication::processEvents(); w->grab().save(outdir + "/" + a[1] + "-" + QString::number(r) + ".png"); }
    } else if (op == "tabs" && a.size() >= 2) {
        QWidget *w = dlg();
        if (w) if (auto *tw = w->findChild<QTabWidget *>()) for (int r = 0; r < tw->count(); r++) { tw->setCurrentIndex(r); QApplication::processEvents(); w->grab().save(outdir + "/" + a[1] + "-" + QString::number(r) + ".png"); }
    } else if (op == "keyseq" && a.size() >= 2) {   /* e.g. keyseq Ctrl+M : goes through the window handle so QShortcut sees it */
        QWidget *w = T.isEmpty() ? nullptr : T[0]; QKeySequence ks(a[1]); if (w && ks.count()) { int k = ks[0].toCombined(); QTest::keyClick(w, Qt::Key(k & ~Qt::KeyboardModifierMask), Qt::KeyboardModifiers(k & Qt::KeyboardModifierMask)); }
    } else if (op == "wait") {
    } else if (op == "close") {
        QWidget *w = dlg(); if (w) w->close();
    } else if (op == "quit") { QApplication::quit(); }
}
extern "C" int _ZN16QCoreApplication4execEv() {
    static int (*real)() = (int (*)())dlsym(RTLD_NEXT, "_ZN16QCoreApplication4execEv");
    outdir = qEnvironmentVariable("QTSHOT_OUT", "/tmp/qtshot");
    if (!qEnvironmentVariableIsEmpty("QTSHOT_CMD")) { auto *t = new QTimer(QCoreApplication::instance()); QObject::connect(t, &QTimer::timeout, [] { tick(); }); t->start(400); }
    return real();
}
