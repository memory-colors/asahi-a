// kinetic.cpp - kinetic touchpad scrolling for the file view. Hook: KItemListContainer::wheelEvent (public Qt API only: no Dolphin headers, no version gate).
// Tunables: INI ~/.config/dolphin-kinetic-scroll.conf, edited by Knomadic (Windows > Gestures); constants below are the defaults.
#include "common.h"
#include <QFileInfo>

// ---------------------------------------------------------------------------------------------------------------------------------------
// KINETIC TOUCHPAD SCROLLING (2026-10-12). Dolphin's file view is QtWidgets (KItemListContainer), so there is no Flickable-style inertia, and
// mutter/Wayland sends only the finger deltas + axis_stop (no momentum). Dolphin also scrolls by angleDelta (~12x the finger distance) via a short
// QPropertyAnimation, so the view never tracks the fingers and stops dead on lift.
// WHAT: overrides the exported virtual KItemListContainer::wheelEvent(QWheelEvent*) (vtable slot is an ABS64 reloc against the symbol, so LD_PRELOAD
// interposes it; no Dolphin headers needed - asm label below). Touchpad events (phase != NoScrollPhase; verified on Qt 6.11 Wayland: Begin(1, zero
// delta) / Update(2) ~8ms apart / End(3) ~100ms after the last Update) are applied to the scrollbar directly (1:1, no easing), and on ScrollEnd a
// QTimer glides with exponential decay from the release velocity. Everything else (real mouse wheel = NoScrollPhase, Ctrl+scroll zoom) is passed
// to the original via dlsym(RTLD_NEXT). Disable for A/B testing: DOLPHIN_KINETIC=0 in the environment.
// Units: Qt wheel/scrollbar values are LOGICAL px (this machine runs 200% scaling); pixelDelta is rounded to int, so angleDelta/12.0 is used
// (measured ratio 11.9-12.0) and the fractional remainder is carried.
static const double KIN_GAIN = 1.5;              // content px per finger px (1.0 = content follows the fingers exactly; >1 = faster, more lines per swipe/flick)
static const double KIN_ANGLE_PER_PX = 12.0;     // angleDelta units per logical px, measured
static const double KIN_DECAY_TAU_S = 0.42;      // glide: v(t) = v0 * exp(-t/tau); total distance = v0 * tau
static const double KIN_MIN_START_VEL = 120.0;   // px/s: slower release than this = no glide
static const double KIN_STOP_VEL = 15.0;         // px/s: glide ends below this
static const double KIN_MAX_VEL = 9000.0;        // px/s clamp
static const int KIN_VEL_WINDOW_MS = 90;         // release velocity = distance over the last this-many ms of Updates
static const int KIN_STALE_MS = 110;             // End later than this after the last Update = fingers were resting -> no glide
static const int KIN_TICK_MS = 40;               // glide WATCHDOG period only: the glide is stepped once per display frame (QWindow::requestUpdate -> UpdateRequest), this covers a missing frame callback

