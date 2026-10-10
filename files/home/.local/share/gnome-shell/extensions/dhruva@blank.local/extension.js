/*
 * Dhruva GNOME Extension
 * Copyright (C) 2026 NarkAgni
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */


import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import GLib from 'gi://GLib';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

import QuickLaunchManager from './src/core/QuickLaunchManager.js';
import MultiMonitorController from './src/core/MultiMonitorController.js';


export default class DhruvaExtension extends Extension {
    enable() {
        this._settings = this.getSettings();

        this._monitorController = new MultiMonitorController(
            this._settings,
            () => this.openPreferences(),
            this.uuid
        );

        Main.layoutManager.connectObject(
            'monitors-changed',
            () => {
                if (this._monitorController) {
                    this._monitorController.reloadDocks();
                }
            },
            this
        );

        this._currentAxis = this._getAxis();

        this._settings.connectObject(
            'changed::dock-position',
            () => {
                const axis = this._getAxis();
                if (this._currentAxis !== axis) {
                    this._currentAxis = axis;
                    if (this._monitorController) {
                        this._monitorController.reloadDocks();
                    }
                }
            },
            this
        );

        this._monitorController.reloadDocks();

        this._quickLaunchManager = new QuickLaunchManager(
            this._settings,
            () => {
                if (this._monitorController) {
                    return this._monitorController.getQuickLaunchDock();
                }
                return null;
            }
        );

        this._debugLog(`enable() reached keybinding setup. accel=${this._settings.get_strv('toggle-visibility-accel')}`);

        let flags = 0;
        const K = Meta.KeyBindingFlags;
        if (K.NON_MASKABLE) flags |= K.NON_MASKABLE;
        const modes = Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW;

        try {
            const bindResult = Main.wm.addKeybinding(
                'toggle-visibility-accel',
                this._settings,
                flags,
                modes,
                () => this._toggleDocksVisible()
            );
            this._debugLog(`addKeybinding returned: ${bindResult}`);
        } catch (e) {
            this._debugLog(`addKeybinding THREW: ${e}`);
        }
    }

    _debugLog(msg) {
        try {
            const path = '/tmp/dhruva-debug.log';
            let prior = '';
            if (GLib.file_test(path, GLib.FileTest.EXISTS)) {
                const [ok, contents] = GLib.file_get_contents(path);
                if (ok) prior = new TextDecoder().decode(contents);
            }
            GLib.file_set_contents(path, `${prior}${new Date().toISOString()} ${msg}\n`);
        } catch (e) { /* ignore */ }
    }

    _toggleDocksVisible() {
        this._debugLog('toggle-visibility-accel fired');
        if (!this._monitorController || !this._monitorController.docks) return;
        for (const dock of this._monitorController.docks) {
            if (dock && dock.actor) {
                dock.actor.visible = !dock.actor.visible;
            }
        }
    }

    disable() {
        Main.layoutManager.disconnectObject(this);

        if (this._settings) {
            this._settings.disconnectObject(this);
        }

        Main.wm.removeKeybinding('toggle-visibility-accel');

        if (this._quickLaunchManager) {
            this._quickLaunchManager.destroy();
            this._quickLaunchManager = null;
        }

        if (this._monitorController) {
            this._monitorController.destroy();
            this._monitorController = null;
        }

        this._currentAxis = null;
        this._settings = null;
    }

    _getAxis() {
        const pos = this._settings ? this._settings.get_string('dock-position') : 'BOTTOM';
        return (pos === 'LEFT' || pos === 'RIGHT') ? 'vertical' : 'horizontal';
    }
}