import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { TouchpadGestureRouter } from './src/swipeDetector.js';
import { DiscretePinchGesture } from './src/pinchDetector.js';
import * as VKeyboard from './src/keyboard.js';

// Brave's Fedora RPM registers two real .desktop files that both claim the same
// StartupWMClass - matching either covers it regardless of which one Shell.WindowTracker
// resolves to for a given window.
const BRAVE_APP_IDS = new Set(['brave-browser.desktop', 'com.brave.Browser.desktop']);

// Settings-backed accelerators (Split-view combo, tile-left/right fallback) - see
// schemas/org.gnome.shell.extensions.custom-gestures.gschema.xml and prefs.js. Read live
// on every gesture fire rather than cached, so changing them in Settings takes effect
// immediately with no re-enable needed.
let settings = null;

const MODIFIER_KEYVALS = {
    Control: Clutter.KEY_Control_L,
    Shift: Clutter.KEY_Shift_L,
    Alt: Clutter.KEY_Alt_L,
    Super: Clutter.KEY_Super_L,
};

// GTK accelerator format ("<Control><Shift>t") - the same convention already used
// throughout this project's own gsettings keybinding arrays, so it's consistent with
// what the user already reads/writes elsewhere, not a bespoke format just for this prefs UI.
function parseAccelerator(accel) {
    const keys = [];
    const modifierPattern = /<(\w+)>/g;
    let match;
    while ((match = modifierPattern.exec(accel)) !== null) {
        const modKeyval = MODIFIER_KEYVALS[match[1]];
        if (modKeyval !== undefined)
            keys.push(modKeyval);
    }
    const keyName = accel.replace(/<\w+>/g, '');
    const keyval = Clutter[`KEY_${keyName}`];
    if (keyval !== undefined)
        keys.push(keyval);
    else
        log(`custom-gestures@blank.local: unrecognized key name "${keyName}" in accelerator "${accel}"`);
    return keys;
}

function getSplitViewKeys() {
    return parseAccelerator(settings.get_string('split-view-accelerator'));
}

// Prior approach patched touchpad-gesture-customization@coooolapps.com's own
// overviewRoundTrip.js, which corrupted Main.overview's state machine badly enough to
// SIGABRT-crash gnome-shell repeatedly. This extension owns ALL 3- and 4-finger swipes
// directly, claims them on BEGIN (see TouchpadGestureRouter), and only ever calls simple
// public API - no continuous drag-follow animations.

// Per-app overrides for 3-finger horizontal. Anything not listed falls back to native
// GNOME tile-left/right (the user's own Alt+Super+Left/Right keybinding). the file manager is
// deliberately NOT listed here (it used to be, both directions -> split view) - that
// conflicted with tiling, so split view moved to the middle-click override below instead,
// freeing 3-finger l/r in the file manager to tile like everywhere else.
//
// Keyed by .desktop app id (Shell.WindowTracker), same mechanism the file manager's own override
// uses below and which has been reliable for it throughout. A prior attempt switched
// Brave specifically to window.get_wm_class() matching instead, theorizing Brave's TWO
// registered .desktop files (brave-browser.desktop and com.brave.Browser.desktop, both
// claiming the same StartupWMClass) were the cause of it silently falling through to
// defaults - that switch did NOT fix it (confirmed by further live testing), and
// get_wm_class()'s reliability for a purely native-Wayland client (Brave has no XWayland
// window at all here) was never actually verified. Reverted to app-id matching, instead
// widened to match EITHER of Brave's two real registered ids, which is grounded in a
// confirmed fact rather than an unverified guess about Wayland wm-class reporting.
const braveOverride = {
    left: () => VKeyboard.sendKeys([Clutter.KEY_Control_L, Clutter.KEY_Page_Up]), // previous tab
    right: () => VKeyboard.sendKeys([Clutter.KEY_Control_L, Clutter.KEY_Page_Down]), // next tab
    // 2026-09-26: the override map isn't actually horizontal-specific despite the
    // APP_HORIZONTAL_OVERRIDES name - handleVertical3Finger below checks the same
    // map for a 'down' key. Sends Ctrl+W regardless of fullscreen/maximized state,
    // since it's just a synthetic key event via the virtual keyboard, not a
    // window-state check. Found by Debian Claude, ported here.
    down: () => VKeyboard.sendKeys([Clutter.KEY_Control_L, Clutter.KEY_w]), // close tab
};
const APP_HORIZONTAL_OVERRIDES = {
    'brave-browser.desktop': braveOverride,
    'com.brave.Browser.desktop': braveOverride,
};

