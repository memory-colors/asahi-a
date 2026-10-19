// panes.cpp - split-view pane behavior: same background in every pane, the INACTIVE pane dimmed (never showing selection), per-pane status bar
// fade, and the general Dolphin text color. Hooks: DolphinView::updatePalette, KStandardItemListWidget::{textColor,paint,drawPixmap,drawOverlays},
// KItemListHeaderWidget::paint. Tunable: runtime conf `inactivetext` (dolphin-tweaks.conf [shim]); text color: `text`.
#include "dolphin_private.h"
#include <QGraphicsItem>
#include <QGraphicsScene>
#include <QGraphicsView>

// EXPERIMENT (DOLPHIN_ROWCACHE=1): cache every item row as a pixmap (QGraphicsItem::DeviceCoordinateCache). Dolphin scrolls by MOVING the visible item
// widgets, so each scroll frame otherwise repaints ~40 rows (text layout + icons); with the cache a frame is mostly pixmap copies. update() invalidates
// a row's cache (hover / selection / content), and a pane active<->inactive switch re-arms every cache (see resetRowCaches). Default OFF for A/B testing.
static bool rowCacheOn()
{
    static const bool on = qEnvironmentVariableIntValue("DOLPHIN_ROWCACHE") == 1;
    return on;
}
static void resetRowCaches(QWidget *paneView)
{
    if (!rowCacheOn()) {
        return;
    }
    for (QGraphicsView *gv : paneView->findChildren<QGraphicsView *>()) {
        if (!gv->scene()) {
            continue;
        }
        for (QGraphicsItem *it : gv->scene()->items()) {
            if (it->cacheMode() != QGraphicsItem::NoCache) {
                it->setCacheMode(QGraphicsItem::NoCache);   // dropping and re-setting the mode discards the cached pixmap
                it->setCacheMode(QGraphicsItem::DeviceCoordinateCache);
            }
        }
    }
}

// Same view background in every pane; the inactive split pane is told apart by dimmer text instead.
// 1) DolphinView::updatePalette() sets the viewport background alpha to 150 when the pane is not the active split-view pane, so the (lighter)
//    window color shows through. Run the original, then put the alpha back to 255. Restoring the palette fires DolphinView's own PaletteChange
//    event filter -> updatePalette() again, so a re-entrancy guard keeps that nested call from undoing the fix.
// 2) Text of an inactive pane (file names, detail columns, column headers) is blended toward the background. A pane is inactive when its
//    DolphinView::isActive() is false, found by walking up from the painting widget. The share of the text color kept is `inactivetext` (0..1,
//    default 0.53) from the runtime conf.
//    - KStandardItemListWidget::textColor (file names): result dimmed; hidden files use the normal text color (m_isHidden masked) so they match normal items.
//    - KStandardItemListWidget::paint (detail columns): m_additionalInfoTextColor swapped for the duration of the paint (read at paint time);
//      m_selected / m_current are also cleared for the duration, so an inactive pane shows no selection highlight or focus ring.
//    - KItemListHeaderWidget::paint (column headers): painter opacity scaled by the same factor (the header sits over the view background).
//    - KStandardItemListWidget::drawPixmap / drawOverlays (icons, thumbnails, emblems) and the expander arrows: opacity scaled by the same factor while an inactive-pane item paints.
extern "C" bool dolphinview_isActive(const QWidget *self) __asm__("_ZNK11DolphinView8isActiveEv");
static bool paneInactive(const QWidget *w)
{
    for (; w; w = w->parentWidget()) {
        if (w->inherits("DolphinView")) {
            return !dolphinview_isActive(w);
        }
    }
    return false;
}
static QColor paneDim(const QColor &fg, const QColor &bg)
{
    const double keep = paneKeep();
    return QColor(int(bg.red() + (fg.red() - bg.red()) * keep + 0.5),
                  int(bg.green() + (fg.green() - bg.green()) * keep + 0.5),
                  int(bg.blue() + (fg.blue() - bg.blue()) * keep + 0.5),
                  fg.alpha());
}

