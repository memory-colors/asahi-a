/**
 * extension.js – Rounded Window Corners
 *
 * Applies GLSL-based rounded corners (and an optional custom shadow) to every
 * window that is not already drawn with libadwaita / libhandy.
 *
 * Signal / lifecycle flow
 * ──────────────────────
 * enable()
 *   └─ wait for shell startup → enableEffect()
 *        ├─ connect global signals   (window-created, minimize, unminimize,
 *        │                            destroy, restacked, settings changed)
 *        └─ applyEffectTo() every existing window actor
 *
 * applyEffectTo(actor)
 *   ├─ connect per-window signals  (size, texture size, fullscreen, focus,
 *   │                               workspace-changed)
 *   └─ onAddEffect(actor)
 *        ├─ add RoundedCornersEffect to the actor / surface
 *        ├─ create custom shadow St.Bin (below the actor in windowGroup)
 *        └─ refreshRoundedCorners()
 *
 * disable()
 *   ├─ disableEffect()    → removeEffectFrom() every actor
 *   └─ uninitPrefs()
 */

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import St from 'gi://St';

import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { WindowPreview } from 'resource:///org/gnome/shell/ui/windowPreview.js';
import { WorkspacesView } from 'resource:///org/gnome/shell/ui/workspacesView.js';
import { TopBar } from './topbar/topbar.js';
import { ThemeManager } from './theme/theme.js';
import { QuickSettingsLayout } from './qs/quickSettings.js';
import { PopupDismiss } from './popup/popupDismiss.js';

import { RoundedCornersEffect, ClipShadowEffect } from './effect.js';

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
const ROUNDED_CORNERS_EFFECT = 'rwc-rounded-corners';
const CLIP_SHADOW_EFFECT      = 'rwc-clip-shadow';
const SHADOW_PADDING          = 22;   // minimum extra pixels around the shadow actor (grows with the shadow settings, see shadowPad)
// Ported from Debian 2026-10-06. After a focused window is closed/minimized, mutter hands focus back to the
// LAST-focused window, so a second swipe-quit with a stationary pointer hits the wrong one. This focuses the
// window under the pointer instead. Set false to disable.
const REFOCUS_UNDER_POINTER = true;
// The dhruva dock (the dock actually visible) is scaled by this while the Overview is open (0.8 = 20% smaller).
const OVERVIEW_DOCK_SCALE = 0.8;
// Window previews in the Overview are enlarged by this factor (1.1 = +10%), growing downward from the top edge;
// the factor follows the overview state so the open/close animation still lands on the real windows.
const OVERVIEW_WINDOWS_SCALE = 1.0;
// Same for the desktop background rectangle behind the window previews (matched to the windows by default).
const OVERVIEW_BACKGROUND_SCALE = 1.0;

// ─────────────────────────────────────────────────────────────────────────────
// Module-level state
//   _settings  – Gio.Settings instance (populated by enable())
//   _connections – list of { object, id } for global signal connections
//   _actorMap    – WeakMap<Meta.WindowActor, ActorData>
//
// ActorData = {
//   shadow         : St.Bin | null,
//   propertyBindings: GObject.Binding[],
//   timeoutId      : GLib.Source | 0,
// }
// ─────────────────────────────────────────────────────────────────────────────
let _settings       = null;
let _connections    = [];   // global connections
const _actorMap     = new WeakMap();
let _mutterSettings = null;
let _fractionalScaling = null;

// ─────────────────────────────────────────────────────────────────────────────
// Settings helpers
// ─────────────────────────────────────────────────────────────────────────────
function getS(key)   { return _settings.get_value(key).recursiveUnpack(); }
function getB(key)   { return _settings.get_boolean(key); }
function getI(key)   { return _settings.get_int(key); }
function getD(key)   { return _settings.get_double(key); }

/** Build the per-window config object from GSettings. */
function buildConfig() {
    return {
        cornerRadius: getI('corner-radius'),
        smoothing:    getD('smoothing'),
        padding: {
            top:    getI('padding-top'),
            bottom: getI('padding-bottom'),
            left:   getI('padding-left'),
            right:  getI('padding-right'),
        },
        borderWidth: getI('border-width'),
        borderColor: [
            getD('border-red'),
            getD('border-green'),
            getD('border-blue'),
            getD('border-alpha'),
        ],
        keepRoundedMaximized:  false,   // hard-coded off (the Behaviour switches were removed 2026-10-24)
        keepRoundedFullscreen: false,
    };
}

