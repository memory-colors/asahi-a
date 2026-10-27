// qt-fm.cpp - sets the Qt look for the Qt6 apps we wrap (SMPlayer, qView): applies the palette, font and icon theme that fm-tweaks generates.
// LD_PRELOAD it (together with qt-noicons) and set QT_STYLE_OVERRIDE=Fusion; no platform theme is needed. Colours come from ~/.config/fm-tweaks/qt-theme.conf (override: FM_QT_THEME), written by `fm-tweaks apply`.
// build: g++ -std=c++17 -shared -fPIC -o ~/.themes/qt-fm/libqt-fm.so qt-fm.cpp $(pkg-config --cflags --libs Qt6Widgets)
#include <QApplication>
#include <QHeaderView>
#include <QTableView>
#include <QStyledItemDelegate>
#include <QPalette>
#include <QFont>
#include <QIcon>
#include <QSettings>
#include <QStringList>
#include <QDir>
#include <QDateTime>
#include <QCursor>
#include <QFile>
#include <QMainWindow>
#include <QMenuBar>
#include <QMenu>
#include <QBitmap>
#include <QPainter>
#include <QToolBar>
#include <QLayout>
#include <QDockWidget>
#include <QShortcut>
#include <QPointer>
#include <QKeyEvent>
#include <QKeySequence>
#include <QTimer>
#include <QFileInfo>
#include <QToolButton>
#include <QAction>
#include <dlfcn.h>
#include <unistd.h>
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
#include <QWheelEvent>
#include <QScrollBar>
#include <cmath>
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

/* swallows tooltip events (playlist rows) */
struct NoTip : QObject {
    explicit NoTip(QObject *p) : QObject(p) {}
    bool eventFilter(QObject *, QEvent *e) override { return e->type() == QEvent::ToolTip; }
};
/* re-hides a menu bar that the app shows on its own (e.g. when leaving fullscreen) unless the user asked for it with the toggle key */
struct MbGuard : QObject {
    QMenuBar *mb; explicit MbGuard(QMenuBar *m) : QObject(m), mb(m) {}
    bool eventFilter(QObject *o, QEvent *e) override {
        if (o == mb && e->type() == QEvent::Show && !mb->property("fm-mb-wanted").toBool()) QTimer::singleShot(0, mb, [m = mb] { if (!m->property("fm-mb-wanted").toBool()) m->setVisible(false); });
        return false;
    }
};
/* kinetic (momentum) scrolling for a list view - Qt gives touchpad scrolling no inertia. Filters the wheel events on the viewport: touchpad / smooth events scroll the bar by pixels
   and, once they stop (60 ms without one, or a ScrollEnd phase), the measured speed keeps going and decays (friction = time constant in ms). Real mouse-wheel notches scroll `lines`
   rows each, instantly. [ui.smplayer] kinetic_scroll=true, kinetic_friction=325, kinetic_gain=0.85, kinetic_lines=3; FM_QT_WHEEL=1 logs the wheel events (stderr). */