// Status bar of an inactive pane (message / zoom / progress labels and the disk-usage widget): faded with a per-widget opacity effect, by the
// same factor as the pane text. The effect is removed again when the pane becomes active. The status bar is a sibling of the view inside
// DolphinViewContainer; the text colors themselves come from the generated QSS block (statustext; disktext = the QToolButton in StatusBarSpaceInfo).
static void paneDimStatusBar(QWidget *view, bool inactive)
{
    QWidget *container = view->parentWidget();
    while (container && !container->inherits("DolphinViewContainer")) {
        container = container->parentWidget();
    }
    if (!container) {
        return;
    }
    QList<QWidget *> targets;
    for (QWidget *bar : container->findChildren<QWidget *>()) {
        if (bar->inherits("DolphinStatusBar")) {
            for (QLabel *l : bar->findChildren<QLabel *>()) {
                targets << l;
            }
            for (QWidget *w : bar->findChildren<QWidget *>()) {
                if (w->inherits("StatusBarSpaceInfo")) {
                    targets << w;
                }
            }
        }
    }
    for (QWidget *w : targets) {
        auto *fx = qobject_cast<QGraphicsOpacityEffect *>(w->graphicsEffect());
        if (inactive) {
            if (!fx) {
                fx = new QGraphicsOpacityEffect(w);
                w->setGraphicsEffect(fx);
            }
            fx->setOpacity(paneKeep());
        } else if (fx) {
            w->setGraphicsEffect(nullptr);
        }
    }
}

// General text color: `text=` of the runtime conf (written by dolphin-tweaks). The qt6ct application palette is
// shared by every Qt6 app, so instead of editing it the Dolphin process alone gets Text / WindowText replaced (file names, detail columns,
// Folders tree, Information panel, menus without their own QSS color). Done once, on the first pane palette update (the QApplication exists then).
static void applyTextPalette()
{
    static bool done = false;
    if (done) {
        return;
    }
    done = true;
    const QColor c = rtColor("text");
    if (!c.isValid()) {
        return;
    }
    QPalette p = QGuiApplication::palette();
    for (QPalette::ColorGroup g : {QPalette::Active, QPalette::Inactive}) {
        p.setColor(g, QPalette::Text, c);
        p.setColor(g, QPalette::WindowText, c);
    }
    QGuiApplication::setPalette(p);
}

HOOK(void, opaque_updatePalette, "_ZN11DolphinView13updatePaletteEv", QWidget *self)
{
    using Fn = void (*)(QWidget *);
    static Fn orig = nextSym<Fn>(opaque_updatePalette_sym);
    static thread_local bool busy = false;
    if (!orig || busy) {
        return;
    }
    busy = true;
    applyTextPalette();
    orig(self);
    paneDimStatusBar(self, !dolphinview_isActive(self));
    resetRowCaches(self);
    if (auto *area = self->findChild<QAbstractScrollArea *>(QString(), Qt::FindDirectChildrenOnly)) {
        if (QWidget *vp = area->viewport()) {
            QPalette p = vp->palette();
            QColor c = p.color(vp->backgroundRole());
            if (c.alpha() != 255) {
                c.setAlpha(255);
                p.setColor(vp->backgroundRole(), c);
                vp->setPalette(p);
            }
            // The item text color depends on the pane state, which the viewport palette change above doesn't necessarily repaint.
            vp->update();
        }
    }
    // The rows are painted by the QGraphicsView INSIDE the container (mouse events also go to its inner viewport), not by area->viewport(): repaint that,
    // otherwise the active/inactive look sticks until something else (a hover) happens to repaint the pane.
    for (QGraphicsView *gv : self->findChildren<QGraphicsView *>()) {
        if (gv->scene()) {
            gv->scene()->update();
        }
        gv->viewport()->update();
    }
    busy = false;
}

HOOK(QColor, dim_textColor, "_ZNK23KStandardItemListWidget9textColorERK7QWidget", const KStandardItemListWidget *self, const QWidget &widget)
{
    using Fn = QColor (*)(const KStandardItemListWidget *, const QWidget &);
    static Fn orig = nextSym<Fn>(dim_textColor_sym);
    if (!orig) {
        return QColor();
    }
    if (!shimOk()) {
        return orig(self, widget);   // unknown Dolphin version: no private-member access
    }
    // Hidden (dot) files/folders normally get the faint detail color; pretend the item isn't hidden so they use the normal text color,
    // then dim it like any other item when the pane is inactive.
    auto *mut = const_cast<KStandardItemListWidget *>(self);
    const bool wasHidden = mut->m_isHidden;
    mut->m_isHidden = false;
    const QColor c = orig(self, widget);
    mut->m_isHidden = wasHidden;
    if (!paneInactive(&widget)) {
        return c;
    }
    return paneDim(c, widget.palette().color(QPalette::Base));
}

