// items.cpp - per-item look fixes: no alternate row stripes, hidden (dot) files shown at normal brightness, flat hover (no outline).
// Hooks: KItemListWidget::{setAlternateBackground,drawItemStyleOption}, KStandardItemListWidget::updatePixmapCache.
#include "dolphin_private.h"
#include <QGraphicsScene>
#include <QGraphicsView>

// No alternate row stripes, ever. Dolphin has no setting for them: KStandardItemListView always enables them, and KItemListWidget::paint
// fills odd rows with palette AlternateBase, run through darker(101)/lighter(101) whenever the view lacks focus - so even AlternateBase == Base
// still leaves a faint stripe on an unfocused view (first open, other split pane, after clicking the sidebar). m_alternateBackground stays
// false when the setter does nothing, so paint() never fills. Exported symbol, called through the PLT -> interposable (no headers needed).
HOOK(void, noalt_setAlternateBackground, "_ZN15KItemListWidget22setAlternateBackgroundEb", void *, bool)
{
}

// Hidden (dot) files/folders: updatePixmapCache() bakes KIconEffect::semiTransparent into the icon when m_isHidden. Build the pixmap as if the item
// weren't hidden so the icon has the same brightness as a normal one (pane dimming is applied separately at paint time).
HOOK(void, flat_updatePixmapCache, "_ZN23KStandardItemListWidget17updatePixmapCacheEv", KStandardItemListWidget *self)
{
    using Fn = void (*)(KStandardItemListWidget *);
    static Fn orig = nextSym<Fn>(flat_updatePixmapCache_sym);
    if (!orig) {
        return;
    }
    if (!shimOk()) {
        orig(self);   // unknown Dolphin version: no private-member access
        return;
    }
    const bool wasHidden = self->m_isHidden;
    self->m_isHidden = false;
    orig(self);
    self->m_isHidden = wasHidden;
}