struct Kinetic : QObject {
    QTableView *view; QScrollBar *bar; double v = 0, acc = 0, tau, gain; int lines;
    QElapsedTimer since, tick; QTimer release, anim;
    Kinetic(QTableView *t, double tau_, double gain_, int lines_) : QObject(t), view(t), bar(t->verticalScrollBar()), tau(tau_), gain(gain_), lines(lines_) {
        release.setSingleShot(true); release.setInterval(60); anim.setInterval(16); anim.setTimerType(Qt::PreciseTimer);
        connect(&release, &QTimer::timeout, this, [this] { launch(); });
        connect(&anim, &QTimer::timeout, this, [this] { step(); });
    }
    void stop() { anim.stop(); release.stop(); v = 0; acc = 0; }
    void move(double d) {
        acc += d; int n = (int)acc; acc -= n; if (n) bar->setValue(bar->value() + n);
    }
    void launch() { v *= gain; if (std::fabs(v) < 0.03) { v = 0; return; } tick.start(); anim.start(); }
    void step() {
        double ms = qBound(1.0, (double)tick.restart(), 50.0); move(v * ms); v *= std::exp(-ms / tau);
        if (std::fabs(v) < 0.015 || (v < 0 && bar->value() <= bar->minimum()) || (v > 0 && bar->value() >= bar->maximum())) stop();
    }
    bool eventFilter(QObject *, QEvent *e) override {
        if (e->type() == QEvent::MouseButtonPress || e->type() == QEvent::Hide || e->type() == QEvent::KeyPress) { stop(); return false; }
        if (e->type() != QEvent::Wheel) return false;
        auto *w = static_cast<QWheelEvent *>(e);
        if (qEnvironmentVariableIsSet("FM_QT_WHEEL")) fprintf(stderr, "[fmwheel] pixel=%d,%d angle=%d,%d phase=%d source=%d mods=%d\n", w->pixelDelta().x(), w->pixelDelta().y(), w->angleDelta().x(), w->angleDelta().y(), (int)w->phase(), (int)w->source(), (int)w->modifiers());
        if (w->modifiers() != Qt::NoModifier) return false;
        QPoint pd = w->pixelDelta(), ad = w->angleDelta();
        if (pd.y() == 0 && ad.y() == 0) return false;
        double rowH = qMax(1, view->verticalHeader()->defaultSectionSize());
        bool smooth = !pd.isNull() || (ad.y() % 120) != 0 || w->phase() != Qt::NoScrollPhase;
        anim.stop(); release.stop();
        double d = -(pd.y() != 0 ? (double)pd.y() : ad.y() * rowH * lines / 120.0);
        move(d);
        if (!smooth) { v = 0; return true; }
        qint64 ms = since.isValid() ? since.restart() : (since.start(), 1000);
        if (ms > 120) v = 0;
        double inst = d / (double)qMax<qint64>(ms, 4); v = (v == 0) ? inst : 0.6 * v + 0.4 * inst; v = qBound(-8.0, v, 8.0);
        if (w->phase() == Qt::ScrollEnd) launch(); else release.start();
        return true;
    }
};
/* playlist "Length" column: show 0:03:45 instead of 00:03:45 (a leading hour zero dropped); [ui.smplayer] length_font_pt (default 0 = same font as the names) sets its point size */
struct LenDelegate : QStyledItemDelegate {
    double pt; LenDelegate(QObject *p, double pt_) : QStyledItemDelegate(p), pt(pt_) {}
    QString displayText(const QVariant &v, const QLocale &l) const override {
        QString t = QStyledItemDelegate::displayText(v, l); if (t.size() > 7 && t[0] == '0' && t.count(':') == 2) t.remove(0, 1); return t;
    }
    void initStyleOption(QStyleOptionViewItem *o, const QModelIndex &i) const override { QStyledItemDelegate::initStyleOption(o, i); if (pt > 0) o->font.setPointSizeF(pt); }
};
/* ---- per-app interface tweaks, [ui.<appname>] in qt-theme.conf: menubar_hidden=true, menubar_key=Ctrl+M, hide_dock_titles=true ----
   Checked every 500 ms (windows appear late); each main window is handled once. */
/* control-bar icon colours: the icons are fixed-colour theme files, so the QToolButtons inside SMPlayer's main control bar (controlwidget / controlwidget_mini) and floating
   control bar (AutohideWidget) get a tinted copy of their icon ([ui.smplayer] control_icon_color / floating_icon_color, empty = untouched). The tint keeps each pixel's alpha
   and replaces its colour. A button re-reads its action's icon whenever the action changes (play <-> pause), so each button also listens to that and re-tints at once. */