// Chromium-based browsers hide their tab/URL bar on ANY OS-level fullscreen (not just
// their own F11/JS-fullscreen-API path) - so for these, the 4-finger-up gesture means
// "maximize" instead of true fullscreen, to keep browser chrome visible.
const FULLSCREEN_AS_MAXIMIZE_APPS = new Set([
    ...BRAVE_APP_IDS,
    'google-chrome.desktop',
    'org.chromium.Chromium.desktop',
    'microsoft-edge.desktop',
]);

// Apps whose split view is driven by the split-view-accelerator (middle-click / 3-finger tap, 3-finger pinch).
const SPLIT_VIEW_APPS = new Set(['thunar.desktop', 'org.xfce.Thunar.desktop']);

function getFocusedAppId() {
    const window = global.display.focus_window;
    if (!window)
        return null;
    const app = Shell.WindowTracker.get_default().get_window_app(window);
    return app ? app.get_id() : null;
}

function handleHorizontal3Finger(direction) {
    const appId = getFocusedAppId();
    const override = appId ? APP_HORIZONTAL_OVERRIDES[appId] : undefined;

    if (override?.[direction]) {
        override[direction]();
        return;
    }

    // default fallback: native tile-left/right
    if (direction === 'left')
        VKeyboard.sendKeys(parseAccelerator(settings.get_string('tile-left-accelerator')));
    else
        VKeyboard.sendKeys(parseAccelerator(settings.get_string('tile-right-accelerator')));
}

function handleVertical4Finger(direction) {
    const window = global.display.focus_window;
    if (!window)
        return;

    if (direction === 'up') {
        const appId = getFocusedAppId();
        if (appId && FULLSCREEN_AS_MAXIMIZE_APPS.has(appId)) {
            // Meta.Window has no get_maximized() method (confirmed via journalctl -
            // "TypeError: window.get_maximized is not a function" - it was throwing and
            // silently aborting this whole handler, including the fullscreen fallback
            // below). Boolean properties are the real API, same as already used
            // correctly in window-gap@amirhosseinkarimi.github.io's gapManager.js.
            if (window.maximizedHorizontally && window.maximizedVertically) {
                window.unmaximize();
            }
            else {
                window.maximize();
                moveToNewWorkspaceRight(window);
                remaximizeAfterGapSettles(window);
            }
        }
        else if (window.is_fullscreen()) {
            window.unmake_fullscreen();
        }
        else {
            window.make_fullscreen();
            moveToNewWorkspaceRight(window);
        }
    }
    else if (direction === 'down') {
        window.delete(global.get_current_time());
    }
}

// Takes over from touchpad-gesture-customization@coooolapps.com, which previously owned
// this one axis - everything else this extension needs was already self-contained. Uses
// the real workspace-manager API directly (Meta.MotionDirection verified against the real
// typelib first) rather than simulating a keybinding - avoids the "wrapper silently
// breaks if the user ever rebinds the underlying shortcut" trap that class of fix has hit
// elsewhere in this project.
function handleHorizontal4Finger(direction) {
    const wsManager = global.workspace_manager;
    const metaDirection = direction === 'left' ? Meta.MotionDirection.LEFT : Meta.MotionDirection.RIGHT;
    const neighbor = wsManager.get_active_workspace().get_neighbor(metaDirection);
    neighbor.activate(global.get_current_time());
}