// Runtime overrides (so a UI, e.g. Knomadic's Gestures page, can tune without a rebuild): optional INI ~/.config/dolphin-kinetic-scroll.conf,
// [Kinetic] Gain=<0.1..10>  DecayTau=<0.05..3 s>  MaxVelocity=<px/s>  Enabled=<true|false>. Re-read at every ScrollBegin; missing file/keys = the constants above.
static double g_gain = KIN_GAIN, g_tau = KIN_DECAY_TAU_S, g_maxVel = KIN_MAX_VEL;
static bool g_confEnabled = true;
// DIAGNOSTIC LOG: DOLPHIN_KINETIC_LOG=1 in the environment (start Dolphin from a terminal with all windows closed - a second launch hands off to the running
// instance) or `Log=true` under [Kinetic] in dolphin-kinetic-scroll.conf (re-read at every ScrollBegin, no restart; Knomadic keeps unknown keys). Writes
// ~/.cache/dolphin-kinetic-log.txt (truncated once per Dolphin process): W = touchpad input events, F = frames (UpdateRequest of the window) with the scrollbar
// value shown in that frame, G = glide start, tick-F / tick-T = glide steps driven by a frame / by the 40 ms watchdog, and one SUMMARY line per flick (frame spacing, px per frame, zero/uneven steps, input event spacing).
static bool g_logOn = false;
static FILE *g_logFile = nullptr;
static QElapsedTimer g_logClock;
static double klogNow() { if (!g_logClock.isValid()) g_logClock.start(); return g_logClock.nsecsElapsed() / 1e6; }
static void klog(const char *fmt, ...)
{
    if (!g_logFile) {
        g_logFile = fopen((QDir::homePath() + "/.cache/dolphin-kinetic-log.txt").toLocal8Bit().constData(), "w");
        if (!g_logFile) { g_logOn = false; return; }
        g_logClock.start();
    }
    va_list ap; va_start(ap, fmt); vfprintf(g_logFile, fmt, ap); va_end(ap);
    fputc('\n', g_logFile); fflush(g_logFile);
}
static double kpct(std::vector<double> v, double q)
{
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    return v[std::min(v.size() - 1, size_t(q * v.size()))];
}
static void kineticReloadConfig()
{
    // Cheap on the gesture-start path: re-parse only when the INI changed (a stat otherwise). Knomadic edits it live; no restart needed.
    static QByteArray lastStamp = "unset";
    const QFileInfo fi(QDir::homePath() + "/.config/dolphin-kinetic-scroll.conf");
    const QByteArray stamp = QByteArray::number(fi.exists() ? fi.lastModified().toMSecsSinceEpoch() : -1) + '/' + QByteArray::number(fi.size());
    if (stamp == lastStamp) {
        return;
    }
    lastStamp = stamp;
    QSettings c(QDir::homePath() + "/.config/dolphin-kinetic-scroll.conf", QSettings::IniFormat);
    g_gain = qBound(0.1, c.value("Kinetic/Gain", KIN_GAIN).toDouble(), 10.0);
    g_tau = qBound(0.05, c.value("Kinetic/DecayTau", KIN_DECAY_TAU_S).toDouble(), 3.0);
    g_maxVel = qBound(500.0, c.value("Kinetic/MaxVelocity", KIN_MAX_VEL).toDouble(), 50000.0);
    g_confEnabled = c.value("Kinetic/Enabled", true).toBool();
    g_logOn = (getenv("DOLPHIN_KINETIC_LOG") && getenv("DOLPHIN_KINETIC_LOG")[0] != '0') || c.value("Kinetic/Log", false).toBool();
}

namespace {
struct KineticState : QObject {
    QPointer<QScrollBar> bar;          // axis being driven (vertical or horizontal)
    QTimer timer;
    QElapsedTimer clock;
    std::deque<std::pair<qint64, double>> samples;   // (event timestamp ms, applied px)
    double pos = 0;                    // sub-pixel scroll position
    double vel = 0;                    // px/s (scrollbar-value direction)
    qint64 lastUpdateTs = 0;
    QPointF glideStartMouse;           // cursor position when the glide began (real motion away from it stops the glide)
    bool tracking = false;
    bool gliding = false;
    QPointer<QWindow> win;             // window whose UpdateRequest (frame callback) steps the glide
    bool sessionOpen = false;          // diagnostic log: a touch session (ScrollBegin .. glide end) is being recorded
    std::vector<std::pair<double, int>> frames;   // (ms, scrollbar value) per frame
    std::vector<double> inputTs;       // ms arrival time of each touchpad ScrollUpdate

