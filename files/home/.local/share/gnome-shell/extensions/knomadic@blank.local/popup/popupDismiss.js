// Click-outside dismissal for the small prompts of the file-manager setup (fm-newitem = New File / New Folder name prompt, fm-confirm = Shred confirm,
// and Thunar's permanent-delete confirm, which hooks.c titles "fm-popup:delete"). A pointer click anywhere outside such a window closes it (Meta delete = same as its close
// button, so the action is cancelled) and still reaches whatever was clicked. An app cannot see clicks outside its own windows on Wayland and focus-loss is unusable under
// sloppy focus (pointer drift alone changes focus), so the shell does it. Added 2026-10-17.

import Clutter from 'gi://Clutter';

const WM_CLASSES = new Set(['fm-newitem', 'fm-confirm']);
const TITLE_PREFIX = 'fm-popup';

export class PopupDismiss {
    enable() {
        this._id = global.stage.connect('captured-event', (_actor, event) => this._onEvent(event));
    }

    disable() {
        if (this._id)
            global.stage.disconnect(this._id);
        this._id = 0;
    }

    _isPopup(w) {
        if (w.minimized)
            return false;
        const cls = w.get_wm_class?.() ?? '';
        return WM_CLASSES.has(cls) || (w.get_title() ?? '').startsWith(TITLE_PREFIX);
    }

    _onEvent(event) {
        const type = event.type();
        if (type !== Clutter.EventType.BUTTON_PRESS && type !== Clutter.EventType.TOUCH_BEGIN)
            return Clutter.EVENT_PROPAGATE;
        try {
            const [x, y] = event.get_coords();
            for (const actor of global.get_window_actors()) {
                const w = actor.meta_window;
                if (!w || !this._isPopup(w))
                    continue;
                const r = w.get_frame_rect();
                if (x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height)
                    w.delete(global.get_current_time());
            }
        } catch (e) {
            console.error(`Knomadic popup dismiss: ${e}`);
        }
        return Clutter.EVENT_PROPAGATE;
    }
}