function handleVertical3Finger(direction) {
    if (direction === 'up') {
        if (!Main.overview.visible)
            Main.overview.show();
    }
    else if (direction === 'down') {
        if (Main.overview.visible) {
            Main.overview.hide();
            return;
        }
        // Same per-app override map handleHorizontal3Finger checks - the
        // 'HORIZONTAL' in the name is stale, the map works for any direction key.
        const appId = getFocusedAppId();
        const override = appId ? APP_HORIZONTAL_OVERRIDES[appId] : undefined;
        if (override?.down) {
            override.down();
            return;
        }
        global.display.focus_window?.minimize();
    }
}

// 3-finger tap surfaces as an ordinary synthesized middle-click (libinput's
// tap-button-map), not a distinct gesture event - so overriding it per-app means
// intercepting real button events, not a swipe tracker. Consumes ALL middle-clicks
// while the file manager is focused (mouse or tap-generated - the user's explicit call, trading
// away the native "middle-click = open in new tab" entirely for split view).
class SplitViewMiddleClickOverride {

    constructor() {
        this._handlerId = global.stage.connect('captured-event', this._onEvent.bind(this));
    }

    _onEvent(_actor, event) {
        const type = event.type();
        if (type !== Clutter.EventType.BUTTON_PRESS && type !== Clutter.EventType.BUTTON_RELEASE)
            return Clutter.EVENT_PROPAGATE;

        // Clutter reports raw pointer button numbers (1/2/3), not a named
        // constant like GDK's BUTTON_MIDDLE.
        if (event.get_button() !== 2)
            return Clutter.EVENT_PROPAGATE;

        if (!SPLIT_VIEW_APPS.has(getFocusedAppId()))
            return Clutter.EVENT_PROPAGATE;

        if (type === Clutter.EventType.BUTTON_PRESS)
            VKeyboard.sendKeys(getSplitViewKeys());

        return Clutter.EVENT_STOP;
    }

    destroy() {
        if (this._handlerId) {
            global.stage.disconnect(this._handlerId);
            this._handlerId = 0;
        }
    }

}

function handlePinch3Finger() {
    if (SPLIT_VIEW_APPS.has(getFocusedAppId()))
        VKeyboard.sendKeys(getSplitViewKeys());
}

// Shared by handleVertical4Finger (any app, on entering fullscreen/maximize via the
// gesture) and BraveNewWorkspaceHandler below (Brave specifically, on window creation).
//
// Finds the lowest-indexed workspace >= 1 (never the desktop at index 0) that has no
// OTHER window on it, and moves this window there. Deliberately NOT "always the next
// workspace over from wherever this window currently is" (which is what simulating the
// native move-to-workspace-right keybinding would do, and what an earlier version of
// this function did) - that would land two apps fullscreened back-to-back on the SAME
// workspace whenever the first one wasn't on the immediately-preceding slot (e.g.
// fullscreen the file manager from the desktop -> workspace 1, then fullscreen Terminal also from
// the desktop -> naive "move one right of my own position" would ALSO put it on
// workspace 1 alongside the file manager, not bump the file manager anywhere - GNOME's native action has no
// concept of "the target's already occupied, go further"). This scans for real vacancy
// instead. Relies on fixed/static workspaces (org.gnome.mutter dynamic-workspaces=false)
// having a stable, known count to scan - the dynamic-mode consolidation problem that the
// keybinding-simulation approach was originally built to dodge no longer applies now that
// static mode + WorkspaceCompactor handle emptying/packing explicitly. Does NOT itself
// maximize/fullscreen - callers handle their own window state, this only ever moves+
// activates. If every app-slot workspace is already occupied, leaves the window where it
// is rather than doubling up on an occupied one.
function moveToNewWorkspaceRight(window) {
    const wsManager = global.workspace_manager;
    const n = wsManager.get_n_workspaces();

    for (let i = 1; i < n; i++) {
        const candidate = wsManager.get_workspace_by_index(i);
        const otherWindows = candidate.list_windows().filter(w => w !== window);
        if (otherWindows.length === 0) {
            window.change_workspace(candidate);
            candidate.activate_with_focus(window, global.get_current_time());
            return;
        }
    }
}