    explicit KineticState(QAbstractScrollArea *area) : QObject(area)
    {
        timer.setTimerType(Qt::PreciseTimer);
        timer.setInterval(KIN_TICK_MS);
        connect(&timer, &QTimer::timeout, this, [this]() { tick("T"); });
    }
    void stop()
    {
        timer.stop();
        gliding = false;
        vel = 0;
        if (sessionOpen && !tracking) {
            finishSession();   // the touch is over (fingers up) and the glide ended/was interrupted
        }
        if (!sessionOpen) {
            qApp->removeEventFilter(this);
        }
    }
    void beginSession()
    {
        if (!g_logOn || sessionOpen) {
            return;   // Qt can deliver ScrollBegin twice
        }
        sessionOpen = true;
        frames.clear();
        inputTs.clear();
        win = static_cast<QWidget *>(parent())->window()->windowHandle();
        qApp->installEventFilter(this);
        klog("BEGIN t=%.2f gain=%.2f tau=%.2f maxvel=%.0f", klogNow(), g_gain, g_tau, g_maxVel);
    }
    void finishSession()
    {
        sessionOpen = false;
        // Per-frame deltas; the "fast phase" ends at the last frame that moved >= 2 px (after that the glide tail is dominated by whole-pixel rounding).
        std::vector<double> dts, steps;
        for (size_t i = 1; i < frames.size(); ++i) {
            dts.push_back(frames[i].first - frames[i - 1].first);
            steps.push_back(std::abs(frames[i].second - frames[i - 1].second));
        }
        size_t first = 0, last = 0;
        while (first < steps.size() && steps[first] == 0) ++first;
        for (size_t i = 0; i < steps.size(); ++i) if (steps[i] >= 2) last = i;
        std::vector<double> fd, fs;
        for (size_t i = first; i <= last && i < steps.size(); ++i) { fd.push_back(dts[i]); fs.push_back(steps[i]); }
        const double med = kpct(fs, 0.5);
        int zero = 0, uneven = 0;
        for (size_t i = 0; i < fs.size(); ++i) {
            zero += (fs[i] == 0);
            if (i > 0 && i + 1 < fs.size()) {   // local jitter: a step far from the average of its two neighbours (the glide decays smoothly, so this should be ~0)
                const double a = (fs[i - 1] + fs[i + 1]) / 2.0;
                uneven += (std::abs(fs[i] - a) >= std::max(2.0, 0.5 * a));
            }
        }
        const double fastMs = frames.size() > last + 1 && !frames.empty() ? frames[std::min(frames.size() - 1, last + 1)].first - frames[std::min(frames.size() - 1, first)].first : 0;
        const double tailMs = frames.empty() ? 0 : frames.back().first - frames[std::min(frames.size() - 1, last + 1)].first;
        std::vector<double> idts;
        for (size_t i = 1; i < inputTs.size(); ++i) idts.push_back(inputTs[i] - inputTs[i - 1]);
        klog("SUMMARY all_frames=%zu | FAST PHASE %.0f ms, frames=%zu: frame_dt_ms med=%.1f p90=%.1f max=%.1f  step_px med=%.0f p90=%.0f max=%.0f  zero_steps=%d uneven(step >=2px and >=50%% off its neighbours' average)=%d | TAIL %.0f ms (<2px/frame, rounding-dominated) | INPUT events=%zu dt_ms med=%.1f p90=%.1f max=%.1f",
             frames.size(), fastMs, fd.size(), kpct(fd, .5), kpct(fd, .9), kpct(fd, 1.0), med, kpct(fs, .9), kpct(fs, 1.0), zero, uneven, tailMs,
             inputTs.size(), kpct(idts, .5), kpct(idts, .9), kpct(idts, 1.0));
        frames.clear();
        inputTs.clear();
        if (!gliding) {
            qApp->removeEventFilter(this);
        }
    }
    void startGlide()
    {
        glideStartMouse = QPointF(QCursor::pos());
        clock.start();
        gliding = true;
        timer.start();
        win = static_cast<QWidget *>(parent())->window()->windowHandle();
        if (win) {
            win->requestUpdate();
        }
        qApp->installEventFilter(this);   // app-wide only while gliding: mouse events go to the QGraphicsView's INNER viewport widget, not area->viewport()
    }
    // A resting touchpad touch sends NO event on Wayland (libinput reports scrolling only once fingers move), so a glide can be stopped by:
    // a new scroll (ScrollBegin/Update), a click on the view, or REAL pointer motion (spontaneous = not Qt's synthetic hover moves
    // generated when content slides under a still cursor).
    bool eventFilter(QObject *obj, QEvent *ev) override
    {
        if (!gliding && !sessionOpen) {
            return false;
        }
        const QEvent::Type t = ev->type();
        if (t == QEvent::UpdateRequest && obj == win) {
            // Vsync-aligned step: runs just before the window repaints, so exactly one position change lands in each frame.
            if (gliding) {
                tick("F");
            }
            if (sessionOpen && bar) {
                frames.emplace_back(klogNow(), bar->value());
                klog("F t=%.2f bar=%d", frames.back().first, frames.back().second);
            }
            if (gliding && win) {
                win->requestUpdate();
            }
            return false;
        }
        if (!gliding) {
            return false;
        }
        if (t != QEvent::MouseButtonPress && t != QEvent::MouseMove) {
            return false;
        }
        auto *area = static_cast<QWidget *>(parent());
        auto *w = qobject_cast<QWidget *>(obj);
        if (!w || (w != area && !area->isAncestorOf(w))) {
            return false;
        }
        switch (ev->type()) {
        case QEvent::MouseButtonPress:
            stop();
            break;
        case QEvent::MouseMove:
            if (ev->spontaneous()
                && (static_cast<QMouseEvent *>(ev)->globalPosition() - glideStartMouse).manhattanLength() >= 1.0) {
                stop();
            }
            break;
        default:
            break;
        }
        return false;
    }
    // Move to 'target' (clamped); returns false when it could not move because it is at the end of the range.
    bool moveTo(double target)
    {
        if (!bar) {
            return false;
        }
        const double clamped = qBound(double(bar->minimum()), target, double(bar->maximum()));
        pos = clamped;
        const int iv = int(std::lround(clamped));
        if (iv != bar->value()) {
            bar->setValue(iv);   // Dolphin applies this immediately (smooth scrolling only runs inside handleWheelEvent / scrollbar drags)
        }
        return clamped == target;
    }
    void tick(const char *src = "T")
    {
        if (!bar || !bar->isVisible()) {
            stop();
            return;
        }
        const double dt = clock.restart() / 1000.0;
        if (dt <= 0) {
            return;
        }
        vel *= std::exp(-dt / g_tau);
        if (std::fabs(vel) < KIN_STOP_VEL || !moveTo(pos + vel * dt)) {
            stop();
        }
        if (g_logOn) {
            klog("tick-%s t=%.2f dt=%.2f vel=%.1f pos=%.2f bar=%d", src, klogNow(), dt * 1000.0, vel, pos, bar ? bar->value() : -1);
        }
    }
};

typedef void (*WheelFn)(void *, QWheelEvent *);
}

