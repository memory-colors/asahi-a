// Dye-test harness shim. DYE_SHOT_DIR=dir, DYE_ACTIONS="wait:ms;shot;sethover:x,y;setcurrent:x,y;action:name;menu;tooltip;shotpop;deactivate;activate;key:Down;quit" (default "wait:5000;shot;quit"), DYE_SIZE=WxH.
// Shots are of the main top-level window: shot-N.png (view) + shot-N.ppm (raw, for pixel counting); info.txt logs window state.
#include <QApplication>
#include <QTimer>
#include <QWidget>
#include <QPixmap>
#include <QImage>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QFile>
#include <QStringList>
#include <memory>
#include <QMenu>
#include <QScrollBar>
#include <QAbstractScrollArea>
#include <QElapsedTimer>
#include <QWheelEvent>
#include <QUrl>
#include <QList>
#include <QAction>
#include <QToolTip>
#include <QGraphicsView>
#include <QGraphicsObject>
#include <qpa/qwindowsysteminterface.h>
#include <dlfcn.h>

static QWidget *mainWin()
{
    for (QWidget *w : QApplication::topLevelWidgets()) {
        if (w->isVisible() && w->width() >= 200 && !qstrcmp(w->metaObject()->className(), "DolphinMainWindow")) {
            return w;
        }
    }
    return nullptr;
}

