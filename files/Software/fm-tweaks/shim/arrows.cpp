// arrows.cpp - expand/collapse chevrons and tighter folder indent in the Details view.
// WHY: Dolphin draws the Details-view expand arrows via style()->drawPrimitive(PE_IndicatorBranch, opt, painter) with NO widget. With any
// application stylesheet QStyleSheetStyle swallows that call, so no arrow is ever drawn (QSS ::branch rules need a widget, don't help).
// WHAT: redefines the exported KStandardItemListWidget::drawSiblingsInformation(QPainter*) and updateExpansionArea() (called through the PLT, so
// LD_PRELOAD interposes them): paints ONLY a chevron for expandable items (no tree-branch lines) and uses a tighter per-level indent.
// Needs Dolphin's private kitemviews headers of the running version (see shimOk()); on an untested version the stock methods run.
#include "dolphin_private.h"

static const qreal ARROW_FRACTION = 0.42;   // chevron width/height as a fraction of the item row height
static const qreal STROKE = 1.6;
static const qreal INDENT_FRACTION = 0.5;    // per-level indent = this * icon size (0.5: a child's icon starts at the middle of its parent's icon; stock = one row height)
// px the folder icon + name are pulled toward the arrow (arrow itself stays where stock Dolphin puts it); runtime conf `arrowgap`
static qreal gapReduction()
{
    static const qreal g = rtDouble("arrowgap", 4.0);
    return g;
}

void KStandardItemListWidget::drawSiblingsInformation(QPainter *painter)
{
    if (!shimOk()) {
        static const auto stock = nextSym<void (*)(KStandardItemListWidget *, QPainter *)>("_ZN23KStandardItemListWidget23drawSiblingsInformationEP8QPainter");
        if (stock) {
            stock(this, painter);
        }
        return;
    }
    if (!m_isExpandable) {
        return;
    }
    const bool expanded = data().value("isExpanded").toBool();
    const bool ltr = layoutDirection() == Qt::LeftToRight;

    const int siblingSize = size().height();
    const int x = (m_expansionArea.left() + m_expansionArea.right() - siblingSize) / 2;
    // m_expansionArea is shifted by gapReduction() (see updateExpansionArea), so shift the chevron back to its stock position.
    const QPointF c(x + siblingSize / 2.0 + (ltr ? gapReduction() : -gapReduction()), siblingSize / 2.0);
    const qreal h = siblingSize * ARROW_FRACTION / 2.0;   // half extent

    const QPalette &pal = styleOption().palette;
    QColor col = expansionAreaHovered() ? pal.color(QPalette::Highlight).lighter(160) : pal.color(QPalette::Text);
    if (!expansionAreaHovered()) {
        col.setAlphaF(0.75);
    }
    if (g_inactivePaint) {
        col.setAlphaF(col.alphaF() * paneKeep());
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
// (iconSize * INDENT_FRACTION) instead of rowHeight, and the whole area is shifted gapReduction() toward the row start. m_expansionArea also
// positions the icon/name column, so those follow (= smaller gap between arrow and folder icon); the chevron is drawn back at the stock spot.
void KStandardItemListWidget::updateExpansionArea()
{
    if (!shimOk()) {
        static const auto stock = nextSym<void (*)(KStandardItemListWidget *)>("_ZN23KStandardItemListWidget19updateExpansionAreaEv");
        if (stock) {
            stock(this);
        }
        return;
    }
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
                m_expansionArea = QRectF(leftPaddingWidth + x - gapReduction(), y, widgetIconSize, widgetIconSize);
                return;
            }
            const qreal rightPaddingWidth = m_highlightEntireRow ? rightPadding() : 0;
            m_expansionArea = QRectF(size().width() - rightPaddingWidth - x - widgetIconSize + gapReduction(), y, widgetIconSize, widgetIconSize);
            return;
        }
    }
    m_expansionArea = QRectF();
}