static QColor icon_tint_for(QToolButton *b) {
    static QSettings *ic = nullptr; if (!ic) ic = new QSettings(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat);
    for (QWidget *p = b->parentWidget(); p; p = p->parentWidget()) {
        const QString n = p->objectName();
        if (!strcmp(p->metaObject()->className(), "AutohideWidget") || n == "floating_control") return QColor(ic->value("ui.smplayer/floating_icon_color").toString());
        if (n == "controlwidget" || n == "controlwidget_mini") return QColor(ic->value("ui.smplayer/control_icon_color").toString());
    }
    return QColor();
}
static void tint_button(QToolButton *b) {
    QColor col = icon_tint_for(b); if (!col.isValid()) return;
    QIcon cur = b->icon(); if (cur.isNull()) return;
    if (b->property("fm-tint-key").toLongLong() == (qlonglong)cur.cacheKey() && b->property("fm-tint-col").toString() == col.name()) return;
    QList<QSize> sizes = cur.availableSizes(); if (sizes.isEmpty()) { sizes << b->iconSize() << b->iconSize() * 2; }
    QIcon out;
    for (QIcon::Mode m : {QIcon::Normal, QIcon::Disabled, QIcon::Active, QIcon::Selected}) for (QIcon::State s : {QIcon::Off, QIcon::On}) for (const QSize &sz : sizes) {
        QPixmap pm = cur.pixmap(sz, m, s); if (pm.isNull()) continue;
        QPainter p(&pm); p.setCompositionMode(QPainter::CompositionMode_SourceIn); p.fillRect(pm.rect(), col); p.end();
        out.addPixmap(pm, m, s);
    }
    b->setIcon(out);
    b->setProperty("fm-tint-key", (qlonglong)b->icon().cacheKey()); b->setProperty("fm-tint-col", col.name());
    if (!b->property("fm-tint-conn").toBool() && b->defaultAction()) {
        b->setProperty("fm-tint-conn", true);
        QObject::connect(b->defaultAction(), &QAction::changed, b, [b] { QTimer::singleShot(0, b, [b] { tint_button(b); }); });
    }
}
static QKeySequence g_mbKey; static QPointer<QMenuBar> g_mbBar;   /* menu-bar toggle key + bar, set by ui_tweaks, used by ShowFilter */
static void ui_tweaks() {
    static QSettings *c = nullptr; static QString app;
    if (!c) { app = QFileInfo(QCoreApplication::applicationFilePath()).fileName().toLower(); c = new QSettings(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat); }
    c->sync(); QString sec = "ui." + app + "/";
    bool hideBar = c->value(sec + "menubar_hidden", false).toBool(), hideDock = c->value(sec + "hide_dock_titles", false).toBool(); QString key = c->value(sec + "menubar_key").toString();
    bool hideLogo = c->value(sec + "hide_logo", false).toBool(), hideTb = c->value(sec + "hide_playlist_toolbar", false).toBool();
    int numW = c->value(sec + "playlist_number_col_width", 0).toInt();   // px; playlist's first (number) column starts this narrow, still draggable
    auto kill = [](QWidget *x) { if (x->maximumHeight() != 0) { x->setMaximumSize(0, 0); x->hide(); } };   // max size 0 survives the app calling show() again
    FILE *dumpf = nullptr;   /* table diagnostics: opened once per tick for ALL windows, the trigger is removed after */
    { QString trig = QDir::homePath() + "/.cache/fm-tweaks/dump-table"; if (QFile::exists(trig)) { dumpf = fopen(qPrintable(QDir::homePath() + "/.cache/fm-tweaks/fmtable.log"), "w"); QFile::remove(trig); } }
    for (QWidget *w : QApplication::topLevelWidgets()) {
        if (app == "smplayer") for (QToolButton *tb : w->findChildren<QToolButton *>()) tint_button(tb);
        if (app == "smplayer") for (QToolBar *t : w->findChildren<QToolBar *>()) if ((t->objectName() == "controlwidget" || t->objectName() == "controlwidget_mini") && !t->property("fm-pad").toBool()) {   /* side padding: QSS padding on a QToolBar also grows its height, so use real contents margins */
            t->setProperty("fm-pad", true); t->setContentsMargins(c->value(sec + "control_pad_left", 8).toInt(), 0, c->value(sec + "control_pad_right", 2).toInt(), 0);
        }
        if (hideLogo) for (QWidget *l : w->findChildren<QWidget *>("mplayerwindowlogo")) kill(l);
        if (hideTb) for (QDockWidget *d : w->findChildren<QDockWidget *>("playlistdock")) for (QToolBar *t : d->findChildren<QToolBar *>()) kill(t);
        if (numW > 0) for (QTableView *v : w->findChildren<QTableView *>()) {
            QHeaderView *h = v->horizontalHeader(); if (!h || v->property("fm-numcol").toBool() || !v->isVisible() || h->count() < 2 || h->length() < 50) continue;
            v->setProperty("fm-numcol", true); h->setMinimumSectionSize(qMin(h->minimumSectionSize(), numW)); h->setSectionResizeMode(0, QHeaderView::Interactive); h->resizeSection(0, numW);
        }
        if (c->value(sec + "kinetic_scroll", true).toBool()) for (QTableView *v : w->findChildren<QTableView *>("playlist_table")) if (!v->property("fm-kinetic").toBool()) {
            v->setProperty("fm-kinetic", true); v->viewport()->installEventFilter(new NoTip(v)); v->viewport()->setMouseTracking(true); v->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
            v->horizontalHeader()->setDefaultAlignment(Qt::AlignHCenter | Qt::AlignVCenter);   /* the app's own default: "Name" stays centred */
            if (v->model() && v->model()->columnCount() > 2) v->setItemDelegateForColumn(2, new LenDelegate(v, c->value(sec + "length_font_pt", 0).toDouble()));
            v->viewport()->installEventFilter(new Kinetic(v, c->value(sec + "kinetic_friction", 325).toDouble(), c->value(sec + "kinetic_gain", 0.85).toDouble(), c->value(sec + "kinetic_lines", 3).toInt()));
        }
        for (QTableView *v : w->findChildren<QTableView *>("playlist_table")) if (QAbstractItemModel *m = v->model()) if (m->columnCount() > 2) {   /* "Length" label left-aligned over its left-aligned numbers; re-applied every tick in case the app rebuilds its header labels */
            const int want = Qt::AlignLeft | Qt::AlignVCenter; if (m->headerData(2, Qt::Horizontal, Qt::TextAlignmentRole).toInt() != want) m->setHeaderData(2, Qt::Horizontal, want, Qt::TextAlignmentRole);
        }
        /* diagnostics without a terminal: `touch ~/.cache/fm-tweaks/dump-table` makes the next tick write ~/.cache/fm-tweaks/fmtable.log (every QTableView of every window: name, model, header/cell alignment, text, fonts, delegates) */
        { FILE *f = dumpf; {
            if (f) {
                fprintf(f, "window %s#%s\n", w->metaObject()->className(), qPrintable(w->objectName()));
                for (QTableView *v : w->findChildren<QTableView *>()) {
                    QAbstractItemModel *m = v->model(); QHeaderView *h = v->horizontalHeader();
                    fprintf(f, "table class=%s name='%s' visible=%d model=%s rows=%d cols=%d hdefaultAlign=%d delegateDefault=%s\n", v->metaObject()->className(), qPrintable(v->objectName()), (int)v->isVisible(), m ? m->metaObject()->className() : "(none)", m ? m->rowCount() : -1, m ? m->columnCount() : -1, (int)h->defaultAlignment(), v->itemDelegate()->metaObject()->className());
                    for (int k = 0; m && k < m->columnCount(); ++k) {
                        QModelIndex ix = m->index(0, k); auto *dc = v->itemDelegateForColumn(k); QVariant fr = m->data(ix, Qt::FontRole);
                        fprintf(f, "  col %d header='%s' headerAlignRole=%s cellAlignRole=%s text='%s' width=%d fontRole=%s viewFont=%.1fpt headerFont=%.1fpt colDelegate=%s\n", k, qPrintable(m->headerData(k, Qt::Horizontal).toString()), qPrintable(m->headerData(k, Qt::Horizontal, Qt::TextAlignmentRole).toString()), qPrintable(m->data(ix, Qt::TextAlignmentRole).toString()), qPrintable(m->data(ix, Qt::DisplayRole).toString()), h->sectionSize(k), qPrintable(fr.isValid() ? fr.value<QFont>().toString() : QString("(none)")), v->font().pointSizeF(), h->font().pointSizeF(), dc ? dc->metaObject()->className() : "(none)");
                    }
                }
            }
        } }
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
        if (!key.isEmpty()) { g_mbKey = QKeySequence(key); g_mbBar = mb; }   /* toggled by ShowFilter (app-wide event filter), not a QShortcut: a clashing SMPlayer binding makes Qt fire neither */
    }
    if (dumpf) fclose(dumpf);
}
/* Applies the tweaks the moment a main window is about to be shown (QShowEvent is sent before the platform window is mapped), so the menu bar / dock titles / logo
   never appear for a moment; the 500 ms tick stays for widgets that only exist later. */