/** Return the shadow settings for the focused or unfocused state. */
function shadowConfig(focused) {
    const prefix = focused ? 'focused-shadow' : 'unfocused-shadow';
    return {
        opacity:         getI(`${prefix}-opacity`),
        blur:            getI(`${prefix}-blur`),
        spread:          getI(`${prefix}-spread`),
        xOffset:         getI(`${prefix}-x-offset`),
        yOffset:         getI(`${prefix}-y-offset`),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────
function logDbg(msg) {
    if (_settings && getB('debug-mode'))
        console.log(`[RoundedWindows] ${msg}`);
}

// ─────────────────────────────────────────────────────────────────────────────
// Application type detection  (libadwaita / libhandy)
// ─────────────────────────────────────────────────────────────────────────────
const _appTypeCache = new Map();   // pid ↦ 'LibAdwaita' | 'LibHandy' | 'Other'

function getAppType(win) {
    const pid = win.get_pid();
    if (_appTypeCache.has(pid))
        return _appTypeCache.get(pid);

    let type = 'Other';
    try {
        const decoder = new TextDecoder();
        const [, bytes] = GLib.file_get_contents(`/proc/${pid}/maps`);
        const maps = decoder.decode(bytes);
        if (maps.includes('libadwaita-1.so'))
            type = 'LibAdwaita';
        else if (maps.includes('libhandy-1.so'))
            type = 'LibHandy';
    } catch (_) {
        // /proc may not be readable for all pids – treat as 'Other'
    }

    _appTypeCache.set(pid, type);
    return type;
}

/** True when this window should NOT get rounded corners. */
function shouldSkip(win) {
    // DING (Desktop Icons NG) desktop pseudo-window
    // gtkApplicationId is a property in GJS (not a method)
    try {
        const appId = win.gtkApplicationId ?? win.get_gtk_application_id?.();
        if (appId === 'com.rastersoft.ding') return true;
    } catch (_) {}

    // Native Wayland clients that never set an app_id (e.g. winit/Slint apps
    // like Krokiet) report wmClass as permanently null, not just transiently
    // during creation - don't hard-skip on that alone. Blacklist/whitelist
    // matching below tolerates null fine (`[].includes(null)` is just false).
    const wmClass = win.get_wm_class_instance();

    // Only process normal application windows
    const normalTypes = [
        Meta.WindowType.NORMAL,
        Meta.WindowType.DIALOG,
        Meta.WindowType.MODAL_DIALOG,
    ];
    if (!normalTypes.includes(win.windowType))
        return true;

    // Blacklist / whitelist logic:
    //   Normal mode (whitelist-mode = false):
    //     listed windows are EXCLUDED (blacklist)
    //   Whitelist mode (whitelist-mode = true):
    //     only listed windows are INCLUDED, all others are excluded
    const blacklist     = getS('blacklist');
    const whitelistMode = getB('whitelist-mode');
    const isListed      = blacklist.includes(wmClass);

    if (whitelistMode && !isListed)
        return true;   // whitelist mode: skip apps not in the list
    if (!whitelistMode && isListed)
        return true;   // blacklist mode: skip apps in the list

    // Optionally skip libadwaita / libhandy apps (unless explicitly listed)
    const appType = getAppType(win);
    if (getB('skip-libadwaita-app') && appType === 'LibAdwaita' && !isListed)
        return true;
    if (getB('skip-libhandy-app')   && appType === 'LibHandy'   && !isListed)
        return true;

    // Skip maximised / fullscreen windows unless the user explicitly wants
    // rounded corners in those states.
    //
    // PATCHED 2026-09-20: was `||`, which misclassifies a window tiled to
    // just one half of the screen (Mutter sets ONLY maximizedHorizontally
    // for that, not maximizedVertically) as fully "maximized" - meaning
    // disabling keep-rounded-maximized (to save CPU on true full-screen
    // single windows, expensive under software rendering with no GPU) also
    // wrongly squared off tiled-left/right windows, which was never wanted.
    // A window is only genuinely maximized (fills the whole screen by
    // itself) when BOTH dimensions are maximized - use `&&` instead.
    const cfg = buildConfig();
    const isMax  = win.maximizedHorizontally && win.maximizedVertically;
    const isFull = win.fullscreen;

    if (isMax  && !cfg.keepRoundedMaximized)  return true;
    if (isFull && !cfg.keepRoundedFullscreen) return true;

    return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Actor helpers
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Get the Clutter.Actor to which the rounded-corners effect should be applied.
 *
 * Always the WindowActor itself.  For X11/XWayland windows this is
 * critical: MetaWindowActorX11.paint() draws the compositor shadow
 * BEFORE the surface child.  Placing the offscreen effect on the
 * window actor ensures the FBO captures (and the shader can round)
 * both the shadow and the surface in a single pass.
 */
function targetActor(actor) {
    return actor;
}

/** Get the RoundedCornersEffect attached to a window actor (or null). */
function getEffect(actor) {
    const target = targetActor(actor);
    return target ? target.get_effect(ROUNDED_CORNERS_EFFECT) : null;
}

/**
 * Check whether fractional scaling is enabled.
 * When `scale-monitor-framebuffer` is active (default on GNOME 46+ Wayland),
 * the compositor handles scaling at the buffer level and the actor/FBO
 * dimensions already account for the scale.  Returning the raw monitor
 * scale in that case would double-scale all shader values.
 */
function isFractionalScalingEnabled() {
    if (_fractionalScaling !== null)
        return _fractionalScaling;

    try {
        if (!_mutterSettings)
            _mutterSettings = new Gio.Settings({ schema_id: 'org.gnome.mutter' });

        const features = _mutterSettings.get_strv('experimental-features');
        const isWayland = !Meta.is_wayland_compositor || Meta.is_wayland_compositor();
        _fractionalScaling = isWayland && features.includes('scale-monitor-framebuffer');
    } catch (_) {
        _fractionalScaling = false;
    }
    return _fractionalScaling;
}

/** Get the monitor scale factor for a window (respects fractional scaling). */
function scaleFactor(win) {
    // When fractional scaling is enabled the actor dimensions already
    // incorporate the scale, so the shader must use scale = 1.
    if (isFractionalScalingEnabled())
        return 1;

    const idx = win.get_monitor();
    return global.display.get_monitor_scale(idx);
}

/**
 * Compute the offset between the window's buffer rect and its frame rect.
 * CSD windows have invisible resize grips outside the visible frame; this
 * delta lets us clip only the visible part.
 *
 * Returns [dx, dy, dw, dh] (all ≤ 0 for the width/height components).
 */
function contentOffset(win) {
    const buf   = win.get_buffer_rect();
    const frame = win.get_frame_rect();
    return [
        frame.x - buf.x,
        frame.y - buf.y,
        frame.width  - buf.width,
        frame.height - buf.height,
    ];
}

/**
 * Compute the shader bounds (x1, y1, x2, y2) in *actor-local* pixel coords,
 * taking the CSD buffer/frame difference into account.
 * Inset by 1px on all sides to avoid rendering the edge texels of the
 * offscreen FBO, which may be partially transparent.
 */
function computeBounds(actor) {
    const [dx, dy, dw, dh] = contentOffset(actor.metaWindow);
    return {
        x1: dx,
        y1: dy,
        x2: dx + actor.width  + dw,
        y2: dy + actor.height + dh,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Shadow helpers
// ─────────────────────────────────────────────────────────────────────────────

/** Logical padding (px) the shadow actor needs so the CSS box-shadow is never clipped at the actor edge.
 *  box-shadow reaches spread + blur + offset beyond the window; a fixed padding cut it off with a hard edge once those
 *  settings grew past it. Uses the larger of the focused/unfocused shadows so focus changes never resize the actor. */
function shadowPad() {
    let need = 0;
    for (const focused of [true, false]) {
        const c = shadowConfig(focused);
        need = Math.max(need, c.spread + c.blur + Math.max(Math.abs(c.xOffset), Math.abs(c.yOffset)));
    }
    return Math.min(300, Math.max(SHADOW_PADDING, Math.ceil(need) + 2));
}

/** Build the CSS box-shadow string from a shadow config object. */
function boxShadowCss(sc, scale) {
    const alpha  = (sc.opacity / 255).toFixed(3);
    const blur   = (sc.blur   * scale).toFixed(1);
    const spread = (sc.spread * scale).toFixed(1);
    const x      = (sc.xOffset * scale).toFixed(1);
    const y      = (sc.yOffset * scale).toFixed(1);
    return `box-shadow: ${x}px ${y}px ${blur}px ${spread}px rgba(0,0,0,${alpha})`;
}

/** Create and insert a custom shadow St.Bin below the window actor. */
function createShadow(actor) {
    // Outer bin: provides extra padding so the shadow can extend outside
    const shadow = new St.Bin({
        name: 'RWC Shadow',
    });

    // Inner bin: the actual CSS shadow is applied here
    const inner = new St.Bin({ x_expand: true, y_expand: true });
    inner.add_style_class_name('rwc-shadow');
    shadow.set_child(inner);

    // Bind x, y, width, height to the window actor (with padding offsets)
    const [dx, dy, dw, dh] = contentOffset(actor.metaWindow);
    const sc = scaleFactor(actor.metaWindow);
    const pad = shadowPad() * sc;

    const offsets = [
        dx - pad,      // X
        dy - pad,      // Y
        dw + 2 * pad,  // WIDTH
        dh + 2 * pad,  // HEIGHT
    ];

    for (let i = 0; i < 4; i++) {
        shadow.add_constraint(new Clutter.BindConstraint({
            source:     actor,
            coordinate: i,
            offset:     offsets[i],
        }));
    }

    // Clip-shadow effect prevents shadow from showing inside the window
    shadow.add_effect_with_name(CLIP_SHADOW_EFFECT, new ClipShadowEffect());

    global.windowGroup.insert_child_below(shadow, actor);

    refreshShadowStyle(actor, shadow);
    return shadow;
}

/** Update the CSS style of an existing shadow actor. */
function refreshShadowStyle(actor, shadowActor) {
    if (!shadowActor) return;

    const win        = actor.metaWindow;
    const sc         = scaleFactor(win);
    const origScale  = St.ThemeContext.get_for_stage(global.stage).scale_factor;
    const cssScale   = sc / origScale;

    const pad    = shadowPad() * cssScale;
    const cfg    = buildConfig();
    const scfg   = shadowConfig(win.appears_focused);

    // CSS border-radius for the shadow's inner box, matched to the shader's squircle.
    // The shader's corner box is shaderR x shaderR (shaderR = cornerRadius*0.5*exponent) and its curve is |d|_exponent = shaderR,
    // so shaderR is the squircle's SIZE parameter, not its visible radius: using it as a CSS (circular) radius made the shadow
    // corners far rounder than the window (66px vs ~25px at radius 22 / smoothing 0.4). CSS only draws circular arcs, so use the
    // circle whose corner inset along the diagonal equals the squircle's: r_circle = shaderR*(1-2^(-1/e))/(1-1/sqrt2)
    // (= shaderR at e=2). The shadow is only drawn OUTSIDE this box and the clip effect erases it inside the squircle, so a circle
    // that is very slightly rounder than the squircle (x1.08) guarantees no gap shows in the window's transparent corners.
    const exponent    = cfg.smoothing * 10 + 2;
    const shaderR     = cfg.cornerRadius * 0.5 * exponent;
    const circleR     = shaderR * (1 - Math.pow(2, -1 / exponent)) / (1 - Math.SQRT1_2);
    const radius      = circleR * 1.08 * cssScale;

    const inner = shadowActor.get_first_child();
    if (!inner) return;

    // Hide shadow when maximised/fullscreened (unless keep-shadow-maximized).
    // Same `&&` fix as the corner-rounding check above - see that comment.
    const isMax  = win.maximizedHorizontally && win.maximizedVertically;
    const isFull = win.fullscreen;
    const hide   = (isMax || isFull) && !getB('keep-shadow-maximized');

    shadowActor.style = `padding: ${pad}px;`;

    // Use transparent background — NEVER white.  The box-shadow alone provides
    // the visual shadow.  A white background would bleed through the shader's
    // transparent squircle corners because CSS border-radius is circular.
    inner.style = hide
        ? 'opacity: 0;'
        : `background: transparent;
           border-radius: ${radius}px;
           ${boxShadowCss(scfg, cssScale)};
           margin: ${cfg.padding.top    * cssScale}px
                   ${cfg.padding.right  * cssScale}px
                   ${cfg.padding.bottom * cssScale}px
                   ${cfg.padding.left   * cssScale}px;`;
}

/** Update the ClipShadowEffect bounds for a shadow actor.
 *
 * The clip now uses the same squircle parameters as the RoundedCornersEffect
 * so the shadow is transparent exactly where the rounded corners are, with
 * pixel-perfect anti-aliasing along the curved edge.
 */
function refreshShadowClip(actor, shadowActor) {
    if (!shadowActor) return;

    const effect = shadowActor.get_effect(CLIP_SHADOW_EFFECT);
    if (!effect) return;

    const sw = shadowActor.width;
    const sh = shadowActor.height;
    if (sw <= 0 || sh <= 0) return;

    // Window content rect within the shadow actor in pixel coordinates
    const [dx, dy, dw, dh] = contentOffset(actor.metaWindow);
    const sc  = scaleFactor(actor.metaWindow);
    const pad = shadowPad() * sc;

    const cfg    = buildConfig();
    const outerR = cfg.cornerRadius * sc;

    // Use the same exponent / radius formulae as RoundedCornersEffect
    // so the clip contour is identical to the rounded corners shader.
    let exponent = cfg.smoothing * 10 + 2;
    let radius   = outerR * 0.5 * exponent;

    // Account for padding inset (same as RoundedCornersEffect)
    // The shadow actor is already positioned at (frame - pad) by its BindConstraints (offset dx - pad), so the window's frame
    // starts at `pad` in shadow-local coordinates: dx/dy must NOT be added again here (that shifted the clip hole right/down by
    // the buffer margin and left a transparent gap between window and shadow). Width/height of the frame = actor size + dw/dh.
    const bx1 = pad + cfg.padding.left   * sc;
    const by1 = pad + cfg.padding.top    * sc;
    const bx2 = pad + actor.width  + dw - cfg.padding.right  * sc;
    const by2 = pad + actor.height + dh - cfg.padding.bottom * sc;

    const maxR = Math.min(bx2 - bx1, by2 - by1) / 2;
    if (maxR > 0 && radius > maxR) {
        exponent *= maxR / radius;
        radius    = maxR;
    }

    effect.setClip([bx1, by1, bx2, by2], radius, exponent);
    if (getB('debug-mode')) effect._dbgClip = `[${bx1.toFixed(1)},${by1.toFixed(1)},${bx2.toFixed(1)},${by2.toFixed(1)}] r=${radius.toFixed(1)} e=${exponent.toFixed(2)} shadowActor=${sw}x${sh}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Effect application / removal
// ─────────────────────────────────────────────────────────────────────────────

/** Attach the RoundedCornersEffect and a custom shadow to a window actor. */
function onAddEffect(actor) {
    logDbg(`Adding effect to "${actor.metaWindow.title}"`);

    const win = actor.metaWindow;
    if (shouldSkip(win)) {
        logDbg(`  → skipped`);
        return;
    }

    const target = targetActor(actor);
    if (!target) return;

    target.add_effect_with_name(ROUNDED_CORNERS_EFFECT, new RoundedCornersEffect());

    let shadow = null;
    let bindings = [];

    if (getB('custom-shadow')) {
        shadow = createShadow(actor);

        // Mirror visibility / transform from window to shadow
        for (const prop of ['pivot-point', 'translation-x', 'translation-y',
                             'scale-x', 'scale-y', 'visible']) {
            bindings.push(actor.bind_property(prop, shadow, prop,
                GObject.BindingFlags.SYNC_CREATE));
        }
    }

    _actorMap.set(actor, { shadow, bindings, timeoutId: 0 });
    refreshRoundedCorners(actor);
    scheduleResync(actor);   // also re-sorts the shadow below its window once the window has been raised/mapped
    if (getB('debug-mode'))
        for (const ms of [300, 1500])
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => { if (_actorMap.has(actor)) dbgShadowDump(actor, `+${ms}ms`); return GLib.SOURCE_REMOVE; });
}

/** Remove effects and shadow from a window actor. */
function onRemoveEffect(actor) {
    try {
        logDbg(`Removing effect from "${actor.metaWindow?.title}"`);
    } catch (_) {}

    try {
        const target = targetActor(actor);
        if (target)
            target.remove_effect_by_name(ROUNDED_CORNERS_EFFECT);
    } catch (_) {
        // Actor may already be destroyed
    }

    const data = _actorMap.get(actor);
    if (!data) return;

    // Unbind property mirrors
    for (const b of data.bindings)
        b.unbind();

    // Remove and destroy the custom shadow actor
    if (data.shadow) {
        try {
            data.shadow.get_constraints().forEach(c => data.shadow.remove_constraint(c));
            if (data.shadow.get_parent())
                global.windowGroup.remove_child(data.shadow);
            data.shadow.clear_effects();
            data.shadow.destroy();
        } catch (_) {
            // Shadow actor may already be destroyed
        }
    }

    if (data.timeoutId)
        GLib.source_remove(data.timeoutId);

    _actorMap.delete(actor);
}

/** Recompute and push all shader uniforms for a single window. */
function refreshRoundedCorners(actor) {
    const win = actor.metaWindow;
    if (!win) return;

    const data = _actorMap.get(actor);
    const fx   = getEffect(actor);

    // If neither the effect nor actor data exists, add the effect.
    // Guard against re-entry: only call onAddEffect when there is no _actorMap
    // entry yet (avoids the infinite loop onAddEffect → refreshRoundedCorners
    // → onAddEffect …). onAddEffect calls refreshRoundedCorners itself at the
    // end, so we just return here.
    if (!fx && !data) {
        onAddEffect(actor);
        return;
    }

    if (shouldSkip(win)) {
        if (data) onRemoveEffect(actor);
        return;
    }

    if (!fx) return;   // effect was removed due to shouldSkip during onAddEffect
    if (!fx.enabled) fx.enabled = true;

    const cfg = buildConfig();
    fx.updateUniforms(scaleFactor(win), cfg, computeBounds(actor));

    // Update shadow
    if (data) {
        refreshShadowStyle(actor, data.shadow);
        refreshShadowClip(actor, data.shadow);

        // Keep BindConstraint offsets in sync with the current window geometry
        const [dx, dy, dw, dh] = contentOffset(win);
        const sc  = scaleFactor(win);
        const pad = shadowPad() * sc;
        const newOffsets = [dx - pad, dy - pad, dw + 2 * pad, dh + 2 * pad];

        if (data.shadow) {
            data.shadow.get_constraints().forEach((c, i) => {
                if (c instanceof Clutter.BindConstraint)
                    c.offset = newOffsets[i];
            });
        }

        if (getB('debug-mode')) {
            const fr = win.get_frame_rect(), bf = win.get_buffer_rect(), sh = data.shadow;
            const geo = `${win.get_wm_class()} frame=${fr.x},${fr.y} ${fr.width}x${fr.height} buf=${bf.x},${bf.y} ${bf.width}x${bf.height} ` +
                `actor=${actor.x},${actor.y} ${actor.width}x${actor.height} d=[${dx},${dy},${dw},${dh}] pad=${pad} ` +
                `shadow=${sh ? `${sh.x},${sh.y} ${sh.width}x${sh.height}` : 'none'} max=${win.maximizedHorizontally}/${win.maximizedVertically}`;
            if (data.lastGeo !== geo) { data.lastGeo = geo; logDbg(`GEO ${geo}`); }
        }
    }
}

/** Refresh the shadow style / position for a single actor. */
function refreshFocus(actor) {
    const data = _actorMap.get(actor);
    if (data?.shadow)
        refreshShadowStyle(actor, data.shadow);
}

/** Remove and re-add the effect for a window actor. */
function refreshAll() {
    for (const actor of global.get_window_actors())
        refreshRoundedCorners(actor);
}

/** When windows are re-stacked, keep shadow actors sorted below their windows. */
function onRestacked() {
    for (const actor of global.get_window_actors()) {
        const data = _actorMap.get(actor);
        if (actor.visible && data?.shadow)
            global.windowGroup.set_child_below_sibling(data.shadow, actor);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Global signal management
// ─────────────────────────────────────────────────────────────────────────────

function addConnection(obj, signal, cb) {
    _connections.push({ object: obj, id: obj.connect(signal, cb) });
}

function removeConnections(obj) {
    let i = _connections.length;
    while (i--) {
        const c = _connections[i];
        if (!obj || c.object === obj) {
            c.object.disconnect(c.id);
            _connections.splice(i, 1);
        }
    }
}

function disconnectAll() {
    for (const c of _connections)
        c.object.disconnect(c.id);
    _connections = [];
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-window signal setup / teardown
// ─────────────────────────────────────────────────────────────────────────────

/** Re-sync a window's shadow/shader once more shortly after a geometry change. Tiling/untiling and drags update the frame
 *  rect and the buffer rect at different moments, so the first refresh (on actor size) can read a stale frame-vs-buffer
 *  offset and leave the shadow actor misplaced (blank gap, missing side). One pending timer per window. */
function scheduleResync(actor) {
    const data = _actorMap.get(actor);
    if (!data || data.timeoutId) return;
    data.timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 80, () => {
        data.timeoutId = 0;
        if (_actorMap.has(actor) && actor.metaWindow) {
            refreshRoundedCorners(actor);
            fixShadowOrder(actor);
        }
        return GLib.SOURCE_REMOVE;
    });
}

/** Debug: one-shot dump of everything that decides whether a window's shadow is actually painted (debug-mode only). */
function dbgShadowDump(actor, tag) {
    try {
        const d = _actorMap.get(actor), sh = d?.shadow;
        if (!sh) return;
        const wg = global.windowGroup, kids = wg.get_children();
        const i = kids.indexOf(sh), j = kids.indexOf(actor);
        const nm = a => a ? (a.metaWindow ? `W:${a.metaWindow.get_wm_class()}` : (a.name || a.constructor.name)) : 'none';
        const ab = sh.get_allocation_box(), [tx, ty] = sh.get_transformed_position(), [tw, th] = sh.get_transformed_size();
        const eff = sh.get_effect(CLIP_SHADOW_EFFECT), inner = sh.get_first_child();
        logDbg(`SHADOW ${tag} ${actor.metaWindow?.get_wm_class()}: visible=${sh.visible} opacity=${sh.opacity} paintOpacity=${sh.get_paint_opacity()} mapped=${sh.mapped} ` +
            `alloc=${ab.x1.toFixed(0)},${ab.y1.toFixed(0)}..${ab.x2.toFixed(0)},${ab.y2.toFixed(0)} stage=${tx.toFixed(0)},${ty.toFixed(0)} ${tw.toFixed(0)}x${th.toFixed(0)} ` +
            `stack shadow=${i} actor=${j}/${kids.length} below=${nm(kids[i - 1])} above=${nm(kids[i + 1])} ` +
            `effect=${eff ? `enabled=${eff.enabled}` : 'MISSING'} clip=${eff?._dbgClip ?? 'unset'} inner="${(inner?.style ?? '').replace(/\s+/g, ' ').slice(0, 70)}" ` +
            `actorVisible=${actor.visible} actorOpacity=${actor.opacity} actorMapped=${actor.mapped} winMax=${actor.metaWindow?.maximizedHorizontally}/${actor.metaWindow?.maximizedVertically}`);
    } catch (e) {
        logDbg(`SHADOW dump failed: ${e}`);
    }
}

/** Keep a window's shadow directly below its window actor in the window group. The 'restacked' handler alone missed the open
 *  path (the new window is raised AFTER its shadow is created without another restack), so a new window's shadow stayed under
 *  other windows until the first move/restack: it vanished over any window it overlapped. */
function fixShadowOrder(actor) {
    const sh = _actorMap.get(actor)?.shadow;
    const wg = global.windowGroup;
    if (sh && actor.get_parent() === wg && sh.get_parent() === wg)
        wg.set_child_below_sibling(sh, actor);
}

function attachWindowSignals(actor) {
    const win     = actor.metaWindow;
    const texture = actor.get_texture();

    // Window resized → update shader uniforms
    addConnection(actor,   'notify::size',  () => { if (actor.metaWindow) refreshRoundedCorners(actor); });
    if (texture)
        addConnection(texture, 'size-changed', () => { if (actor.metaWindow) refreshRoundedCorners(actor); });

    // Frame geometry / tile / maximise state changed: refresh now and once more after mutter settles
    const resync = () => { if (actor.metaWindow) { refreshRoundedCorners(actor); scheduleResync(actor); } };
    addConnection(win, 'raised', () => { if (actor.metaWindow) fixShadowOrder(actor); });
    addConnection(win, 'size-changed',                   resync);
    addConnection(win, 'notify::maximized-horizontally', resync);
    addConnection(win, 'notify::maximized-vertically',   resync);

    // Fullscreen state changed (may not cause a size change)
    addConnection(win, 'notify::fullscreen',     () => { if (actor.metaWindow) refreshRoundedCorners(actor); });
    // Focus changed → update shadow style
    addConnection(win, 'notify::appears-focused',() => { if (actor.metaWindow) refreshFocus(actor); });
    // Monitor / workspace change
    addConnection(win, 'workspace-changed',      () => { if (actor.metaWindow) refreshFocus(actor); });
}

function applyEffectTo(actor) {
    // Wayland XWayland windows may not have a surface child yet
    if (!actor.firstChild) {
        const connId = actor.connect('notify::first-child', () => {
            applyEffectTo(actor);
            actor.disconnect(connId);
        });
        return;
    }

    if (!actor.get_texture()) return;

    // Add the effect FIRST, then connect signals. If signals were connected
    // before the effect, adding the effect could trigger notify::size
    // synchronously, causing re-entrant calls to refreshRoundedCorners
    // before _actorMap has been populated.
    onAddEffect(actor);
    attachWindowSignals(actor);
}

function removeEffectFrom(actor) {
    removeConnections(actor);
    removeConnections(actor.metaWindow);
    const tex = actor.get_texture();
    if (tex) removeConnections(tex);
    onRemoveEffect(actor);
}

// ─────────────────────────────────────────────────────────────────────────────
// Global enable / disable
// ─────────────────────────────────────────────────────────────────────────────

function enableEffect() {
    // Apply to all existing windows
    for (const actor of global.get_window_actors())
        applyEffectTo(actor);

    // New window created
    addConnection(global.display, 'window-created',
        (_, win) => {
            const actor = win.get_compositor_private();
            // Native Wayland clients that never set an app_id (e.g.
            // winit/Slint apps like Krokiet) report wmClass as permanently
            // null, not just transiently during creation - waiting for
            // notify::wm-class here meant applyEffectTo() (and so
            // onAddEffect) never ran at all for them. Just apply
            // unconditionally; shouldSkip() already tolerates null wmClass.
            applyEffectTo(actor);
        });

    // Debug: shadow state around an interactive move (why does the shadow vanish while dragging?)
    const dbgDrag = (tag, actor) => {
        const d = _actorMap.get(actor), sh = d?.shadow;
        if (!sh) return;
        const wg = global.windowGroup, kids = wg.get_children();
        const inner = sh.get_first_child();
        logDbg(`DRAG ${tag} ${actor.metaWindow?.get_wm_class()}: shadow visible=${sh.visible} opacity=${sh.opacity} mapped=${sh.mapped} ` +
            `alloc=${sh.x},${sh.y} ${sh.width}x${sh.height} inner="${(inner?.style ?? '').replace(/\s+/g, ' ').slice(0, 90)}" ` +
            `stack shadow=${kids.indexOf(sh)} actor=${kids.indexOf(actor)} of ${kids.length} effects=${sh.get_effects?.().length ?? '?'}`);
    };
    addConnection(global.display, 'grab-op-begin', (_d, win) => {
        const actor = win?.get_compositor_private?.();
        if (!actor || !getB('debug-mode') || !_actorMap.has(actor)) return;
        dbgDrag('begin', actor);
        for (const ms of [120, 600])
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => { if (_actorMap.has(actor)) dbgDrag(`+${ms}ms`, actor); return GLib.SOURCE_REMOVE; });
    });

    // End of an interactive move/resize (e.g. untiling by dragging): re-sync that window's shadow
    addConnection(global.display, 'grab-op-end', (_d, win) => {
        const actor = win?.get_compositor_private?.();
        if (actor && _actorMap.has(actor)) {
            if (getB('debug-mode')) dbgDrag('end', actor);
            refreshRoundedCorners(actor); scheduleResync(actor);
        }
    });

    // Window closed
    addConnection(global.windowManager, 'destroy',
        (_, actor) => removeEffectFrom(actor));

    // Minimise: always hide shadow + disable effect to prevent the white
    // background of the shadow actor from showing during the animation.
    addConnection(global.windowManager, 'minimize',
        (_, actor) => {
            const data = _actorMap.get(actor);
            if (data?.shadow)
                data.shadow.visible = false;
            const fx = getEffect(actor);
            if (fx) fx.enabled = false;
        });

    // Unminimise: restore shadow + effect.  For the Magic-Lamp extension,
    // wait until the animation is nearly finished before showing the shadow.
    addConnection(global.windowManager, 'unminimize',
        (_, actor) => {
            const data = _actorMap.get(actor);
            const fx   = getEffect(actor);

            const lamp = actor.get_effect('unminimize-magic-lamp-effect');
            if (lamp && data?.shadow && fx) {
                data.shadow.visible = false;
                const timer = lamp.timerId;
                if (timer) {
                    const tid = timer.connect('new-frame', src => {
                        if (src.get_progress() > 0.98) {
                            data.shadow.visible = true;
                            fx.enabled = true;
                            src.disconnect(tid);
                        }
                    });
                }
                return;
            }

            // Standard unminimise (no magic lamp)
            if (data?.shadow)
                data.shadow.visible = true;
            if (fx) fx.enabled = true;
        });

    // Window re-stack → reorder shadow actors
    addConnection(global.display, 'restacked', onRestacked);

    // Settings changed → reapply all
    addConnection(_settings, 'changed', () => {
        _appTypeCache.clear();
        refreshAll();
    });
}

function disableEffect() {
    for (const actor of global.get_window_actors())
        removeEffectFrom(actor);
    disconnectAll();
    _appTypeCache.clear();
}

// ─────────────────────────────────────────────────────────────────────────────
// Extension class
// ─────────────────────────────────────────────────────────────────────────────

export default class RoundedWindowCornersExtension extends Extension {

    #startupConnection = null;

    enable() {
        _settings = this.getSettings();
        this.#startTheme();
        logDbg('Enabling…');

        if (Main.layoutManager._startingUp) {
            // GNOME Shell is still starting up – wait until it is ready
            this.#startupConnection = Main.layoutManager.connect(
                'startup-complete', () => {
                    enableEffect();
                    this.#hideWorldClocks();
                    Main.layoutManager.disconnect(this.#startupConnection);
                    this.#startupConnection = null;
                },
            );
        } else {
            enableEffect();
            this.#hideWorldClocks();
        }
        this.#startRefocus();
        this.#startTopBar();
        this.#startTiling();
        this.#startPopupDismiss();
        this.#startOverviewTweaks();
        this.#startQsLayout();
    }

    // ── Shell theme loader (merged from the stock User Themes extension, see theme/). Started first so the theme loads even if
    //    something later in enable() fails. ──
    #theme = null;

    #startTheme() {
        try {
            this.#theme = new ThemeManager(_settings);
            this.#theme.enable();
        } catch (e) {
            console.error('Knomadic theme loader failed to start: ' + e);
            this.#theme = null;
        }
    }

    #stopTheme() {
        try {
            this.#theme?.disable();
        } catch (e) {
            console.error('Knomadic theme loader failed to stop cleanly: ' + e);
        }
        this.#theme = null;
    }

    // ── Quarter tiling: Tiling Assistant folded in (see tiling/NOTICE.md). Loaded with a dynamic import inside try/catch so that a
    //    shell API change on a GNOME upgrade can only disable tiling, never Knomadic itself. ──
    #tiling = null;
    #tilingToken = 0;
    #tilingSig = 0;
    #tilingCss = null;

    #startTiling() {
        if (!this.#tilingSig)   // the prefs switch starts/stops it live
            this.#tilingSig = _settings.connect('changed::quarter-tiling', () => { this.#stopTiling(); this.#startTiling(); });
        if (!_settings.get_boolean('quarter-tiling')) return;
        const token = ++this.#tilingToken;
        const dir = Gio.File.new_for_path(GLib.build_filenamev([this.path, 'tiling']));
        import('./tiling/extension.js').then(async mod => {
            if (token !== this.#tilingToken) return;   // disabled again while loading
            const ta = new mod.default({
                'uuid': 'tiling-assistant@leleat-on-github', 'name': 'Tiling Assistant (in Knomadic)', 'version': 56,
                'settings-schema': 'org.gnome.shell.extensions.tiling-assistant', 'dir': dir, 'path': dir.get_path(),
            });
            this.#tiling = ta;
            try {   // upstream's stylesheet.css (popup / focus hint / layout picker styles), which a normal extension gets loaded automatically
                this.#tilingCss = Gio.File.new_for_path(GLib.build_filenamev([dir.get_path(), 'stylesheet.css']));
                St.ThemeContext.get_for_stage(global.stage).get_theme().load_stylesheet(this.#tilingCss);
            } catch (e) { console.error(`Knomadic tiling stylesheet: ${e}`); this.#tilingCss = null; }
            await ta.enable();
        }).catch(e => {
            console.error(`Knomadic quarter tiling failed to start: ${e}`);
            try { this.#tiling?.disable(); } catch (e2) { /* ignore */ }
            this.#tiling = null;
        });
    }

    #stopTiling(final = false) {
        this.#tilingToken++;
        if (final && this.#tilingSig) { _settings.disconnect(this.#tilingSig); this.#tilingSig = 0; }
        try {
            this.#tiling?.disable();
        } catch (e) {
            console.error(`Knomadic quarter tiling failed to stop cleanly: ${e}`);
        }
        this.#tiling = null;
        if (this.#tilingCss) {
            try { St.ThemeContext.get_for_stage(global.stage).get_theme().unload_stylesheet(this.#tilingCss); } catch (e) { /* ignore */ }
            this.#tilingCss = null;
        }
    }

    // ── Click-outside dismissal of the file-manager prompts (see popup/popupDismiss.js) ──
    #popupDismiss = null;

    #startPopupDismiss() {
        try {
            this.#popupDismiss = new PopupDismiss();
            this.#popupDismiss.enable();
        } catch (e) {
            console.error(`Knomadic popup dismiss failed to start: ${e}`);
            this.#popupDismiss = null;
        }
    }

    #stopPopupDismiss() {
        try {
            this.#popupDismiss?.disable();
        } catch (e) {
            console.error(`Knomadic popup dismiss failed to stop cleanly: ${e}`);
        }
        this.#popupDismiss = null;
    }

    // ── Top Bar (see topbar/). Off until 'topbar-enabled' is set ──
    #topBar = null;
    #topBarSettingId = 0;

    #startTopBar() {
        try {
            if (!this.#topBarSettingId) {
                this.#topBarSettingId = _settings.connect('changed::topbar-enabled', () => {
                    this.#stopTopBar(true);
                    this.#startTopBar();
                });
            }
            if (!_settings.get_boolean('topbar-enabled'))
                return;
            this.#topBar = new TopBar(_settings);
            this.#topBar.enable();
        } catch (e) {
            console.error(`Knomadic Top Bar failed to start: ${e}`);
            try { this.#topBar?.disable(); } catch (e2) { /* ignore */ }
            this.#topBar = null;
        }
    }

    #stopTopBar(keepSettingsHandler = false) {
        try {
            this.#topBar?.disable();
        } catch (e) {
            console.error(`Knomadic Top Bar failed to stop cleanly: ${e}`);
        }
        this.#topBar = null;
        if (!keepSettingsHandler && this.#topBarSettingId) {
            _settings?.disconnect(this.#topBarSettingId);
            this.#topBarSettingId = 0;
        }
    }

    // ── Quick Settings / Date Menu layout (qs/quickSettings.js; replaces the quick-settings-tweaks extension) ──
    #qsLayout = null;

    #startQsLayout() {
        try {
            this.#qsLayout = new QuickSettingsLayout(_settings);
            this.#qsLayout.enable();
        } catch (e) {
            console.error(`Knomadic QS layout failed to start: ${e}`);
            try { this.#qsLayout?.disable(); } catch (e2) { /* ignore */ }
            this.#qsLayout = null;
        }
    }

    #stopQsLayout() {
        try {
            this.#qsLayout?.disable();
        } catch (e) {
            console.error(`Knomadic QS layout failed to stop cleanly: ${e}`);
        }
        this.#qsLayout = null;
    }

    // ── Overview tweaks (user request 2026-10-06, replaces two abandoned extensions) ──
    //  1. search box invisible until the user types (typing still starts a search; it empties/hides again)
    //  2. no app icons on the window previews
    //  3. no window titles on the previews
    #searchTextId = 0;
    #origUpdateIconScale = null;
    #origShowOverlay = null;
    #layoutPatches = [];

    #startOverviewTweaks() {
        try {
            this.#hideTopBarInOverview();
            logDbg(`OVERVIEW top-bar fade hooked (own topBar=${!!this.#topBar})`);
        } catch (e) {
            logDbg(`top-bar tweak failed: ${e}`);
        }
        try {
            const entry = Main.overview.searchEntry;
            const text = entry.clutter_text;
            const sync = () => { entry.opacity = text.text ? 255 : 0; };
            this.#searchTextId = text.connect('text-changed', sync);
            sync();
            if (getB('debug-mode')) {
                const wid = entry.connect('notify::opacity', () => {
                    if (Main.overview.visible)
                        logDbg(`OVERVIEW search-entry opacity changed to ${entry.opacity} by: ${new Error().stack.split('\n').slice(1, 6).join(' | ')}`);
                });
                const sid = Main.overview.connect('shown', () => {
                    const bin = Main.overview._overview?._controls?._searchEntryBin;
                    logDbg(`OVERVIEW search-entry when shown: entry opacity=${entry.opacity} visible=${entry.visible} mapped=${entry.mapped} ` +
                        `bin opacity=${bin?.opacity} bin h=${bin?.height} bin parent=${bin?.get_parent()}`);
                });
                this.#layoutPatches.push(() => { entry.disconnect(wid); Main.overview.disconnect(sid); });
            }
            logDbg(`OVERVIEW search-entry hooked (entry=${entry?.constructor?.name}, opacity=${entry.opacity})`);
        } catch (e) {
            logDbg(`search-entry tweak failed: ${e}`);
        }
        try {
            const controls = Main.overview._overview._controls;
            const bin = controls._searchEntryBin;
            const entry = Main.overview.searchEntry;
            const origH = bin.get_preferred_height.bind(bin);
            // 0 height while the box is empty so the layout reclaims its space (thumbnails move to the top)
            bin.get_preferred_height = w => entry.clutter_text.text ? origH(w) : [0, 0];
            this.#layoutPatches.push(() => { delete bin.get_preferred_height; });
            const relayout = () => controls.layout_manager.layout_changed();
            const id = entry.clutter_text.connect('text-changed', relayout);
            this.#layoutPatches.push(() => entry.clutter_text.disconnect(id));

            // inactive (neighbour) workspaces stay at 100% instead of shrinking to 94% (no jump when switching)
            const wsProto = WorkspacesView.prototype;
            const origState = wsProto._updateWorkspacesState;
            wsProto._updateWorkspacesState = function () {
                origState.call(this);
                this._workspaces.forEach(w => {
                    w.set_scale(1, 1);
                    const c = w._container;
                    if (c) {
                        const k = 1 + (OVERVIEW_WINDOWS_SCALE - 1) * Math.clamp(w.stateAdjustment.value, 0, 1);
                        c.set_pivot_point(0.5, 0.0);
                        c.set_scale(k, k);
                    }
                    const bg = w._background;
                    if (bg) {
                        const kb = 1 + (OVERVIEW_BACKGROUND_SCALE - 1) * Math.clamp(w.stateAdjustment.value, 0, 1);
                        bg.set_pivot_point(0.5, 0.0);
                        bg.set_scale(kb, kb);
                    }
                });
            };
            this.#layoutPatches.push(() => { wsProto._updateWorkspacesState = origState; });
            this.#layoutPatches.push(() => {
                for (const w of Main.overview._overview._controls._workspacesDisplay._workspacesViews?.flatMap(v => v._workspaces ?? []) ?? [])
                    { w._container?.set_scale(1, 1); w._background?.set_scale(1, 1); }
            });
            relayout();

            // Top bar space: the Overview lays out inside the monitor's work area, which starts below the top bar.
            // Extend that box (Overview-only; real windows keep their struts) up to the screen edge so the thumbnails
            // use the strip the faded-out bar leaves behind.
            const lm = controls.layout_manager;
            const origWorkArea = lm._updateWorkAreaBox.bind(lm);
            lm._updateWorkAreaBox = () => {
                origWorkArea();
                const box = lm._workAreaBox;
                const top = box.y1;
                if (top > 0) {
                    box.set_origin(box.x1, 0);
                    box.set_size(box.get_width(), box.get_height() + top);
                }
            };
            this.#layoutPatches.push(() => { delete lm._updateWorkAreaBox; lm._updateWorkAreaBox(); relayout(); });
            lm._updateWorkAreaBox();
            relayout();

            // dhruva dock: smaller while the Overview is open, anchored at its bottom centre
            const findDock = () => {
                const walk = a => {
                    if (a.name === 'DhruvaContainer')
                        return a;
                    for (const c of a.get_children()) {
                        const r = walk(c);
                        if (r)
                            return r;
                    }
                    return null;
                };
                return walk(Main.layoutManager.uiGroup);
            };
            // dhruva's layout engine re-applies dockUI.actor.set_scale(layoutScale) on every layout pass, which silently undid our
            // ease (the dock stayed full size in the Overview). Wrap the dock's set_scale (instance method) so our overview factor is
            // multiplied into whatever scale dhruva asks for; ease towards base*factor. dhruva keeps owning the pivot point.
            const patchDock = dock => {
                if (dock._knomadicFactor !== undefined)
                    return;
                dock._knomadicFactor = 1;
                dock._knomadicOrigSetScale = dock.set_scale;
                dock.set_scale = (sx, sy) => dock._knomadicOrigSetScale.call(dock, sx * dock._knomadicFactor, sy * dock._knomadicFactor);
            };
            const unpatchDock = dock => {
                if (dock?._knomadicFactor === undefined)
                    return;
                dock.remove_all_transitions();
                const f = dock._knomadicFactor;
                delete dock.set_scale;
                delete dock._knomadicOrigSetScale;
                delete dock._knomadicFactor;
                dock.set_scale(dock.scale_x / f, dock.scale_y / f);
            };
            const scaleDock = factor => {
                const dock = findDock();
                logDbg(`OVERVIEW dock scale ${factor}: ${dock ? 'DhruvaContainer found' : 'DhruvaContainer NOT FOUND'}`);
                if (!dock)
                    return;
                patchDock(dock);
                const baseX = dock.scale_x / dock._knomadicFactor, baseY = dock.scale_y / dock._knomadicFactor;
                dock._knomadicFactor = factor;
                dock.remove_all_transitions();
                dock.ease({ scale_x: baseX * factor, scale_y: baseY * factor, duration: 250, mode: Clutter.AnimationMode.EASE_OUT_QUAD });
                if (getB('debug-mode'))
                    GLib.timeout_add(GLib.PRIORITY_DEFAULT, 600, () => {
                        logDbg(`OVERVIEW dock after 600ms: scale=${dock.scale_x.toFixed(3)} factor=${dock._knomadicFactor} pivot=${dock.pivot_point.x.toFixed(2)},${dock.pivot_point.y.toFixed(2)}`);
                        return GLib.SOURCE_REMOVE;
                    });
            };
            const ids = [
                Main.overview.connect('showing', () => scaleDock(OVERVIEW_DOCK_SCALE)),
                Main.overview.connect('hiding', () => scaleDock(1)),
            ];
            this.#layoutPatches.push(() => {
                ids.forEach(i => Main.overview.disconnect(i));
                unpatchDock(findDock());
            });
            logDbg('OVERVIEW layout/dock/work-area hooks installed');
        } catch (e) {
            logDbg(`overview layout tweak failed: ${e}`);
        }
        try {
            const proto = WindowPreview.prototype;
            this.#origUpdateIconScale = proto._updateIconScale;
            const orig = this.#origUpdateIconScale;
            proto._updateIconScale = function () {
                orig.call(this);
                this._icon.visible = false;
            };
            // 3. no window titles: the title fades in on hover via showOverlay (the close button stays)
            this.#origShowOverlay = proto.showOverlay;
            const origShow = this.#origShowOverlay;
            proto.showOverlay = function (...args) {
                origShow.apply(this, args);
                this._title.hide();
            };
            logDbg('OVERVIEW window-preview icon/title hooks installed');
        } catch (e) {
            logDbg(`window-icon tweak failed: ${e}`);
        }
    }

    // Knomadic's top bar fades out while the Overview is open. Opacity is used on purpose: intellihide drives
    // the box's translation but never touches opacity, so the two don't fight.
    #hideTopBarInOverview() {
        const boxes = () => this.#topBar
            ? [Main.layoutManager.panelBox]
            : [];
        // A non-reactive parent does not stop its REACTIVE children from being picked, so the invisible bar's buttons (calendar, quick
        // settings) still caught clicks meant for the workspace thumbnails under it. Switch every reactive actor of the bar off while
        // the Overview is open and remember which ones to switch back on.
        const offActors = new Set();
        const inputOff = a => {
            if (a.reactive) { offActors.add(a); a.reactive = false; }
            for (const c of a.get_children()) inputOff(c);
        };
        const inputOn = () => {
            for (const a of offActors) { try { a.reactive = true; } catch (e) { /* destroyed meanwhile */ } }
            offActors.clear();
        };
        const fade = (opacity, reactive) => boxes().forEach(b => {
            logDbg(`OVERVIEW top-bar fade to ${opacity} on ${b}`);
            b.remove_transition('opacity');
            if (reactive) inputOn(); else inputOff(b);
            b.reactive = reactive;
            b.ease({ opacity, duration: 200, mode: Clutter.AnimationMode.EASE_OUT_QUAD });
        });
        const dbgBoxes = () => {
            if (!getB('debug-mode')) return;
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                boxes().forEach(b => logDbg(`OVERVIEW top-bar 500ms after showing: ${b} opacity=${b.opacity} visible=${b.visible} mapped=${b.mapped} ` +
                    `parent=${b.get_parent()} panelBox===layoutManager.panelBox:${b === Main.layoutManager.panelBox}`));
                return GLib.SOURCE_REMOVE;
            });
        };
        const watch = [];
        if (getB('debug-mode'))
            for (const b of boxes())
                watch.push([b, b.connect('notify::opacity', () => {
                    if (Main.overview.visible)
                        logDbg(`OVERVIEW top-bar opacity changed to ${b.opacity} by: ${new Error().stack.split('\n').slice(1, 6).join(' | ')}`);
                })]);
        const ids = [
            Main.overview.connect('showing', () => { fade(0, false); dbgBoxes(); }),
            Main.overview.connect('hiding', () => fade(255, true)),
        ];
        this.#layoutPatches.push(() => {
            ids.forEach(i => Main.overview.disconnect(i));
            watch.forEach(([b, id]) => b.disconnect(id));
            inputOn();
            boxes().forEach(b => { b.remove_transition('opacity'); b.opacity = 255; b.reactive = true; });
        });
    }

    #stopOverviewTweaks() {
        for (const undo of this.#layoutPatches.splice(0)) {
            try { undo(); } catch (e) { /* ignore */ }
        }
        try {
            if (this.#searchTextId) {
                Main.overview.searchEntry.clutter_text.disconnect(this.#searchTextId);
                Main.overview.searchEntry.opacity = 255;
            }
        } catch (e) { /* ignore */ }
        this.#searchTextId = 0;
        if (this.#origUpdateIconScale) {
            WindowPreview.prototype._updateIconScale = this.#origUpdateIconScale;
            this.#origUpdateIconScale = null;
        }
        if (this.#origShowOverlay) {
            WindowPreview.prototype.showOverlay = this.#origShowOverlay;
            this.#origShowOverlay = null;
        }
    }

    // ── Refocus window under the pointer after close/minimize (see REFOCUS_UNDER_POINTER) ──
    #refocusIds = [];
    #refocusTimer = 0;
    #lastFocus = null;

    #startRefocus() {
        if (!REFOCUS_UNDER_POINTER || this.#refocusIds.length)
            return;
        try {
            const display = global.display;
            this.#lastFocus = display.focus_window;
            this.#refocusIds.push([display, display.connect('notify::focus-window', () => {
                if (display.focus_window)
                    this.#lastFocus = display.focus_window;
            })]);
            const wm = global.window_manager;
            // tile/resize: after a tile (mutter reports it as a size change) the tiled window can leave the pointer over a window that was underneath it,
            // but sloppy focus only reacts to pointer MOTION, so focus would stay on the tiled window
            this.#refocusIds.push([wm, wm.connect('size-changed', (_wm, actor) => {
                try {
                    this.#onWindowResized(actor);
                } catch (e) {
                    logDbg(`refocus error: ${e}`);
                }
            })]);
            for (const sig of ['destroy', 'minimize']) {
                this.#refocusIds.push([wm, wm.connect(sig, (_wm, actor) => {
                    try {
                        this.#onWindowGone(actor);
                    } catch (e) {
                        logDbg(`refocus error: ${e}`);
                    }
                })]);
            }
        } catch (e) {
            logDbg(`refocus setup failed: ${e}`);
        }
    }

    #stopRefocus() {
        for (const [obj, id] of this.#refocusIds)
            obj.disconnect(id);
        this.#refocusIds = [];
        if (this.#refocusTimer) {
            GLib.source_remove(this.#refocusTimer);
            this.#refocusTimer = 0;
        }
        this.#lastFocus = null;
    }

    #onWindowGone(actor) {
        const gone = actor?.meta_window;
        if (gone && [Meta.WindowType.POPUP_MENU, Meta.WindowType.DROPDOWN_MENU, Meta.WindowType.MENU, Meta.WindowType.COMBO].includes(gone.get_window_type())) {
            // a context menu closed: its grab kept the pointer from entering the window it was moved onto, and sloppy focus only reacts to motion,
            // so focus the window under the pointer (only when the focused window no longer covers it)
            if (this.#refocusTimer)
                GLib.source_remove(this.#refocusTimer);
            this.#refocusTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 60, () => {
                this.#refocusTimer = 0;
                try {
                    const f = global.display.focus_window;
                    const [px, py] = global.get_pointer();
                    const r = f?.get_frame_rect();
                    if (!r || px < r.x || px >= r.x + r.width || py < r.y || py >= r.y + r.height)
                        this.#refocusUnderPointer(null, true);
                } catch (e) {
                    logDbg(`refocus error: ${e}`);
                }
                return GLib.SOURCE_REMOVE;
            });
            return;
        }
        if (!gone || gone !== this.#lastFocus)
            return;
        if (gone.get_window_type() !== Meta.WindowType.NORMAL || gone.get_transient_for())
            return;
        this.#lastFocus = null;
        if (this.#refocusTimer)
            GLib.source_remove(this.#refocusTimer);
        this.#refocusTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 60, () => {
            this.#refocusTimer = 0;
            try {
                this.#refocusUnderPointer(gone);
            } catch (e) {
                logDbg(`refocus error: ${e}`);
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    #onWindowResized(actor) {
        const w = actor?.meta_window;
        if (!w || w !== global.display.focus_window)
            return;
        if (w.get_window_type() !== Meta.WindowType.NORMAL || w.get_transient_for())
            return;
        if (this.#refocusTimer)
            GLib.source_remove(this.#refocusTimer);
        this.#refocusTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 150, () => {
            this.#refocusTimer = 0;
            try {
                // only when the focused window no longer covers the pointer, and only onto a window that IS under it (never onto the desktop/top window)
                const [px, py] = global.get_pointer();
                const r = w.get_frame_rect();
                const inside = px >= r.x && px < r.x + r.width && py >= r.y && py < r.y + r.height;
                if (!inside && w === global.display.focus_window)
                    this.#refocusUnderPointer(w, true);
            } catch (e) {
                logDbg(`refocus error: ${e}`);
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    #refocusUnderPointer(gone, strict = false) {
        if (Main.overview.visible)
            return;
        const ws = global.workspace_manager.get_active_workspace();
        const [px, py] = global.get_pointer();
        const wins = global.get_window_actors()
            .map(a => a.meta_window)
            .filter(w => w && w !== gone && !w.minimized &&
                w.get_window_type() === Meta.WindowType.NORMAL &&
                (w.located_on_workspace(ws) || w.on_all_workspaces));
        // get_window_actors() is bottom-to-top; search from the top
        let target = null;
        for (let i = wins.length - 1; i >= 0; i--) {
            const r = wins[i].get_frame_rect();
            if (px >= r.x && px < r.x + r.width && py >= r.y && py < r.y + r.height) {
                target = wins[i];
                break;
            }
        }
        if (!target && !strict)
            target = wins[wins.length - 1] ?? null;
        if (target && target !== global.display.focus_window)
            target.activate(global.get_current_time());
    }

    // ── Calendar dropdown: remove the "World Clocks" / "Add World Clocks…" box ──
    // The date menu keeps it as dateMenu._clocksItem and (re)shows it whenever the Clocks app is installed
    // (WorldClocksSection._sync), so hide it and re-hide on any visibility change. CSS cannot hide a widget
    // in GNOME Shell, and hiding the Clocks launcher would remove the app, so this lives here (user request
    // 2026-10-05). disable() restores the stock behaviour by re-running the section's own _sync().
    #clocksItem = null;
    #clocksVisId = 0;

    #hideWorldClocks() {
        const item = Main.panel?.statusArea?.dateMenu?._clocksItem;
        if (!item || this.#clocksItem)
            return;
        this.#clocksItem = item;
        item.visible = false;
        this.#clocksVisId = item.connect('notify::visible', () => {
            if (item.visible)
                item.visible = false;
        });
    }

    #restoreWorldClocks() {
        const item = this.#clocksItem;
        if (!item)
            return;
        if (this.#clocksVisId) {
            item.disconnect(this.#clocksVisId);
            this.#clocksVisId = 0;
        }
        this.#clocksItem = null;
        if (typeof item._sync === 'function')
            item._sync();
    }

    disable() {
        logDbg('Disabling…');

        if (this.#startupConnection !== null) {
            Main.layoutManager.disconnect(this.#startupConnection);
            this.#startupConnection = null;
        }

        this.#stopQsLayout();
        this.#stopOverviewTweaks();
        this.#stopTiling(true);
        this.#stopPopupDismiss();
        this.#stopTheme();
        this.#stopTopBar();
        this.#stopRefocus();
        this.#restoreWorldClocks();
        disableEffect();
        _settings = null;
        _mutterSettings = null;
        _fractionalScaling = null;
    }
}