static void runStep(QStringList steps, int idx, QString dir, int *shotN)
{
    QFile log(dir + "/info.txt");
    log.open(QIODevice::Append | QIODevice::Text);
    auto logln = [&](const QString &s) { log.write((s + "\n").toUtf8()); };
    int delay = 0;
    while (idx < steps.size()) {
        const QString s = steps[idx++];
        const QString cmd = s.section(':', 0, 0), arg = s.section(':', 1);
        QWidget *w = mainWin();
        if (cmd == "wait") {
            delay = arg.toInt();
            break;
        } else if (cmd == "quit") {
            logln("quit");
            log.close();
            QApplication::exit(0);
            return;
        } else if (!w) {
            logln("no main window for step " + s);
        } else if (cmd == "shot") {
            if (qEnvironmentVariableIsSet("DYE_SIZE")) {
                const QList<QByteArray> wh = qgetenv("DYE_SIZE").split('x');
                if (wh.size() == 2 && (w->width() != wh[0].toInt() || w->height() != wh[1].toInt())) {
                    w->resize(wh[0].toInt(), wh[1].toInt());
                    QApplication::processEvents();
                }
            }
            const QImage img = w->grab().toImage().convertToFormat(QImage::Format_RGB32);
            img.save(dir + QString("/shot-%1.png").arg(*shotN));
            img.convertToFormat(QImage::Format_RGB888).save(dir + QString("/shot-%1.ppm").arg(*shotN), "PPM");
            logln(QString("shot-%1 active=%2 size=%3x%4").arg(*shotN).arg(w->isActiveWindow()).arg(img.width()).arg(img.height()));
            ++*shotN;
        } else if (cmd == "hover") {
            const QPoint p(arg.section(',', 0, 0).toInt(), arg.section(',', 1, 1).toInt());
            const QPoint gp = w->mapToGlobal(p);
            QWindowSystemInterface::handleEnterEvent<QWindowSystemInterface::SynchronousDelivery>(w->windowHandle(), QPointF(p), QPointF(gp));
            QWindowSystemInterface::handleMouseEvent<QWindowSystemInterface::SynchronousDelivery>(w->windowHandle(), QPointF(p.x() - 8, p.y() - 3), QPointF(gp.x() - 8, gp.y() - 3), Qt::NoButton, Qt::NoButton, QEvent::MouseMove);
            QWindowSystemInterface::handleMouseEvent<QWindowSystemInterface::SynchronousDelivery>(w->windowHandle(), QPointF(p), QPointF(gp), Qt::NoButton, Qt::NoButton, QEvent::MouseMove);
            QWidget *t = w->childAt(p);
            QApplication::processEvents();
            for (QWidget *q = t; q; q = q->parentWidget()) {
                logln(QString("   chain %1 underMouse=%2 mouseTracking=%3").arg(q->metaObject()->className()).arg(q->underMouse()).arg(q->hasMouseTracking()));
            }
            logln(QString("hover %1,%2 -> %3").arg(p.x()).arg(p.y()).arg(t ? t->metaObject()->className() : "none"));
        } else if (cmd == "action" || cmd == "listactions") {
            // action:<objectName> triggers a QAction of the main window (e.g. editable_location, show_filter_bar); listactions logs all names
            if (cmd == "listactions") {
                QStringList names;
                for (QAction *a : w->findChildren<QAction *>()) {
                    if (!a->objectName().isEmpty()) names << a->objectName();
                }
                logln("actions: " + names.join(' '));
            } else if (QAction *a = w->findChild<QAction *>(arg)) {
                a->trigger();
                QApplication::processEvents();
                logln("action " + arg + " triggered");
            } else {
                logln("action " + arg + " NOT FOUND");
            }
        } else if (cmd == "click") {
            // real press+release through the window system at window point x,y (left button)
            const QPoint p(arg.section(',', 0, 0).toInt(), arg.section(',', 1, 1).toInt());
            const QPoint gp = w->mapToGlobal(p);
            using WSI = QWindowSystemInterface;
            WSI::handleEnterEvent<WSI::SynchronousDelivery>(w->windowHandle(), QPointF(p), QPointF(gp));
            WSI::handleMouseEvent<WSI::SynchronousDelivery>(w->windowHandle(), QPointF(p), QPointF(gp), Qt::NoButton, Qt::NoButton, QEvent::MouseMove);
            WSI::handleMouseEvent<WSI::SynchronousDelivery>(w->windowHandle(), QPointF(p), QPointF(gp), Qt::LeftButton, Qt::LeftButton, QEvent::MouseButtonPress);
            WSI::handleMouseEvent<WSI::SynchronousDelivery>(w->windowHandle(), QPointF(p), QPointF(gp), Qt::NoButton, Qt::LeftButton, QEvent::MouseButtonRelease);
            QApplication::processEvents();
            QWidget *t = w->childAt(p);
            logln(QString("click %1,%2 -> %3").arg(p.x()).arg(p.y()).arg(t ? t->metaObject()->className() : "none"));
        } else if (cmd == "esc") {
            QWidget *f = QApplication::focusWidget() ? QApplication::focusWidget() : w;
            QKeyEvent kp(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier), kr(QEvent::KeyRelease, Qt::Key_Escape, Qt::NoModifier);
            QApplication::sendEvent(f, &kp);
            QApplication::sendEvent(f, &kr);
            QApplication::processEvents();
            logln(QString("esc -> %1").arg(f->metaObject()->className()));
        } else if (cmd == "urledit") {
            // put every location bar into edit mode (KUrlNavigator::setUrlEditable)
            using Fn = void (*)(void *, bool);
            static Fn ed = reinterpret_cast<Fn>(dlsym(RTLD_DEFAULT, "_ZN13KUrlNavigator14setUrlEditableEb"));
            int n = 0;
            for (QWidget *q : w->findChildren<QWidget *>()) {
                if (!qstrcmp(q->metaObject()->className(), "DolphinUrlNavigator") && ed) { ed(q, true); ++n; }
            }
            QApplication::processEvents();
            logln(QString("urledit on %1 navigators").arg(n));
        } else if (cmd == "flick" || cmd == "trace") {
            // flick:<n updates>  - synthetic touchpad two-finger flick (ScrollBegin, n x ScrollUpdate 8 ms apart, ScrollEnd) over the main file view.
            // trace:<ms>         - for that long, log (time, vertical scrollbar value) on every QEvent::UpdateRequest of the main window + every 4 ms by timer.
            QAbstractScrollArea *area = nullptr;
            for (QAbstractScrollArea *a : w->findChildren<QAbstractScrollArea *>()) {
                if (!qstrcmp(a->metaObject()->className(), "KItemListContainer") && a->isVisible() && a->verticalScrollBar()->maximum() > 0) { area = a; break; }
            }
            if (!area) { logln(cmd + ": no scrollable KItemListContainer (is the folder long enough?)"); continue; }
            QScrollBar *bar = area->verticalScrollBar();
            if (cmd == "flick") {
                const int n = arg.toInt() > 0 ? arg.toInt() : 12;
                const QPoint p = area->mapTo(w, QPoint(area->width() / 2, area->height() / 2));
                const QPointF gp = w->mapToGlobal(p);
                using WSI = QWindowSystemInterface;
                logln(QString("flick start n=%1 bar=%2/%3").arg(n).arg(bar->value()).arg(bar->maximum()));
                auto *i = new int(0);
                auto *tm = new QTimer(QApplication::instance());
                tm->setInterval(8);
                QObject::connect(tm, &QTimer::timeout, [=]() {
                    const int k = (*i)++;
                    if (k == 0) {
                        WSI::handleWheelEvent(w->windowHandle(), QPointF(p), gp, QPoint(0, 0), QPoint(0, 0), Qt::NoModifier, Qt::ScrollBegin);
                    }
                    if (k < n) {
                        WSI::handleWheelEvent(w->windowHandle(), QPointF(p), gp, QPoint(0, 0), QPoint(0, -120), Qt::NoModifier, Qt::ScrollUpdate);
                    } else {
                        WSI::handleWheelEvent(w->windowHandle(), QPointF(p), gp, QPoint(0, 0), QPoint(0, 0), Qt::NoModifier, Qt::ScrollEnd);
                        tm->stop();
                    }
                });
                tm->start();
            } else {
                struct Tr : QObject {
                    QElapsedTimer clk; QScrollBar *bar; QString dir; QWindow *win;
                    bool eventFilter(QObject *o, QEvent *e) override {
                        if (o == win && e->type() == QEvent::UpdateRequest) rec("F");
                        return false;
                    }
                    void rec(const char *kind) {
                        QFile f(dir + "/trace.txt"); f.open(QIODevice::Append | QIODevice::Text);
                        f.write(QString("%1 %2 %3\n").arg(kind).arg(clk.nsecsElapsed() / 1e6, 0, 'f', 2).arg(bar->value()).toUtf8());
                    }
                };
                auto *tr = new Tr; tr->bar = bar; tr->dir = dir; tr->win = w->windowHandle(); tr->clk.start();
                tr->win->installEventFilter(tr);
                auto *tm = new QTimer(tr); tm->setInterval(4);
                QObject::connect(tm, &QTimer::timeout, [tr]() { tr->rec("T"); });
                tm->start();
                QTimer::singleShot(arg.toInt(), tr, [tr, tm]() { tm->stop(); tr->win->removeEventFilter(tr); });
            }
        } else if (cmd == "bench") {
            // bench:<N> - time N grab()s (full paintEvent) of the main file view viewport (cost of painting all visible items, hooks included)
            QAbstractScrollArea *area = nullptr;
            for (QAbstractScrollArea *a : w->findChildren<QAbstractScrollArea *>()) {
                if (!qstrcmp(a->metaObject()->className(), "KItemListContainer") && a->isVisible()) { area = a; break; }
            }
            if (!area) { logln("bench: no KItemListContainer"); continue; }
            const int n = arg.toInt() > 0 ? arg.toInt() : 200;
            for (int k = 0; k < 20; ++k) (void)area->viewport()->grab();   // warm up
            QElapsedTimer tm; tm.start();
            for (int k = 0; k < n; ++k) (void)area->viewport()->grab();
            logln(QString("bench %1 repaints: %2 ms total, %3 ms each").arg(n).arg(tm.elapsed()).arg(double(tm.nsecsElapsed()) / 1e6 / n, 0, 'f', 3));
        } else if (cmd == "listviews") {
            for (QGraphicsView *gv : w->findChildren<QGraphicsView *>()) {
                const QPoint o = gv->mapTo(w, QPoint(0, 0));
                QWidget *dv = gv;
                while (dv && qstrcmp(dv->metaObject()->className(), "DolphinView")) dv = dv->parentWidget();
                logln(QString("view at %1,%2 %3x%4 vis=%5 items=%6 inDolphinView=%7").arg(o.x()).arg(o.y()).arg(gv->width()).arg(gv->height()).arg(gv->isVisible()).arg(gv->items().size()).arg(dv ? "yes" : "no"));
            }
        } else if (cmd == "openwith") {
            // construct and show KDE's Open With dialog (KOpenWithDialog(QList<QUrl>, QWidget*)) for $DYE_OPENWITH_FILE (grab it with shotpop)
            using Ctor = void (*)(void *, const QList<QUrl> &, QWidget *);
            static Ctor ctor = reinterpret_cast<Ctor>(dlsym(RTLD_DEFAULT, "_ZN15KOpenWithDialogC1ERK5QListI4QUrlEP7QWidget"));
            if (ctor) {
                void *mem = ::operator new(4096);   // generously larger than the real object; leaked on purpose (test shim)
                ctor(mem, QList<QUrl>{QUrl::fromLocalFile(QString::fromLocal8Bit(qgetenv("DYE_OPENWITH_FILE")))}, w);
                auto *d = static_cast<QWidget *>(mem);
                d->show();
                QApplication::processEvents();
                logln(QString("openwith dialog shown: %1").arg(d->metaObject()->className()));
            } else {
                logln("openwith: constructor not found");
            }
        } else if (cmd == "menu") {
            auto *m = new QMenu(w);
            m->setObjectName("dyeMenu");
            m->addAction("Normal item");
            QAction *sel = m->addAction("Hovered item");
            m->addAction("Disabled item")->setEnabled(false);
            m->addSeparator();
            QAction *chk = m->addAction("Checked item");
            chk->setCheckable(true);
            chk->setChecked(true);
            m->popup(w->mapToGlobal(QPoint(420, 250)));
            m->setActiveAction(sel);
            QApplication::processEvents();
            logln("menu popped");
        } else if (cmd == "tooltip") {
            QToolTip::showText(w->mapToGlobal(QPoint(700, 300)), "Tooltip sample text", w, QRect(), 20000);
            QApplication::processEvents();
            logln("tooltip shown");
        } else if (cmd == "shotpop") {
            for (QWidget *q : QApplication::topLevelWidgets()) {
                const QByteArray cn = q->metaObject()->className();
                if (q->isVisible() && (cn == "QMenu" || cn == "QTipLabel" || cn == "KOpenWithDialog")) {
                    const QImage img = q->grab().toImage().convertToFormat(QImage::Format_RGB32);
                    img.save(dir + QString("/shot-%1.png").arg(*shotN));
                    img.convertToFormat(QImage::Format_RGB888).save(dir + QString("/shot-%1.ppm").arg(*shotN), "PPM");
                    logln(QString("shot-%1 popup %2 %3x%4").arg(*shotN).arg(cn.constData()).arg(img.width()).arg(img.height()));
                    ++*shotN;
                }
            }
        } else if (cmd == "sethover" || cmd == "setcurrent" || cmd == "setselected") {
            // call KItemListWidget::setHovered/setCurrent on the item widget under window point x,y (bypasses input synthesis)
            const QPoint p(arg.section(',', 0, 0).toInt(), arg.section(',', 1, 1).toInt());
            bool done = false;
            for (QGraphicsView *gv : w->findChildren<QGraphicsView *>()) {
                logln(QString("   gv vis=%1 geom=%2,%3 %4x%5 items=%6").arg(gv->isVisible()).arg(gv->mapTo(w, QPoint(0, 0)).x()).arg(gv->mapTo(w, QPoint(0, 0)).y()).arg(gv->width()).arg(gv->height()).arg(gv->items().size()));
                if (!gv->isVisible()) continue;
                const QPoint vp = gv->viewport()->mapFrom(w, p);
                if (!gv->viewport()->rect().contains(vp)) continue;
                QGraphicsItem *it = nullptr;
                for (QGraphicsItem *c : gv->items(vp)) {
                    QGraphicsItem *q = c;
                    while (q && !(q->toGraphicsObject() && QByteArray(q->toGraphicsObject()->metaObject()->className()).contains("ListWidget"))) {
                        q = q->parentItem();
                    }
                    if (q) { it = q; break; }
                }
                if (it) {
                    using Fn = void (*)(void *, bool);
                    static Fn setH = reinterpret_cast<Fn>(dlsym(RTLD_DEFAULT, "_ZN15KItemListWidget10setHoveredEb"));
                    static Fn setC = reinterpret_cast<Fn>(dlsym(RTLD_DEFAULT, "_ZN15KItemListWidget10setCurrentEb"));
                    static Fn setS = reinterpret_cast<Fn>(dlsym(RTLD_DEFAULT, "_ZN15KItemListWidget11setSelectedEb"));
                    (cmd == "sethover" ? setH : cmd == "setselected" ? setS : setC)(it->toGraphicsObject(), true);
                    logln(QString("%1 on %2").arg(cmd, it->toGraphicsObject()->metaObject()->className()));
                    done = true;
                }
            }
            if (!done) logln(cmd + ": no item widget at " + arg);
        } else if (cmd == "deactivate") {
            QApplication::setActiveWindow(nullptr);
            logln(QString("deactivate -> active=%1").arg(w->isActiveWindow()));
        } else if (cmd == "activate") {
            QApplication::setActiveWindow(w);
            logln(QString("activate -> active=%1").arg(w->isActiveWindow()));
        } else if (cmd == "key") {
            const int k = arg == "Down" ? Qt::Key_Down : arg == "Up" ? Qt::Key_Up : arg == "CtrlA" ? Qt::Key_A : Qt::Key_Tab;
            QWidget *f = QApplication::focusWidget() ? QApplication::focusWidget() : w;
            const Qt::KeyboardModifiers m = arg == "CtrlA" ? Qt::ControlModifier : Qt::NoModifier;
            QKeyEvent kp(QEvent::KeyPress, k, m), kr(QEvent::KeyRelease, k, m);
            QApplication::sendEvent(f, &kp);
            QApplication::sendEvent(f, &kr);
            logln(QString("key %1 -> %2").arg(arg, f->metaObject()->className()));
        }
    }
    log.close();
    if (idx >= steps.size()) {
        QApplication::exit(0);
        return;
    }
    QTimer::singleShot(delay, QApplication::instance(), [=]() { runStep(steps, idx, dir, shotN); });
}

extern "C" int shot_exec() __asm__("_ZN16QCoreApplication4execEv");
extern "C" int shot_exec()
{
    using Fn = int (*)();
    static Fn orig = reinterpret_cast<Fn>(dlsym(RTLD_NEXT, "_ZN16QCoreApplication4execEv"));
    const QString dir = QString::fromLocal8Bit(qgetenv("DYE_SHOT_DIR"));
    if (!dir.isEmpty() && QApplication::instance()) {
        const QString acts = qEnvironmentVariableIsSet("DYE_ACTIONS") ? QString::fromLocal8Bit(qgetenv("DYE_ACTIONS")) : QString("wait:5000;shot;quit");
        auto *n = new int(0);
        QTimer::singleShot(0, QApplication::instance(), [=]() { runStep(acts.split(';'), 0, dir, n); });
    }
    return orig();
}