HOOK(void, kinetic_wheelEvent, "_ZN18KItemListContainer10wheelEventEP11QWheelEvent", void *self, QWheelEvent *e)
{
    static const WheelFn orig = nextSym<WheelFn>(kinetic_wheelEvent_sym);
    if (!orig) {
        return;
    }
    static const bool enabled = !(getenv("DOLPHIN_KINETIC") && getenv("DOLPHIN_KINETIC")[0] == '0');
    auto *area = static_cast<QAbstractScrollArea *>(static_cast<QObject *>(self));   // KItemListContainer : QAbstractScrollArea (QObject at offset 0)

    // State object is a child of the container (dies with it); found via a dynamic property so no Q_OBJECT/moc is needed.
    KineticState *st = reinterpret_cast<KineticState *>(area->property("_kineticState").value<quintptr>());
    if (e->phase() == Qt::ScrollBegin) {
        kineticReloadConfig();   // before the enabled check: re-enabling in Knomadic must take effect on the next swipe
    }
    const bool touchpad = enabled && g_confEnabled && e->phase() != Qt::NoScrollPhase && !(e->modifiers() & Qt::ControlModifier);
    if (!touchpad) {
        if (st) {
            st->stop();   // a mouse-wheel notch / Ctrl-zoom interrupts a glide
        }
        orig(self, e);
        return;
    }
    if (!st) {
        st = new KineticState(area);
        area->setProperty("_kineticState", QVariant::fromValue<quintptr>(reinterpret_cast<quintptr>(st)));
    }

    switch (e->phase()) {
    case Qt::ScrollBegin:
        st->stop();
        st->samples.clear();
        st->tracking = true;
        st->beginSession();
        e->accept();
        return;
    case Qt::ScrollEnd: {
        e->accept();
        if (!st->tracking) {
            return;   // Qt delivers End twice
        }
        st->tracking = false;
        double v = 0;
        if (!st->samples.empty() && qint64(e->timestamp()) - st->lastUpdateTs <= KIN_STALE_MS) {
            double sum = 0;
            for (const auto &s : st->samples) {
                if (st->lastUpdateTs - s.first <= KIN_VEL_WINDOW_MS) {
                    sum += s.second;
                }
            }
            v = sum / (KIN_VEL_WINDOW_MS / 1000.0);
        }
        st->samples.clear();
        v = qBound(-g_maxVel, v, g_maxVel);
        if (std::fabs(v) >= KIN_MIN_START_VEL && st->bar) {
            st->vel = v;
            st->pos = st->bar->value() + 0.0;
            if (st->sessionOpen) {
                klog("G t=%.2f release vel=%.1f px/s bar=%d", klogNow(), v, st->bar->value());
            }
            st->startGlide();
        } else if (st->sessionOpen) {
            st->finishSession();   // no glide: the session ends with the fingers
        }
        return;
    }
    default:   // ScrollUpdate (ScrollMomentum is never sent by this Qt/compositor, but would be handled the same)
        break;
    }

    // Axis choice mirrors KItemListContainer::wheelEvent.
    const QPoint ang = e->angleDelta();
    const bool horizontal = std::abs(ang.y()) < std::abs(ang.x()) || !area->verticalScrollBar()->isVisible();
    QScrollBar *bar = horizontal ? area->horizontalScrollBar() : area->verticalScrollBar();
    const double fingerPx = (horizontal ? ang.x() : ang.y()) / KIN_ANGLE_PER_PX;

    st->stop();
    if (st->bar != bar) {
        st->bar = bar;
        st->pos = bar->value();
    } else if (std::fabs(st->pos - bar->value()) > 1.0) {
        st->pos = bar->value();   // someone else moved the bar (keyboard, scrollbar drag, directory change)
    }
    st->tracking = true;
    const double delta = -fingerPx * g_gain;
    if (st->sessionOpen) {
        st->inputTs.push_back(klogNow());
        klog("W t=%.2f ts=%lu ang=%d,%d px=%d,%d delta=%.2f bar=%d", st->inputTs.back(), (unsigned long)e->timestamp(), ang.x(), ang.y(), e->pixelDelta().x(), e->pixelDelta().y(), delta, bar->value());
    }
    if (!st->moveTo(st->pos + delta)) {
        st->samples.clear();   // pinned at an end: no glide from here
    } else {
        st->samples.emplace_back(qint64(e->timestamp()), delta);
        st->lastUpdateTs = qint64(e->timestamp());
        while (!st->samples.empty() && st->lastUpdateTs - st->samples.front().first > KIN_VEL_WINDOW_MS) {
            st->samples.pop_front();
        }
    }
    e->accept();
}

