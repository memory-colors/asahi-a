// urlbar.cpp - path bar in edit mode: the navigator only paints its pathbar-colored frame fill in breadcrumb mode (patched Breeze, PE_FrameLineEdit),
// so with the location editor open the toolbar's Window color showed around the edit field. Pre-fill the whole navigator with the same `pathbar`
// color (runtime conf = the file Breeze reads) before KUrlNavigator::paintEvent runs. Hook: KUrlNavigator::paintEvent.
#include "common.h"
#include <QLineEdit>

// Path bar in edit mode: the navigator only paints its pathbar-colored frame fill in breadcrumb mode (patched Breeze, PE_FrameLineEdit), so
// with the location editor open the toolbar's Window color showed around the edit field. Pre-fill the whole navigator with the same
// `pathbar=` color (~/.themes/dolphin-theme/breeze-colors.conf, the file Breeze reads) before KUrlNavigator::paintEvent runs.
HOOK(void, navfill_paintEvent, "_ZN13KUrlNavigator10paintEventEP11QPaintEvent", QWidget *self, QPaintEvent *ev)
{
    using Fn = void (*)(QWidget *, QPaintEvent *);
    static Fn orig = nextSym<Fn>(navfill_paintEvent_sym);
    if (!orig) {
        return;
    }
    static const QColor fill = rtColor("pathbar");
    if (fill.isValid()) {
        QPainter p(self);
        p.fillRect(self->rect(), fill);
    }
    // Text color of the location editor: QSS `color` does not reach it (verified with several selectors), so set the QLineEdit palette itself.
    static const QColor text = rtColor("urltext");
    if (text.isValid()) {
        for (QLineEdit *le : self->findChildren<QLineEdit *>()) {
            QPalette p = le->palette();
            if (p.color(QPalette::Text) != text) {
                p.setColor(QPalette::Text, text);
                p.setColor(QPalette::WindowText, text);
                le->setPalette(p);
            }
        }
    }
    orig(self, ev);
}

