// core.cpp - state and services shared by the hooks: runtime config, version gate, and the LD_PRELOAD scrub.
#include "common.h"

#ifndef DT_TESTED_VERSIONS
#define DT_TESTED_VERSIONS "26.08.0 26.08.1"   // Dolphin versions whose kitemviews layout this source was built/tested against
#endif

static double g_paneKeep = 0.53;
thread_local bool g_inactivePaint = false;

// Never leak the preload into child processes (helper programs without Qt symbols abort on load; the harness/test preloads must not nest).
__attribute__((constructor)) static void scrubPreload()
{
    unsetenv("LD_PRELOAD");
}

static const QHash<QString, QString> &rtValues()
{
    static const QHash<QString, QString> values = [] {
        QHash<QString, QString> v;
        const QByteArray out = qgetenv("DOLPHIN_TWEAKS_OUT");
        QFile f((out.isEmpty() ? QDir::homePath() + QStringLiteral("/.themes/dolphin-theme") : QString::fromLocal8Bit(out)) + QStringLiteral("/breeze-colors.conf"));
        if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
            while (!f.atEnd()) {
                const QString line = QString::fromUtf8(f.readLine()).trimmed();
                const int eq = line.indexOf(QLatin1Char('='));
                if (eq > 0) {
                    v.insert(line.left(eq), line.mid(eq + 1).trimmed());
                }
            }
        }
        bool ok = false;
        const double keep = v.value(QStringLiteral("inactivetext")).toDouble(&ok);
        g_paneKeep = ok ? qBound(0.0, keep, 1.0) : 0.53;   // a missing/junk value keeps the default, never 0 (= invisible text)
        return v;
    }();
    return values;
}

double paneKeep()
{
    rtValues();
    return g_paneKeep;
}

QColor rtColor(const char *key)
{
    const QColor c(rtValues().value(QString::fromLatin1(key)));
    return c;   // QColor(QString) is invalid for "" / junk
}

double rtDouble(const char *key, double fallback)
{
    bool ok = false;
    const double d = rtValues().value(QString::fromLatin1(key)).toDouble(&ok);
    return ok ? d : fallback;
}

bool shimOk()
{
    static int state = -1;   // -1 unknown (QApplication not up yet), 0 closed, 1 open
    if (state >= 0) {
        return state == 1;
    }
    if (!QCoreApplication::instance() || QCoreApplication::applicationVersion().isEmpty()) {
        return false;   // too early to know: stay on stock behavior for this call only
    }
    rtValues();   // also primes g_paneKeep
    const QString v = QCoreApplication::applicationVersion();
    const bool forced = qEnvironmentVariableIntValue("DOLPHIN_TWEAKS_FORCE") == 1;
    state = (forced || QString::fromLatin1(DT_TESTED_VERSIONS).split(QLatin1Char(' ')).contains(v)) ? 1 : 0;
    if (state == 0) {
        fprintf(stderr, "dolphin-tweaks: Dolphin %s is not on the tested list (%s); layout-dependent tweaks are OFF. Rebuild the shim against this version "
                        "(shim/build.sh) or set DOLPHIN_TWEAKS_FORCE=1.\n", qPrintable(v), DT_TESTED_VERSIONS);
    }
    return state == 1;
}
