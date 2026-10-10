// Quick Settings + Date Menu layout, merged into Knomadic 2026-10-09 (replaces the standalone quick-settings-tweaks extension).
// Deliberately small: reorder/hide quick toggles, reorder/hide system indicators, reorder/hide the bottom-row items, hide the
// date menu's left box, monochrome privacy indicators. Settings: Knomadic keys qs-*. Hardcoded: toggles not in the order list
// are hidden; BackgroundAppsToggle is never touched.

import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { QuickToggle, QuickMenuToggle, SystemIndicator } from 'resource:///org/gnome/shell/ui/quickSettings.js';

const CLS_HIDE_LEFT = 'knomadic-qs-hide-left-box';
const CLS_PRIVACY = 'knomadic-qs-privacy-monochrome';

export class QuickSettingsLayout {
    constructor(settings) {
        this._s = settings;
        this._hidden = new Map();   // actor -> {id, wasVisible}
        this._conns = [];           // [object, id]
        this._idle = 0;
    }

    enable() {
        this._qs = Main.panel.statusArea.quickSettings;
        if (!this._qs)
            return;
        this._grid = this._qs.menu._grid;
        this._indicators = this._qs._indicators;

        this._connect(this._grid, 'child-added', () => this._applyToggles());
        this._connect(this._indicators, 'child-added', () => this._applyIndicators());
        for (const key of ['qs-toggle-order', 'qs-toggle-hidden', 'qs-indicator-order', 'qs-indicator-hidden',
            'qs-items-order', 'qs-items-hidden', 'qs-datemenu-hide-left'])
            this._connect(this._s, `changed::${key}`, () => this._applyAll());

        this._indicators.add_style_class_name(CLS_PRIVACY);
        this._applyAll();
    }

    disable() {
        for (const [obj, id] of this._conns)
            obj.disconnect(id);
        this._conns = [];
        if (this._idle) {
            GLib.source_remove(this._idle);
            this._idle = 0;
        }
        this._unhideAll();
        this._indicators?.remove_style_class_name(CLS_PRIVACY);
        this._dateBox?.remove_style_class_name(CLS_HIDE_LEFT);
        this._dateBox = null;
        this._qs = this._grid = this._indicators = null;
    }

    _connect(obj, sig, fn) {
        this._conns.push([obj, obj.connect(sig, fn)]);
    }

    // hide + keep hidden (the shell re-shows many of these on state changes)
    _hide(actor) {
        if (this._hidden.has(actor)) {
            actor.hide();
            return;
        }
        const id = actor.connect('show', () => actor.hide());
        this._hidden.set(actor, { id, wasVisible: actor.visible });
        actor.connect('destroy', () => this._hidden.delete(actor));
        actor.hide();
    }

    _unhide(actor) {
        const rec = this._hidden.get(actor);
        if (!rec)
            return;
        actor.disconnect(rec.id);
        this._hidden.delete(actor);
        if (rec.wasVisible)
            actor.show();
    }

    _unhideAll() {
        for (const actor of [...this._hidden.keys()])
            this._unhide(actor);
    }

    _applyAll() {
        this._applyToggles();
        this._applyIndicators();
        this._applyItems();
        this._applyDateMenu();
    }

    // Moves `ordered` (actors, already in the wanted order) to the front of the container.
    _reorder(container, ordered) {
        let last = null;
        for (const a of ordered) {
            if (last)
                container.set_child_above_sibling(a, last);
            last = a;
        }
    }

    _applyToggles() {
        if (!this._grid)
            return;
        const order = this._s.get_strv('qs-toggle-order');
        const hidden = new Set(this._s.get_strv('qs-toggle-hidden'));
        const toggles = this._grid.get_children().filter(c =>
            (c instanceof QuickToggle || c instanceof QuickMenuToggle) && c.constructor.name !== 'BackgroundAppsToggle');
        const ordered = [];
        for (const name of order) {
            const t = toggles.find(c => c.constructor.name === name);
            if (t)
                ordered.push(t);
        }
        for (const t of toggles) {
            if (!ordered.includes(t) || hidden.has(t.constructor.name))
                this._hide(t);
            else
                this._unhide(t);
        }
        this._reorder(this._grid, ordered);
    }

    _applyIndicators() {
        if (!this._indicators)
            return;
        const order = this._s.get_strv('qs-indicator-order');
        const hidden = new Set(this._s.get_strv('qs-indicator-hidden'));
        const all = this._indicators.get_children().filter(c => c instanceof SystemIndicator);
        const name = c => GObject.type_name_from_instance(c);
        for (const c of all) {
            if (hidden.has(name(c)))
                this._hide(c);
            else
                this._unhide(c);
        }
        if (!order.length)
            return;
        const ordered = [];
        for (const n of order) {
            const c = all.find(x => name(x) === n);
            if (c)
                ordered.push(c);
        }
        this._reorder(this._indicators, ordered);
    }

    _applyItems() {
        const run = () => {
            const sys = this._qs?._system?._systemItem;
            if (!sys)
                return false;
            const byClass = n => sys.child.get_children().find(c => c.constructor.name === n);
            const items = {
                screenshot: byClass('ScreenshotItem'),
                settings: byClass('SettingsItem'),
                lock: byClass('LockItem'),
                shutdown: byClass('ShutdownItem'),
                battery: sys.powerToggle,
                laptopSpacer: sys._laptopSpacer,
                desktopSpacer: sys._desktopSpacer,
            };
            const hidden = new Set(this._s.get_strv('qs-items-hidden'));
            for (const [id, actor] of Object.entries(items)) {
                if (!actor)
                    continue;
                if (hidden.has(id))
                    this._hide(actor);
                else
                    this._unhide(actor);
            }
            const order = this._s.get_strv('qs-items-order');
            if (order.length)
                this._reorder(sys.child, order.map(id => items[id]).filter(Boolean));
            return true;
        };
        if (run() || this._idle)
            return;
        // the system item is built lazily at startup - retry until it exists
        this._idle = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            if (!run())
                return GLib.SOURCE_CONTINUE;
            this._idle = 0;
            return GLib.SOURCE_REMOVE;
        });
    }

    _applyDateMenu() {
        const dm = Main.panel.statusArea.dateMenu;
        if (!dm)
            return;
        this._dateBox = dm.menu.box;
        const left = dm.menu.box.first_child?.first_child?.get_first_child();
        if (this._s.get_boolean('qs-datemenu-hide-left')) {
            if (left)
                this._hide(left);
            this._dateBox.add_style_class_name(CLS_HIDE_LEFT);
        } else {
            if (left)
                this._unhide(left);
            this._dateBox.remove_style_class_name(CLS_HIDE_LEFT);
        }
    }
}