HOOK(void, dim_itemPaint, "_ZN23KStandardItemListWidget5paintEP8QPainterPK24QStyleOptionGraphicsItemP7QWidget", KStandardItemListWidget *self, QPainter *painter, const QStyleOptionGraphicsItem *option, QWidget *widget)
{
    using Fn = void (*)(KStandardItemListWidget *, QPainter *, const QStyleOptionGraphicsItem *, QWidget *);
    static Fn orig = nextSym<Fn>(dim_itemPaint_sym);
    if (!orig) {
        return;
    }
    if (!widget && rowCacheOn() && self->scene() && !self->scene()->views().isEmpty()) {
        // Qt paints a cached item into its pixmap with widget == nullptr, but Dolphin's paint() dereferences it (widget->hasFocus()); normally it is the view's viewport.
        widget = self->scene()->views().first()->viewport();
    }
    if (rowCacheOn() && !self->property("_rowCacheArmed").toBool()) {
        // Never change the cache mode from inside paint() (it would discard the cache being painted into): defer to the event loop.
        self->setProperty("_rowCacheArmed", true);
        QPointer<QGraphicsWidget> guard(self);
        QTimer::singleShot(0, qApp, [guard] {
            if (guard) {
                guard->setCacheMode(QGraphicsItem::DeviceCoordinateCache);
            }
        });
    }
    if (!shimOk() || !widget || !paneInactive(widget)) {
        orig(self, painter, option, widget);
        return;
    }
    const QColor saved = self->m_additionalInfoTextColor;
    self->m_additionalInfoTextColor = paneDim(saved, widget->palette().color(QPalette::Base));
    // No selection highlight / focus ring in an inactive pane: paint it as if unselected and not current (flags restored right after,
    // so the highlight is back as soon as the pane becomes active). setSelected() clears the hover cache, so a stale cache can't linger.
    const bool wasSelected = self->m_selected, wasCurrent = self->m_current;
    self->m_selected = false;
    self->m_current = false;
    g_inactivePaint = true;
    orig(self, painter, option, widget);
    g_inactivePaint = false;
    self->m_selected = wasSelected;
    self->m_current = wasCurrent;
    self->m_additionalInfoTextColor = saved;
}

// Icons / thumbnails and emblem overlays of an inactive pane: Dolphin draws them with painter->drawPixmap inside KStandardItemListWidget::paint
// (drawPixmap / drawOverlays are exported, non-virtual), so scale the painter opacity down while g_inactivePaint is set by dim_itemPaint.
HOOK(void, dim_drawPixmap, "_ZN23KStandardItemListWidget10drawPixmapEP8QPainterRK7QPixmap", void *self, QPainter *painter, const QPixmap &pixmap)
{
    using Fn = void (*)(void *, QPainter *, const QPixmap &);
    static Fn orig = nextSym<Fn>(dim_drawPixmap_sym);
    if (!orig) {
        return;
    }
    if (!g_inactivePaint) {
        orig(self, painter, pixmap);
        return;
    }
    const qreal opacity = painter->opacity();
    painter->setOpacity(opacity * paneKeep());
    orig(self, painter, pixmap);
    painter->setOpacity(opacity);
}
HOOK(void, dim_drawOverlays, "_ZNK23KStandardItemListWidget12drawOverlaysEP8QPainter", const void *self, QPainter *painter)
{
    using Fn = void (*)(const void *, QPainter *);
    static Fn orig = nextSym<Fn>(dim_drawOverlays_sym);
    if (!orig) {
        return;
    }
    if (!g_inactivePaint) {
        orig(self, painter);
        return;
    }
    const qreal opacity = painter->opacity();
    painter->setOpacity(opacity * paneKeep());
    orig(self, painter);
    painter->setOpacity(opacity);
}

HOOK(void, dim_headerPaint, "_ZN21KItemListHeaderWidget5paintEP8QPainterPK24QStyleOptionGraphicsItemP7QWidget", void *self, QPainter *painter, const QStyleOptionGraphicsItem *option, QWidget *widget)
{
    using Fn = void (*)(void *, QPainter *, const QStyleOptionGraphicsItem *, QWidget *);
    static Fn orig = nextSym<Fn>(dim_headerPaint_sym);
    if (!orig) {
        return;
    }
    if (!widget || !paneInactive(widget)) {
        orig(self, painter, option, widget);
        return;
    }
    const qreal opacity = painter->opacity();
    painter->setOpacity(opacity * paneKeep());
    orig(self, painter, option, widget);
    painter->setOpacity(opacity);
}