// window-gap@amirhosseinkarimi.github.io removes its screen-edge gap struts reactively,
// once it notices a window is maximized - but window.maximize() itself sizes the window
// against whatever work area exists AT THAT INSTANT, which still has the strut in it (the
// strut hasn't been removed yet at that point - window-gap hasn't reacted yet). Once it
// does react and the strut disappears, nothing re-triggers the now-already-maximized
// window to grow into the newly-available space. Confirmed live two ways: window-gap's
// own debug logging proved its skip-gap logic was correct but the window still looked
// gapped regardless, AND the user found that double-clicking the titlebar (native
// unmaximize->maximize toggle) fixes it instantly - meaning simply calling maximize()
// again on an ALREADY-maximized window is a no-op (Mutter has nothing to recompute if it
// thinks the state isn't changing). Forcing a real unmaximize->maximize transition
// instead, after window-gap's own retry (150ms) should have settled, gets the same effect
// as the manual double-click fix.
function remaximizeAfterGapSettles(window) {
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
        if (window.maximizedHorizontally && window.maximizedVertically) {
            window.unmaximize();
            window.maximize();
        }
        return GLib.SOURCE_REMOVE;
    });
}

// Every new Brave top-level window opens maximized on its own fresh workspace, activated
// and focused. Works alongside WorkspaceCompactor below (org.gnome.mutter
// dynamic-workspaces=false, fixed count) rather than relying on dynamic-workspace
// auto-removal, which the user found disorienting - see that class for why.
function isBraveWindow(window) {
    const app = Shell.WindowTracker.get_default().get_window_app(window);
    return app ? BRAVE_APP_IDS.has(app.get_id()) : false;
}

function openBraveInNewWorkspace(window) {
    window.maximize();
    moveToNewWorkspaceRight(window);
    remaximizeAfterGapSettles(window);
}

class BraveNewWorkspaceHandler {

    constructor() {
        this._handlerId = global.display.connect('window-created', this._onWindowCreated.bind(this));
    }

    _onWindowCreated(_display, window) {
        if (window.get_window_type() !== Meta.WindowType.NORMAL)
            return;

        if (isBraveWindow(window)) {
            openBraveInNewWorkspace(window);
            return;
        }

        // Shell.WindowTracker may not have classified the app yet this early - retry
        // once shortly after in case this really was a Brave window.
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
            if (isBraveWindow(window))
                openBraveInNewWorkspace(window);
            return GLib.SOURCE_REMOVE;
        });
    }

    destroy() {
        if (this._handlerId) {
            global.display.disconnect(this._handlerId);
            this._handlerId = 0;
        }
    }

}

// Keeps workspaces packed with no gaps, EXCEPT index 0 (the user's permanent empty
// "desktop" workspace, never touched). Fixed-count static workspaces (org.gnome.mutter
// dynamic-workspaces=false) don't auto-remove/renumber on their own - the user
// deliberately switched to that mode so workspace 1 stays workspace 1 forever, but that
// also means a workspace that empties out (index >= 1) just sits empty in place unless
// something moves a later workspace's windows into it. When workspace N (N >= 1) empties,
// this finds the lowest-indexed workspace after it that still has windows and moves all
// of them into the gap - so closing whatever's in the middle "pulls" everything after it
// left by one, same net effect the old dynamic-workspace consolidation had, but never
// touching workspace 0. Only switches the visible workspace to the now-filled gap if the
// user was already looking at that exact workspace (i.e. they likely just closed the
// window and are still there) - doesn't yank their view if they're looking elsewhere.
class WorkspaceCompactor {

    constructor() {
        this._workspaceHandlers = new Map();
        this._connectAll();
        this._nWorkspacesHandlerId = global.workspace_manager.connect(
            'notify::n-workspaces', () => this._connectAll());
    }

