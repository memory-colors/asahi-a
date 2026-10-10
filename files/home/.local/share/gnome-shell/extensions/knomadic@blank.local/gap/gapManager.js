// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Amir Hossein Karimi

import Clutter from 'gi://Clutter';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export class GapManager {
    constructor(settings) {
        this._settings = settings;
        this._actors = [];
        this._lastSignature = null;
    }

    rebuild(force = false) {
        const margins = this._getMargins();
        const noGapFullscreen = this._settings.get_boolean('no-gap-fullscreen');

        // Real incident, 2026-09-26: rebuild() used to unconditionally tear
        // down and recreate every strut actor on every call, including
        // every focus-change between two windows that are BOTH merely
        // tiled (neither maximized) - a case where the computed state
        // (margins + per-monitor skip-gap flag) is byte-for-byte identical
        // before and after. Destroying and immediately recreating
        // affectsStruts:true chrome actors makes Mutter briefly recompute
        // the work area even when nothing actually changed, which visibly
        // re-snapped/"bounced" already-tiled windows on every alt-tab
        // between them - worse, extension.js's debounce runs rebuild()
        // TWICE per focus change (an immediate pass + a 150ms safety-net
        // retry), doubling the unnecessary churn. Fix: compute the full
        // desired state first, compare against what's already on screen,
        // and skip touching any actor at all if nothing changed.
        //
        // force: a SECOND real incident, same day. Skipping the teardown+
        // recreate also skips the Mutter work-area reflow that tiling
        // windows depend on - without it, a freshly-tiled window can end up
        // cut off until a second tile forces a real rebuild. extension.js
        // passes force=true for signals that mean a window's geometry
        // genuinely changed (size-change, workspace-switched, etc.), which
        // bypasses the no-op check entirely and always does the real
        // teardown+recreate - force=false (pure focus-change) still uses
        // the no-op check above to keep the bounce fix.
        const skipFlags = Main.layoutManager.monitors.map((_monitor, index) =>
            noGapFullscreen && this._monitorShouldSkipGap(index));
        // Monitor geometry is included so a real topology change (dock/undock)
        // is never accidentally treated as a no-op just because margins and
        // skip-flags happen to match the previous state.
        const monitorGeometry = Main.layoutManager.monitors.map(
            m => [m.x, m.y, m.width, m.height]);
        const signature = JSON.stringify({ margins, skipFlags, monitorGeometry });

        if (!force && signature === this._lastSignature)
            return;
        this._lastSignature = signature;

        this._destroyActors();

        for (const [index, monitor] of Main.layoutManager.monitors.entries()) {
            if (skipFlags[index])
                continue;

            if (margins.top > 0)
                this._addEdge(monitor.x, monitor.y, monitor.width, margins.top);

            if (margins.bottom > 0) {
                this._addEdge(
                    monitor.x,
                    monitor.y + monitor.height - margins.bottom,
                    monitor.width,
                    margins.bottom
                );
            }

            if (margins.left > 0)
                this._addEdge(monitor.x, monitor.y, margins.left, monitor.height);

            if (margins.right > 0) {
                this._addEdge(
                    monitor.x + monitor.width - margins.right,
                    monitor.y,
                    margins.right,
                    monitor.height
                );
            }
        }
    }

    destroy() {
        this._destroyActors();
        this._settings = null;
        this._lastSignature = null;
    }

    // True fullscreen (e.g. video/game via F11), or a single window genuinely
    // maximized on BOTH axes (fills the monitor by itself). Deliberately
    // requires maximizedHorizontally AND maximizedVertically, not OR - a
    // tiled-left/right window only has ONE axis maximized (full height, half
    // width), and must keep its gap. Using OR here was the exact bug found
    // and fixed in rounded-windows@marcosgt.github.io earlier this project.
    _monitorShouldSkipGap(index) {
        if (global.display.get_monitor_in_fullscreen(index))
            return true;

        const focusWindow = global.display.focus_window;
        return !!focusWindow &&
            focusWindow.get_monitor() === index &&
            focusWindow.maximizedHorizontally &&
            focusWindow.maximizedVertically;
    }

    _getMargins() {
        if (this._settings.get_boolean('uniform')) {
            const size = this._settings.get_int('gap-size');
            return { top: size, bottom: size, left: size, right: size };
        }

        return {
            top: this._settings.get_int('margin-top'),
            bottom: this._settings.get_int('margin-bottom'),
            left: this._settings.get_int('margin-left'),
            right: this._settings.get_int('margin-right'),
        };
    }

    _addEdge(x, y, width, height) {
        const actor = new Clutter.Actor({
            reactive: false,
            width,
            height,
            x,
            y,
            opacity: 0,
        });

        // GNOME 50 removed affectsInputRegion from addChrome params
        Main.layoutManager.addChrome(actor, {
            affectsStruts: true,
        });

        this._actors.push(actor);
    }

    _destroyActors() {
        for (const actor of this._actors) {
            Main.layoutManager.removeChrome(actor);
            actor.destroy();
        }
        this._actors = [];
    }
}
