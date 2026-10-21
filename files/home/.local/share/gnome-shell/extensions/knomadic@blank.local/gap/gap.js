// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Amir Hossein Karimi
//
// Window Gap, merged into Knomadic 2026-10-07 (was the standalone window-gap@blank.local extension).
// Logic is unchanged: gapManager.js is a byte-for-byte copy; this file is the old extension.js enable()/disable()
// wrapped in a class. Differences: it reads Knomadic's settings through GapSettings (keys prefixed "windowgap-"),
// and it ignores 'changed' signals for other Knomadic keys.

import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import { GapManager } from './gapManager.js';

const PREFIX = 'windowgap-';
const FORCE_COOLDOWN_MS = 350;   // see rebuild() below: forced requests this soon after a rebuild are our own reflow echoing back: ignore them

// GapManager asks for 'uniform', 'gap-size', 'margin-top', ... ; map them to Knomadic's prefixed keys.
class GapSettings {
    constructor(settings) {
        this._s = settings;
    }

    get_boolean(key) { return this._s.get_boolean(PREFIX + key); }
    get_int(key) { return this._s.get_int(PREFIX + key); }
}

export class WindowGap {
    constructor(settings) {
        this._settings = settings;
    }

    enable() {
        this._gapManager = new GapManager(new GapSettings(this._settings));
        this._rebuildId = 0;
        this._retryId = 0;
        this._pendingForce = false;

        // All rebuild requests are deferred through a timer so rapid signal bursts
        // (e.g. Brave window creation: maximize + workspace-switch + focus-change all
        // fire within one frame) collapse into a single rebuild. A second rebuild runs
        // 150ms later to catch cases where maximizedHorizontally/maximizedVertically
        // haven't settled yet at signal time - confirmed live: gap still showed around
        // a window that was in fact maximized when rebuild ran too early.
        //
        // Previously rebuild() ran synchronously on every signal, which caused a
        // feedback loop: affectsStruts:true chrome actors change the work area, Mutter
        // repositions maximized windows, that fires size-change, which re-triggers
        // rebuild(), and so on - pinning gnome-shell at 76-130% CPU and leaking to
        // 1.8 GB over a session.
        //
        // force: real incident, 2026-09-26. GapManager.rebuild() now skips touching
        // any actor when gap state (margins/skip-flags/monitor geometry) hasn't
        // changed, to fix alt-tab "bouncing" already-tiled windows via unnecessary
        // strut teardown+recreate. But a genuine size-change (a window actually
        // being tiled) relies on that same teardown+recreate to make Mutter reflow
        // the window against the current work area - without it, a freshly-tiled
        // window can end up cut off/not fully tiled until a second tile forces a
        // real rebuild. So size-change (and other genuinely geometry-relevant
        // signals) pass force=true to bypass the no-op check, while pure
        // attention/focus signals (focus-window, restacked) pass force=false and
        // keep the bounce fix. The debounce collapses multiple requests into one
        // call - if ANY of them asked for force, the collapsed call is forced too.
        const rebuild = (force = false) => {
            // Feedback-loop fix (2026-10-10, 2nd version): a forced rebuild destroys/recreates the strut actors, Mutter re-tiles the window and the
            // resulting 'size-change' used to request ANOTHER forced rebuild (flip loop: Konsole 954x1068 <-> 960x1080 several times at open).
            // A forced request that arrives within FORCE_COOLDOWN_MS of a rebuild we just did is that echo: ignore it. The ORIGINAL two-pass
            // design stays intact (forced pass + forced 150ms retry): the first pass leaves a freshly tiled window ungapped, the forced retry's
            // reflow re-applies the gapped tile (making the retry non-forced removed the gap entirely).
            if (force && GLib.get_monotonic_time() / 1000 - (this._lastRebuildAt ?? -1e9) < FORCE_COOLDOWN_MS)
                return;
            if (force)
                this._pendingForce = true;
            if (this._rebuildId)
                return;
            this._rebuildId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 16, () => {
                this._rebuildId = 0;
                const doForce = this._pendingForce;
                this._pendingForce = false;
                this._lastRebuildAt = GLib.get_monotonic_time() / 1000;
                this._gapManager.rebuild(doForce);
                if (this._retryId)
                    GLib.source_remove(this._retryId);
                this._retryId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 150, () => {
                    this._lastRebuildAt = GLib.get_monotonic_time() / 1000;
                    this._gapManager.rebuild(doForce);
                    this._retryId = 0;
                    return GLib.SOURCE_REMOVE;
                });
                return GLib.SOURCE_REMOVE;
            });
        };

        // Knomadic's settings object fires 'changed' for EVERY Knomadic key; only react to the window-gap ones
        this._settings.connectObject('changed', (_settings, key) => {
            if (key.startsWith(PREFIX))
                rebuild(true);
        }, this);
        Main.layoutManager.connectObject('monitors-changed', () => rebuild(true), this);
        global.display.connectObject('in-fullscreen-changed', () => rebuild(true), this);
        // Maximize/unmaximize/tile don't themselves change fullscreen state or
        // monitor topology, so the no-gap-on-maximized check needs its own
        // trigger - size-change fires for any window geometry change
        // (maximize, unmaximize, tile, unfullscreen), and rebuild() is cheap.
        // Forced: this is the actual geometry change tiling relies on to reflow.
        // 2026-10-16: NOT forced any more. The edge strips are the same before and after a tile, so tearing them down and recreating them
        // made mutter lay the tiled window out twice (full half-screen first, then gapped) = the visible "twitch" at the screen edge.
        // Unforced, rebuild() only touches the strips when the computed state really changed (e.g. a window going maximized on both axes
        // drops the gap). To undo: put `rebuild(true)` back here.
        global.window_manager.connectObject('size-change', () => rebuild(false), this);
        // Closing a maximized window (rather than un-maximizing it) doesn't
        // fire size-change on anything - focus just moves elsewhere (or
        // nowhere). Catch that case too. Not forced: pure focus/attention
        // shifts (e.g. alt-tab between two already-tiled windows) shouldn't
        // force a no-op teardown+recreate - that's the bounce this was fixed for.
        global.display.connectObject('notify::focus-window', () => rebuild(false), this);
        // A window arriving on a DIFFERENT workspace that's already maximized (e.g. moved
        // there and activated programmatically) doesn't necessarily fire size-change
        // (nothing resized) or notify::focus-window in every case - the workspace
        // becoming visible is the actual thing that matters here. Forced: the same
        // reflow-on-teardown mechanism tiling needs applies here too.
        global.workspace_manager.connectObject('workspace-switched', () => rebuild(true), this);

        rebuild(true);
    }

    disable() {
        this._settings?.disconnectObject(this);
        Main.layoutManager.disconnectObject(this);
        global.display.disconnectObject(this);
        global.window_manager.disconnectObject(this);
        global.workspace_manager.disconnectObject(this);
        if (this._rebuildId) {
            GLib.source_remove(this._rebuildId);
            this._rebuildId = 0;
        }
        if (this._retryId) {
            GLib.source_remove(this._retryId);
            this._retryId = 0;
        }

        this._gapManager?.destroy();
        this._gapManager = null;
    }
}