struct ShowFilter : QObject {
    bool eventFilter(QObject *o, QEvent *e) override {
        if ((e->type() == QEvent::ShortcutOverride || e->type() == QEvent::KeyPress) && !g_mbKey.isEmpty() && g_mbBar) {   /* menu-bar toggle key (Ctrl+M): claim it before any shortcut, toggle on the key press */
            auto *ke = static_cast<QKeyEvent *>(e);
            if (!ke->isAutoRepeat() && QKeySequence(ke->keyCombination()) == g_mbKey) {
                if (e->type() == QEvent::KeyPress) { bool want = !g_mbBar->isVisible(); g_mbBar->setProperty("fm-mb-wanted", want); g_mbBar->setVisible(want); }
                e->accept(); return true;
            }
        }
        /* Fusion paints an opaque rectangle behind rounded menus (the patched Breeze did not): make every QMenu window translucent BEFORE it is mapped, so the stylesheet's rounded corners show */
        if (e->type() == QEvent::Polish && o->isWidgetType() && (qobject_cast<QMenu *>(o) || !strcmp(o->metaObject()->className(), "QTipLabel"))) { auto *m = static_cast<QWidget *>(o); m->setAttribute(Qt::WA_TranslucentBackground, true); m->setWindowFlag(Qt::NoDropShadowWindowHint, true); }   /* also tooltips (QTipLabel) */
        /* SMPlayer's floating control panel (AutohideWidget): padding so the seek slider no longer touches the edges (horizontal px: [ui.smplayer] floating_padding, default 8; vertical: floating_padding_v, default 0) */
        if (e->type() == QEvent::Show && qEnvironmentVariableIsSet("FM_QT_DUMP") && qobject_cast<QMainWindow *>(o)) {   /* FM_QT_DUMP: also the playlist dock tree (class, geometry, margins, autofill, window colour) 3 s after the main window shows */
            auto *mw0 = static_cast<QWidget *>(o);
            QTimer::singleShot(3000, mw0, [mw0] { for (QDockWidget *d : mw0->findChildren<QDockWidget *>()) {
                fprintf(stderr, "[fmdock] %s#%s geom=%d,%d %dx%d\n", d->metaObject()->className(), qPrintable(d->objectName()), d->x(), d->y(), d->width(), d->height());
                for (QWidget *c : d->findChildren<QWidget *>()) { QMargins m = c->layout() ? c->layout()->contentsMargins() : QMargins(); fprintf(stderr, "[fmdock]   %s#%s geom=%d,%d %dx%d vis=%d auto=%d win=%s lay=%d,%d,%d,%d\n", c->metaObject()->className(), qPrintable(c->objectName()), c->x(), c->y(), c->width(), c->height(), c->isVisible(), c->autoFillBackground(), qPrintable(c->palette().color(QPalette::Window).name()), m.left(), m.top(), m.right(), m.bottom()); } } });
        }
        if (e->type() == QEvent::Show && qEnvironmentVariableIsSet("FM_QT_DUMP") && qobject_cast<QMainWindow *>(o)) {   /* FM_QT_DUMP: reveal the (normally mouse-triggered) floating panel so it can be inspected headless */
            auto *mw = static_cast<QWidget *>(o);
        }
        /* SMPlayer's playlist dock and its Playlist widget are custom QWidget subclasses: their stylesheet background is ignored unless WA_StyledBackground is set (the grey frame around the list) */
        if (e->type() == QEvent::Show && o->isWidgetType() && qobject_cast<QDockWidget *>(o)) { auto *d = static_cast<QDockWidget *>(o); d->setAttribute(Qt::WA_StyledBackground, true); if (d->widget()) { d->widget()->setAttribute(Qt::WA_StyledBackground, true);
            QWidget *pl = d->widget();   /* the Playlist widget insets the list by 9 px left/right/bottom: shrink it ([ui.smplayer] playlist_margin, default 0) */
            if (pl->layout() && !pl->property("fm-margin").toBool()) { pl->setProperty("fm-margin", true); static QSettings c(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat); int mg = c.value("ui.smplayer/playlist_margin", 0).toInt(); pl->layout()->setContentsMargins(mg, 0, mg, mg); } } }
        /* floating panel: no empty strip above/below the toolbar - SMPlayer sizes the panel taller than its toolbar (it centres it); shrink the panel to the toolbar's height, keeping its bottom edge ([ui.smplayer] floating_fit, default on) */
        if ((e->type() == QEvent::Resize || e->type() == QEvent::Show) && o->isWidgetType() && !strcmp(o->metaObject()->className(), "AutohideWidget")) {
            auto *w = static_cast<QWidget *>(o);
            static QSettings fc(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat);
            QToolBar *tb = w->findChild<QToolBar *>("floating_control");
            if (tb && fc.value("ui.smplayer/floating_fit", true).toBool() && !w->property("fm-fitting").toBool()) {
                int th = tb->sizeHint().height() + w->layout()->contentsMargins().top() + w->layout()->contentsMargins().bottom();
                if (th > 0 && w->height() != th) {
                    w->setProperty("fm-fitting", true); int diff = w->height() - th;
                    w->setFixedHeight(th); w->move(w->x(), w->y() + diff);
                    w->setProperty("fm-fitting", false);
                }
            }
        }
        /* the floating panel sits over the video (a native window), so its transparent rounded corners show the window's black behind them: clip the corners with a mask instead (radius: [ui.smplayer] floating_radius, default 2 = the qss border-radius) */
        if ((e->type() == QEvent::Resize || e->type() == QEvent::Show) && o->isWidgetType() && !strcmp(o->metaObject()->className(), "AutohideWidget")) {
            auto *w = static_cast<QWidget *>(o);
            static QSettings rc0(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat);
            if (rc0.value("ui.smplayer/floating_mask", false).toBool() && w->width() > 0 && w->height() > 0) {   /* 1-bit mask: edges are not antialiased, so keep the radius small */
                static QSettings rc(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat);
                int r = rc.value("ui.smplayer/floating_radius", 2).toInt();
                QBitmap bm(w->size()); bm.fill(Qt::color0); QPainter pt(&bm); pt.setRenderHint(QPainter::Antialiasing, false); pt.setBrush(Qt::color1); pt.setPen(Qt::color1); pt.drawRoundedRect(QRectF(0, 0, w->width(), w->height()), r, r); pt.end();
                w->setMask(bm);
            }
        }
        if (e->type() == QEvent::Show && o->metaObject() && !strcmp(o->metaObject()->className(), "AutohideWidget")) {
            auto *w = static_cast<QWidget *>(o);
            if (qEnvironmentVariableIsSet("FM_QT_DUMP")) QTimer::singleShot(600, w, [w] {   /* FM_QT_DUMP=1: print the floating panel's widget tree (class, geometry, layout margins) */
                fprintf(stderr, "[fmdump] AutohideWidget %dx%d isWindow=%d parent=%s translucent=%d layout=%s\n", w->width(), w->height(), (int)w->isWindow(), w->parentWidget() ? w->parentWidget()->metaObject()->className() : "none", (int)w->testAttribute(Qt::WA_TranslucentBackground), w->layout() ? w->layout()->metaObject()->className() : "none");
                if (w->layout()) { QMargins m = w->layout()->contentsMargins(); fprintf(stderr, "[fmdump] margins %d %d %d %d spacing %d\n", m.left(), m.top(), m.right(), m.bottom(), w->layout()->spacing()); }
                for (QWidget *c : w->findChildren<QWidget *>()) fprintf(stderr, "[fmdump]   %s#%s geom=%d,%d %dx%d\n", c->metaObject()->className(), qPrintable(c->objectName()), c->x(), c->y(), c->width(), c->height());
            });
            if (!w->property("fm-pad").toBool() && w->layout()) {
                w->setProperty("fm-pad", true); w->setAttribute(Qt::WA_StyledBackground, true);   /* plain QWidget subclasses ignore the stylesheet background (rounded panel) unless told to paint it */
                static QSettings c(qEnvironmentVariable("FM_QT_THEME", QDir::homePath() + "/.config/fm-tweaks/qt-theme.conf"), QSettings::IniFormat);
                int px = c.value("ui.smplayer/floating_padding", 8).toInt(), py = c.value("ui.smplayer/floating_padding_v", 0).toInt(); QMargins m = w->layout()->contentsMargins();   // vertical 0 by default: SMPlayer fixes the panel height itself, extra margins only squeeze the content
                w->layout()->setContentsMargins(m.left() + px, m.top() + py, m.right() + px, m.bottom() + py); if (py > 0) w->setMinimumHeight(w->height() + 2 * py);   /* SMPlayer fixes the height itself: grow it by the vertical padding or the content gets squeezed */
            }
        }
        if (e->type() == QEvent::Show && qobject_cast<QMainWindow *>(o) && static_cast<QWidget *>(o)->isWindow()) ui_tweaks();
        return false;
    }
};
static void install_show_filter() { static bool done = false; if (done) return; done = true; QCoreApplication::instance()->installEventFilter(new ShowFilter); }   // SMPlayer shows its main window BEFORE exec()
/* apply right after the QApplication object exists - before any widget or icon is created */
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
/* QStatusBar draws its message at a hard-coded 6 px from the left edge (QSS padding/margin cannot move it), which sits on the rounded window corner: prefix the text with figure spaces */
extern "C" void _ZN10QStatusBar11showMessageERK7QStringi(void *self, const QString &text, int timeout) {
    static void (*real)(void *, const QString &, int) = (void (*)(void *, const QString &, int))dlsym(RTLD_NEXT, "_ZN10QStatusBar11showMessageERK7QStringi");
    real(self, text.isEmpty() ? text : QString(QChar(0x2007)).repeated(2) + QChar(0x2005) + text, timeout);
}