// Row highlight shape + flat hover. (1) Hover = color only, no outline. Breeze draws the hover of an unselected item as Highlight @ 30% fill plus a 1px outline of the same color @ 80%
// (Style::drawPanelItemViewItemPrimitive - not exported, so it can't be hooked). Dolphin renders the hover into a transparent pixmap cache via
// KItemListWidget::drawItemStyleOption, so wrap that: render the original into a scratch image, clamp every pixel's alpha to the fill's alpha
// (sampled in the middle of the item) so the outline ring becomes exactly the fill color, and paint that instead. Selected rows, the current-item
// focus ring (drawn by the non-hover call) and everything else are left alone.
// (2) Rounded ends: with `edgeradius` > 0 (runtime conf, logical px; Breeze's own corner is ~5) every row highlight (hover / selection / current-item ring)
// is redrawn as a rounded rectangle with that radius on BOTH ends. When a Details row is wider than the viewport (narrow pane / split view) the rectangle
// ends at the viewport edge instead of running square off it. Method: the stock call is rendered into a scratch image, its fill color (centre) and outline
// color (top edge, only if more opaque than the fill) are sampled, and the shape is redrawn on the real painter; a hover is fill-only (no outline).
// Needs the item size and its scene/view geometry (private header: version gated). With edgeradius = 0 only the flat-hover step below runs.
HOOK(void, hoverflat_drawItemStyleOption, "_ZN15KItemListWidget19drawItemStyleOptionEP8QPainterP7QWidget6QFlagsIN6QStyle9StateFlagEE", void *self, QPainter *painter, QWidget *widget, QStyle::State state)
{
    using Fn = void (*)(void *, QPainter *, QWidget *, QStyle::State);
    static Fn orig = nextSym<Fn>(hoverflat_drawItemStyleOption_sym);
    if (!orig) {
        return;
    }
    static const double edgeRadius = rtDouble("edgeradius", 0);
    QPaintDevice *dev = painter->device();
    const bool hover = (state & QStyle::State_MouseOver) && !(state & QStyle::State_Selected);
    bool shape = false;
    qreal vl = 0, vr = 0, itemW = 0, itemH = 0;
    if (edgeRadius > 0 && dev && shimOk()) {
        auto *item = static_cast<KItemListWidget *>(self);
        QGraphicsScene *sc = item->scene();
        if (sc && !sc->views().isEmpty()) {
            QGraphicsView *gv = sc->views().first();
            itemW = item->size().width();
            itemH = item->size().height();
            vl = item->mapFromScene(gv->mapToScene(QPoint(0, 0))).x();                              // viewport's left / right edge in item coordinates
            vr = item->mapFromScene(gv->mapToScene(QPoint(gv->viewport()->width(), 0))).x();
            shape = true;
        }
    }
    if (!dev || (!hover && !shape)) {
        orig(self, painter, widget, state);
        return;
    }
    const qreal dpr = dev->devicePixelRatioF();
    const QSizeF logical = shape ? QSizeF(itemW, itemH) : QSizeF(dev->width() / dpr, dev->height() / dpr);
    const int pw = int(std::ceil(logical.width() * dpr)), ph = int(std::ceil(logical.height() * dpr));
    if (pw < 4 || ph < 4 || pw > 8192 || ph > 2048) {
        orig(self, painter, widget, state);
        return;
    }
    QImage img(pw, ph, QImage::Format_ARGB32_Premultiplied);
    img.setDevicePixelRatio(dpr);
    img.fill(Qt::transparent);
    {
        QPainter ip(&img);
        orig(self, &ip, widget, state);
    }
    if (!shape) {
        // flat hover only (edgeradius off): clamp the outline ring to the fill alpha so it becomes the fill color exactly
        const QRgb fillPx = img.pixel(pw / 2, ph / 2);
        const int fillAlpha = qAlpha(fillPx);
        if (fillAlpha > 0 && fillAlpha < 255) {
            for (int y = 0; y < ph; ++y) {
                QRgb *line = reinterpret_cast<QRgb *>(img.scanLine(y));
                for (int x = 0; x < pw; ++x) {
                    if (qAlpha(line[x]) > fillAlpha) {
                        line[x] = fillPx;
                    }
                }
            }
        }
        painter->drawImage(0, 0, img);
        return;
    }
    // Where the stock highlight actually is (it is inset from the row rectangle, e.g. by the tree-arrow padding): scan the middle row / column for alpha.
    int bx0 = -1, bx1 = -1, by0 = -1, by1 = -1;
    for (int x = 0; x < pw; ++x) {
        if (qAlpha(img.pixel(x, ph / 2)) > 8) {
            if (bx0 < 0) bx0 = x;
            bx1 = x;
        }
    }
    for (int y = 0; y < ph; ++y) {
        if (qAlpha(img.pixel(pw / 2, y)) > 8) {
            if (by0 < 0) by0 = y;
            by1 = y;
        }
    }
    if (bx0 < 0 || by0 < 0) {
        painter->drawImage(0, 0, img);   // nothing recognizable was drawn: leave it as the style made it
        return;
    }
    const QColor fill = img.pixelColor((bx0 + bx1) / 2, ph / 2);
    const QColor edge = img.pixelColor(pw / 2, by0);
    const bool hasOutline = !hover && edge.alpha() > fill.alpha() + 8;
    const qreal hx0 = bx0 / dpr, hx1 = (bx1 + 1) / dpr, hy0 = by0 / dpr, hy1 = (by1 + 1) / dpr;   // stock highlight rect, logical
    const qreal L = std::max(hx0, vl), R = std::min(hx1, vr);                                         // ... limited to what is visible
    const qreal r = std::min<qreal>(edgeRadius, (hy1 - hy0) / 2.0);
    if (R - L < 2 * r) {
        painter->drawImage(0, 0, img);
        return;
    }
    const qreal inset = hasOutline ? 0.5 : 0.0;
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing, true);
    painter->setBrush(fill.alpha() > 0 ? QBrush(fill) : QBrush(Qt::NoBrush));
    painter->setPen(hasOutline ? QPen(edge, 1.0) : QPen(Qt::NoPen));
    painter->drawRoundedRect(QRectF(L + inset, hy0 + inset, R - L - 2 * inset, hy1 - hy0 - 2 * inset), r, r);
    painter->restore();
}
