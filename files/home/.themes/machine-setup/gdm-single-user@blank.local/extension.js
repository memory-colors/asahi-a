/**
 * gdm-single-user@blank.local - GDM greeter only (session-modes: ["gdm"]).
 *
 * GNOME's login dialog always shows the user list + "Not listed?" first, even with one account
 * (LoginDialog._onReset -> _showUserList). This wraps _showUserList on the live dialog instance
 * (Main.screenShield._dialog is the LoginDialog in the greeter) and, once the user list has loaded
 * with exactly one entry, activates it - the same call a click on the tile makes.
 *
 * Everything is try/catch'd: if anything here fails the stock greeter keeps working.
 */
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

const POLL_MS = 100;
const GIVE_UP_MS = 6000;

export default class GdmSingleUser extends Extension {
    #dialog = null;
    #origShowUserList = null;
    #pollId = 0;
    #findId = 0;

    enable() {
        // The dialog is created when the greeter starts; extensions load after, but poll in case it is not there yet.
        let waited = 0;
        this.#findId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POLL_MS, () => {
            waited += POLL_MS;
            const dialog = Main.screenShield?._dialog;
            if (dialog?._userList && dialog._showUserList) {
                this.#findId = 0;
                this.#patch(dialog);
                return GLib.SOURCE_REMOVE;
            }
            if (waited >= GIVE_UP_MS) {
                this.#findId = 0;
                return GLib.SOURCE_REMOVE;
            }
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        if (this.#findId) {
            GLib.source_remove(this.#findId);
            this.#findId = 0;
        }
        this.#stopPoll();
        if (this.#dialog && this.#origShowUserList)
            delete this.#dialog._showUserList;
        this.#dialog = null;
        this.#origShowUserList = null;
    }

    #patch(dialog) {
        try {
            this.#dialog = dialog;
            this.#origShowUserList = dialog._showUserList.bind(dialog);
            dialog._showUserList = () => {
                this.#origShowUserList();
                this.#autoPickWhenLoaded(dialog);
            };
            // The list may already be on screen by the time we get here.
            if (dialog._userSelectionBox?.visible)
                this.#autoPickWhenLoaded(dialog);
        } catch (e) {
            console.error(`gdm-single-user: patch failed: ${e}`);
        }
    }

    // Single-account machine by design: no escape hatch needed. (If a 2nd account ever appears, the exact-one check
    // below simply stops auto-picking and the stock user list returns.)
    #shouldAutoPick(dialog) {
        return dialog._userList.numItems() === 1;
    }

    #autoPickWhenLoaded(dialog) {
        this.#stopPoll();
        let waited = 0;
        this.#pollId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POLL_MS, () => {
            waited += POLL_MS;
            try {
                if (!dialog._userSelectionBox?.visible)
                    return waited >= GIVE_UP_MS ? this.#endPoll() : GLib.SOURCE_CONTINUE;
                const n = dialog._userList.numItems();
                if (n === 0)
                    return waited >= GIVE_UP_MS ? this.#endPoll() : GLib.SOURCE_CONTINUE;
                if (n === 1 && this.#shouldAutoPick(dialog)) {
                    const [item] = dialog._userList._items.values();
                    this.#pollId = 0;
                    dialog._onUserListActivated(item);
                    return GLib.SOURCE_REMOVE;
                }
            } catch (e) {
                console.error(`gdm-single-user: auto-pick failed: ${e}`);
            }
            return this.#endPoll();
        });
    }

    #endPoll() {
        this.#pollId = 0;
        return GLib.SOURCE_REMOVE;
    }

    #stopPoll() {
        if (this.#pollId) {
            GLib.source_remove(this.#pollId);
            this.#pollId = 0;
        }
    }
}
