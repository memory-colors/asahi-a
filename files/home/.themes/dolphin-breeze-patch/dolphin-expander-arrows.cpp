// dolphin-expander-arrows.cpp - LD_PRELOAD shim for Dolphin 26.08.1 (aarch64 Fedora build; same source on Debian: rebuild against Dolphin's own version).
// WHY: Dolphin draws the Details-view expand arrows via style()->drawPrimitive(PE_IndicatorBranch, opt, painter) with NO widget.
// With any application stylesheet (Dolphin runs with -stylesheet dolphin-theme.qss) QStyleSheetStyle swallows that call, so no arrow is
// ever drawn (verified with a Qt test harness: Breeze alone draws it, any stylesheet = 0 pixels; QSS ::branch rules need a widget, don't help).
// WHAT: overrides the exported KStandardItemListWidget::drawSiblingsInformation(QPainter*) and updateExpansionArea() (called through the PLT, so LD_PRELOAD interposes it)
// and paints ONLY a chevron for expandable items: transparent background, NO tree-branch lines.
// Class layout must match the installed libdolphinprivate: rebuild whenever dolphin is updated (kitemviews source of the same version).
// Build: see build line at the bottom. Load: Dolphin launcher Exec=env LD_PRELOAD=~/.themes/kf6-patched/libdolphin-expander-arrows.so ...
#include <QApplication>
#include <QBitArray>
#include <QGraphicsWidget>
#include <QPainter>
#include <QPainterPath>
#include <QPalette>
#include <QPixmap>
#include <QPointF>
#include <QPointer>
#include <QStaticText>
#include <QStyleOption>
#include <QVariant>
#include <QHash>
#include <QByteArray>
#include <QSet>
#include <QList>
#include <QString>
#include <QUrl>
#include <memory>
#include <functional>
#include <map>
#define private public
#define protected public
#include "kitemviews/kstandarditemlistwidget.h"
#include "kitemviews/kitemliststyleoption.h"
#undef private
#undef protected

// Chevron look (logical px): size relative to the 22px expansion area, stroke, colours.
static const qreal ARROW_FRACTION = 0.42;   // chevron width/height as a fraction of the item row height
static const qreal STROKE = 1.6;
static const qreal GAP_REDUCTION = 4.0;      // px the folder icon + name are pulled toward the arrow (arrow itself stays where stock Dolphin puts it)
static const qreal INDENT_FRACTION = 0.5;    // per-level indent = this * icon size (0.5: a child's icon starts at the middle of its parent's icon; stock = one row height)

void KStandardItemListWidget::drawSiblingsInformation(QPainter *painter)
{
    if (!m_isExpandable) {
        return;
    }
    const bool expanded = data().value("isExpanded").toBool();
    const bool ltr = layoutDirection() == Qt::LeftToRight;

    const int siblingSize = size().height();
    const int x = (m_expansionArea.left() + m_expansionArea.right() - siblingSize) / 2;
    // m_expansionArea is shifted by GAP_REDUCTION (see updateExpansionArea), so shift the chevron back to its stock position.
    const QPointF c(x + siblingSize / 2.0 + (ltr ? GAP_REDUCTION : -GAP_REDUCTION), siblingSize / 2.0);
    const qreal h = siblingSize * ARROW_FRACTION / 2.0;   // half extent

    const QPalette &pal = styleOption().palette;
    QColor col = expansionAreaHovered() ? pal.color(QPalette::Highlight).lighter(160) : pal.color(QPalette::Text);
    if (!expansionAreaHovered()) {
        col.setAlphaF(0.75);
    }

    QPainterPath path;
    if (expanded) {            // down: v
        path.moveTo(c.x() - h, c.y() - h / 2);
        path.lineTo(c.x(), c.y() + h / 2);
        path.lineTo(c.x() + h, c.y() - h / 2);
    } else if (ltr) {          // right: >
        path.moveTo(c.x() - h / 2, c.y() - h);
        path.lineTo(c.x() + h / 2, c.y());
        path.lineTo(c.x() - h / 2, c.y() + h);
    } else {                   // left: <
        path.moveTo(c.x() + h / 2, c.y() - h);
        path.lineTo(c.x() - h / 2, c.y());
        path.lineTo(c.x() + h / 2, c.y() + h);
    }
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing, true);
    painter->setBrush(Qt::NoBrush);
    painter->setPen(QPen(col, STROKE, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
    painter->drawPath(path);
    painter->restore();
}
// Override of KStandardItemListWidget::updateExpansionArea(): identical to Dolphin 26.08.1 except the per-level step is
// (iconSize * INDENT_FRACTION) instead of rowHeight, and the whole area is shifted GAP_REDUCTION toward the row start. m_expansionArea also
// positions the icon/name column, so those follow (= smaller gap between arrow and folder icon); the chevron is drawn back at the stock spot.
void KStandardItemListWidget::updateExpansionArea()
{
    if (m_supportsItemExpanding) {
        const QHash<QByteArray, QVariant> values = data();
        const int expandedParentsCount = values.value("expandedParentsCount", 0).toInt();
        if (expandedParentsCount >= 0) {
            const int widgetIconSize = styleOption().iconSize;
            const qreal widgetHeight = size().height();
            const qreal inc = (widgetHeight - widgetIconSize) / 2;
            const qreal x = expandedParentsCount * (widgetIconSize * INDENT_FRACTION) + inc;
            const qreal y = inc;
            if (layoutDirection() == Qt::LeftToRight) {
                const qreal leftPaddingWidth = m_highlightEntireRow ? leftPadding() : 0;
                m_expansionArea = QRectF(leftPaddingWidth + x - GAP_REDUCTION, y, widgetIconSize, widgetIconSize);
                return;
            }
            const qreal rightPaddingWidth = m_highlightEntireRow ? rightPadding() : 0;
            m_expansionArea = QRectF(size().width() - rightPaddingWidth - x - widgetIconSize + GAP_REDUCTION, y, widgetIconSize, widgetIconSize);
            return;
        }
    }
    m_expansionArea = QRectF();
}
// Build (from a dir containing dolphin_export.h = "#define DOLPHIN_EXPORT"; DOLPHIN_SRC = unpacked dolphin-<ver> source):
//   g++ -std=c++20 -O2 -fPIC -shared -I<stubdir> -I$DOLPHIN_SRC/src dolphin-expander-arrows.cpp -o libdolphin-expander-arrows.so $(pkg-config --cflags --libs Qt6Widgets)