    _connectAll() {
        this._disconnectAll();
        const wsManager = global.workspace_manager;
        const n = wsManager.get_n_workspaces();
        for (let i = 1; i < n; i++) {
            const workspace = wsManager.get_workspace_by_index(i);
            const id = workspace.connect('window-removed', () => this._onWindowRemoved(workspace));
            this._workspaceHandlers.set(workspace, id);
        }
    }

    _disconnectAll() {
        for (const [workspace, id] of this._workspaceHandlers)
            workspace.disconnect(id);
        this._workspaceHandlers.clear();
    }

    _onWindowRemoved(workspace) {
        if (workspace.list_windows().length !== 0)
            return;

        const wsManager = global.workspace_manager;
        const n = wsManager.get_n_workspaces();
        const wasActive = wsManager.get_active_workspace() === workspace;

        for (let i = workspace.index() + 1; i < n; i++) {
            const candidate = wsManager.get_workspace_by_index(i);
            const windows = candidate.list_windows();
            if (windows.length === 0)
                continue;

            for (const window of windows)
                window.change_workspace(workspace);

            if (wasActive)
                workspace.activate(global.get_current_time());
            return;
        }

        // Nothing to pull in — step back to the previous workspace rather than
        // leaving the user stranded on a now-empty one.
        if (wasActive) {
            const prevIdx = Math.max(0, workspace.index() - 1);
            wsManager.get_workspace_by_index(prevIdx).activate(global.get_current_time());
        }
    }

    destroy() {
        this._disconnectAll();
        if (this._nWorkspacesHandlerId) {
            global.workspace_manager.disconnect(this._nWorkspacesHandlerId);
            this._nWorkspacesHandlerId = 0;
        }
    }

}

// Tiling (and maximize) is reported by mutter as a MAXIMIZE/UNMAXIMIZE size change, and the stock shell answers it with a
// clone-scale-and-fade animation that reads as a "bounce". Completing the change immediately (what the shell does when it
// decides not to animate) removes it; fullscreen and monitor-move keep their animation. The shell connects _sizeChangeWindow
// through a bound copy, so it can't be replaced - but it calls this._prepareAnimationInfo at call time, so an instance property wins.
class NoTileBounce {
    constructor() {
        this._wm = Main.wm;
        this._wm._prepareAnimationInfo = function (shellwm, actor, oldFrameRect, change) {
            if (change === Meta.SizeChange.MAXIMIZE || change === Meta.SizeChange.UNMAXIMIZE) {
                shellwm.completed_size_change(actor);
                return;
            }
            return Object.getPrototypeOf(this)._prepareAnimationInfo.call(this, shellwm, actor, oldFrameRect, change);
        };
    }

    destroy() {
        delete this._wm._prepareAnimationInfo;   // drops the instance override; the prototype method is back
        this._wm = null;
    }
}

export default class CustomGesturesExtension extends Extension {

    enable() {
        settings = this.getSettings();
        this._swipeRouter = new TouchpadGestureRouter({
            '3-horizontal': handleHorizontal3Finger,
            '3-vertical': handleVertical3Finger,
            '4-horizontal': handleHorizontal4Finger,
            '4-vertical': handleVertical4Finger,
        });
        this._pinch3 = new DiscretePinchGesture([3], handlePinch3Finger);
        this._splitViewMiddleClick = new SplitViewMiddleClickOverride();
        this._braveNewWorkspace = new BraveNewWorkspaceHandler();
        this._workspaceCompactor = new WorkspaceCompactor();
        this._noTileBounce = new NoTileBounce();
    }

    disable() {
        this._swipeRouter?.destroy();
        this._swipeRouter = undefined;
        this._pinch3?.destroy();
        this._pinch3 = undefined;
        this._splitViewMiddleClick?.destroy();
        this._splitViewMiddleClick = undefined;
        this._braveNewWorkspace?.destroy();
        this._braveNewWorkspace = undefined;
        this._workspaceCompactor?.destroy();
        this._workspaceCompactor = undefined;
        this._noTileBounce?.destroy();
        this._noTileBounce = undefined;
        VKeyboard.cleanup();
        settings = null;
    }

}
