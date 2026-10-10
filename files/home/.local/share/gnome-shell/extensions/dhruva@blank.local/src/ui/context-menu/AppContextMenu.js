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


import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import Clutter from 'gi://Clutter';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import PeekManager from '../../core/PeekManager.js';
import { setBoxVertical } from '../../core/Utils.js';
import { applyThemeStyle } from './ContextMenuStyle.js';
import { TimeoutTracker } from '../../core/TimeoutTracker.js';
import { attachTrashActions } from './TrashActionsHandler.js';
import { createThumbnailScroll } from './WindowThumbnailBuilder.js';
import { resetMagnification } from '../magnifier/MagnifierReset.js';
import { setMagnifierPauseState } from '../magnifier/MagnifierState.js';
import { applyRealtimeFrame } from '../magnifier/MagnifierFrameEngine.js';
import { createIconMenuItem, createMenuItem, addSeparator } from './ContextMenuItems.js';


const DEFAULT_PANEL_WIDTH = 280;
const POS_TRACKER_INTERVAL_MS = 16;
const IGNORE_EXPIRY_MS = 2000;

export default class AppContextMenu {
    constructor(dockUI, app, buttonActor, isCtrlPressed = false, openPrefsCallback = null, disablePeek = false) {
        this.dockUI = dockUI;
        this.appManager = dockUI.appManager;
        this.app = app;
        this.buttonActor = buttonActor;

        if (this.buttonActor) {
            this.buttonActor.connectObject('destroy', () => { this.buttonActor = null; }, this);
        }

        this.isCtrlPressed = isCtrlPressed;
        this.openPrefsCallback = openPrefsCallback;
        this.timers = new TimeoutTracker();

        this._isHiding = false;
        this._dynamicPanelWidth = DEFAULT_PANEL_WIDTH;
        this._previousFocus = global.stage.get_key_focus();

        this.actor = new St.Widget({
            style_class: 'context-menu-overlay',
            reactive: true,
            x_expand: true,
            y_expand: true
        });
        global.stage.set_key_focus(null);

        this.actor.connectObject(
            'button-release-event', () => { this.hide(); return Clutter.EVENT_STOP; },
            'touch-event', (_a, event) => {
                if (event.type() === Clutter.EventType.TOUCH_END) this.hide();
                return Clutter.EVENT_STOP;
            },
            'destroy', () => this._cleanup(),
            this
        );

        if (!disablePeek) this.peekManager = new PeekManager(this.dockUI, this.actor);

        this.menuContainer = new St.Widget({
            layout_manager: new Clutter.BinLayout(),
            reactive: true,
            style: 'background-color: transparent;'
        });
        this.bgDrawingArea = new St.DrawingArea({ x_expand: true, y_expand: true, style: 'background-color: transparent;' });
        this.menuContainer.add_child(this.bgDrawingArea);

        this.panel = new St.BoxLayout({
            reactive: true,
            style_class: 'context-menu-panel',
            style: 'background-color: #303035; border: none; box-shadow: none;'
        });
        setBoxVertical(this.panel, true);

        this.panel.connectObject(
            'button-release-event', () => Clutter.EVENT_STOP,
            'touch-event', () => Clutter.EVENT_STOP,
            this
        );

        this.menuContainer.add_child(this.panel);
        applyThemeStyle(this, this.panel);
        this._buildMenu();
        this.actor.add_child(this.menuContainer);
    }

    _cleanup() {
        this.timers.destroy();

        if (this.dockUI && this.dockUI.actor && setMagnifierPauseState) {
            setMagnifierPauseState(this.dockUI.actor, 'context-menu', false);
        }
        if (this.dockUI && this.dockUI._activeContextMenu === this) {
            this.dockUI._activeContextMenu = null;
        }
        if (this.peekManager) {
            this.peekManager.destroy();
            this.peekManager = null;
        }

        this.actor.disconnectObject(this);
        this.panel.disconnectObject(this);
        if (this.buttonActor) this.buttonActor.disconnectObject(this);
    }

    _buildMenu() {
        if (!this.app && this.buttonActor && this.buttonActor._isFolder) {
            const fData = this.buttonActor._folderData;
            const titleBox = new St.BoxLayout({
                x_align: Clutter.ActorAlign.CENTER,
                y_align: Clutter.ActorAlign.CENTER,
                style_class: 'context-menu-header-box'
            });
            setBoxVertical(titleBox, false);
            titleBox.add_child(new St.Label({ text: fData.name, style_class: 'context-menu-header-title' }));
            this.panel.add_child(titleBox);
            addSeparator(this.panel);

            this.panel.add_child(createIconMenuItem('Unpack Stack', () => {
                fData.apps.forEach(appId => this.dockUI.appManager.favManager.addFavorite(appId));
                this.dockUI.folderManager.deleteFolder(fData.id);
                this.dockUI.queueRender();
                this.hide();
            }, false, this));

            this.panel.add_child(createIconMenuItem('Close All Apps', () => {
                fData.apps.forEach(appId => {
                    const a = this.dockUI.appManager.appSystem.lookup_app(appId);
                    if (a) a.request_quit();
                });
                this.hide();
            }, false, this));

            addSeparator(this.panel);
            this.panel.add_child(createIconMenuItem(`Delete ${fData.name}`, () => {
                this.dockUI.folderManager.deleteFolder(fData.id);
                this.dockUI.queueRender();
                this.hide();
            }, true, this));
            return;
        }

        if (!this.app) return;

        // Simplified per-app menu (2026-09-28, matching Debian parity fix):
        // just New Window, Pin/Unpin, Quit. Removed: app-name header,
        // window-thumbnail scroll, "Add to <Folder>" options, is_module
        // "Open X" item, custom .desktop actions, "Remove from <Stack>",
        // and the Recycle Bin module's attachTrashActions() special-case
        // (its context menu now just shows whichever of the 3 standard
        // items apply - same side effect Debian's fix has).
        const windows = this.app.get_windows();

        const appInfo = this.app.get_app_info ? this.app.get_app_info() : null;
        let hasNewWindow = false;
        const quietContext = new Gio.AppLaunchContext();

        if (this.app.can_open_new_window && this.app.can_open_new_window()) {
            this.panel.add_child(createMenuItem('New Window', () => {
                if (appInfo) appInfo.launch([], quietContext);
                else this.app.open_new_window(-1);
                this.hide();
            }, false, this));
            hasNewWindow = true;
        }

        if (hasNewWindow) addSeparator(this.panel);

        if (!this.app.is_module && this.app.get_id && (!this.buttonActor || !this.buttonActor._inFolder)) {
            const isPinned = this.appManager.hasApp(this.app);
            this.panel.add_child(createMenuItem(isPinned ? 'Unpin from Dhruva' : 'Pin to Dhruva', () => {
                if (isPinned) this.appManager.removeApp(this.app);
                else this.appManager.addApp(this.app);
                this.dockUI._renderDock();
                this.hide();
            }, false, this));
        }

        if (this.app.get_state() === Shell.AppState.RUNNING) {
            addSeparator(this.panel);
            this.panel.add_child(createMenuItem(windows.length > 1 ? 'Close All Windows' : (this.app.is_module ? 'Close Folder' : 'Quit'), () => {
                this._addAppToIgnoreList(this.app);
                if (this.app.request_quit) this.app.request_quit();
                if (this.dockUI.actor) this.dockUI.actor._lastIconClickTime = 0;
                this.dockUI._renderDock();
                this.hide();
            }, true, this));
        }

        const isAppGrid = (this.app.get_id ? this.app.get_id() : '') === 'dhruva-grid-button';
        const shouldShowSettings = (this.isCtrlPressed || isAppGrid) && Boolean(this.openPrefsCallback);

        if (shouldShowSettings) {
            if (!isAppGrid) addSeparator(this.panel);
            this.panel.add_child(createMenuItem('Dhruva Settings', () => {
                this.hide();
                const res = this.openPrefsCallback();
                if (res instanceof Promise) res.catch(e => console.warn('[Dhruva]', e.message));
            }, false, this));
        }
    }

    _addAppToIgnoreList(app) {
        if (!this.dockUI || !app.get_id) return;
        const appId = app.get_id();
        if (!this.dockUI._ignoringApps) this.dockUI._ignoringApps = new Set();
        this.dockUI._ignoringApps.add(appId);

        this.timers.addTimeout(GLib.PRIORITY_DEFAULT, IGNORE_EXPIRY_MS, () => {
            if (this.dockUI && this.dockUI._ignoringApps) this.dockUI._ignoringApps.delete(appId);
            return GLib.SOURCE_REMOVE;
        });
    }

    _updatePosition() {
        if (this._isHiding || !this.actor || !this.menuContainer) return;

        if (!this.buttonActor || !this.buttonActor.get_parent()) {
            if (this.dockUI && this.dockUI.boxActor && this.app) {
                const newBtn = this.dockUI.boxActor.get_children().find(c => c._delegate && c._delegate.app && c._delegate.app.get_id() === this.app.get_id());
                if (newBtn) {
                    if (this.buttonActor) this.buttonActor.disconnectObject(this);
                    this.buttonActor = newBtn;
                    this.buttonActor.connectObject('destroy', () => { this.buttonActor = null; }, this);
                } else {
                    this.hide();
                    return;
                }
            } else {
                this.hide();
                return;
            }
        }

        const [btnX, btnY] = this.buttonActor.get_transformed_position();
        const [btnW, btnH] = this.buttonActor.get_transformed_size();
        if (Number.isNaN(btnX) || Number.isNaN(btnY) || btnW <= 0 || (btnX === 0 && btnY === 0 && !this.buttonActor.get_parent())) return;

        let [, panelW] = this.menuContainer.get_preferred_width(-1);
        let [, panelH] = this.menuContainer.get_preferred_height(-1);

        const { monitor } = this.dockUI.monitorManager.getCurrentMonitor();
        const maxPanelHeight = monitor.height * 0.85;
        if (panelH > maxPanelHeight) panelH = maxPanelHeight;

        const stateStr = `${btnX},${btnY},${btnW},${panelW},${panelH}`;
        if (this._lastStateStr === stateStr) return;
        this._lastStateStr = stateStr;

        const isInsideFolder = this.buttonActor && this.buttonActor._inFolder;
        const isAppGrid = !this.peekManager && !isInsideFolder;
        const gap = isInsideFolder ? -8 : (isAppGrid ? -8 : 22);

        let posX = btnX + (btnW / 2) - (panelW / 2);
        let posY = btnY;
        const dockPos = this._dockPos;

        if (dockPos === 'BOTTOM') {
            posY = btnY - panelH - gap;
            this.menuContainer.set_pivot_point(0.5, 1.0);
        } else if (dockPos === 'TOP') {
            posY = btnY + btnH + gap;
            this.menuContainer.set_pivot_point(0.5, 0.0);
        } else if (dockPos === 'LEFT') {
            posX = btnX + btnW + gap;
            posY = btnY + (btnH / 2) - (panelH / 2);
            this.menuContainer.set_pivot_point(0.0, 0.5);
        } else if (dockPos === 'RIGHT') {
            posX = btnX - panelW - gap;
            posY = btnY + (btnH / 2) - (panelH / 2);
            this.menuContainer.set_pivot_point(1.0, 0.5);
        }

        if (posX < monitor.x + gap) posX = monitor.x + gap;
        if (posX + panelW > monitor.x + monitor.width - gap) posX = monitor.x + monitor.width - panelW - gap;
        if (dockPos !== 'BOTTOM' && posY + panelH > monitor.y + monitor.height - gap) posY = monitor.y + monitor.height - panelH - gap;

        posX = Math.round(posX);
        posY = Math.round(posY);

        if (dockPos === 'BOTTOM' || dockPos === 'TOP') this.bgDrawingArea._arrowCenter = Math.round((btnX + btnW / 2) - posX);
        else this.bgDrawingArea._arrowCenter = Math.round((btnY + btnH / 2) - posY);
        this.bgDrawingArea.queue_repaint();

        this.panel.ease({ width: panelW, duration: 100, mode: Clutter.AnimationMode.EASE_OUT_QUAD });

        if (this._isFirstPosition !== false) {
            this.menuContainer.set_position(posX, posY);
            this._isFirstPosition = false;
        } else {
            this.menuContainer.ease({ x: posX, y: posY, height: panelH, duration: 100, mode: Clutter.AnimationMode.EASE_OUT_QUAD });
        }
    }

    show(dockPosition) {
        this._dockPos = dockPosition;
        this._isFirstPosition = true;

        if (this.dockUI && this.dockUI.actor && setMagnifierPauseState) {
            setMagnifierPauseState(this.dockUI.actor, 'context-menu', true);
        }

        this.timers.remove(this._showDelayId);

        const setupUI = () => {
            this._showDelayId = null;
            if (this._isHiding || !this.actor) return GLib.SOURCE_REMOVE;

            if (this.dockUI && this.dockUI._activeContextMenu && this.dockUI._activeContextMenu !== this) {
                this.dockUI._activeContextMenu.actor.destroy();
            }
            this.dockUI._activeContextMenu = this;

            Main.layoutManager.addChrome(this.actor, { affectsStruts: false });
            global.stage.set_key_focus(this.actor);
            this.actor.grab_key_focus();

            if (this.dockUI && this.dockUI.actor) {
                const parent = this.actor.get_parent();
                if (!this.peekManager) {
                    if (parent) parent.set_child_above_sibling(this.actor, null);
                } else {
                    const sibling = this.dockUI.actor;
                    const siblingParent = sibling && sibling.get_parent ? sibling.get_parent() : null;
                    if (parent && sibling && parent === siblingParent) parent.set_child_below_sibling(this.actor, sibling);
                }
            }

            this.actor.set_position(0, 0);
            this.actor.set_size(global.stage.width, global.stage.height);

            const ah = 12;
            let padBottom = 12, padTop = 12, padLeft = 12, padRight = 12;
            if (dockPosition === 'BOTTOM') padBottom += ah;
            else if (dockPosition === 'TOP') padTop += ah;
            else if (dockPosition === 'LEFT') padLeft += ah;
            else if (dockPosition === 'RIGHT') padRight += ah;

            this.panel.set_style(`background-color: #303035; border: none; box-shadow: none; padding: ${padTop}px ${padRight}px ${padBottom}px ${padLeft}px;`);
            this.menuContainer.opacity = 0;
            this._updatePosition();

            this.menuContainer.ease({ opacity: 255, duration: 180, mode: Clutter.AnimationMode.EASE_OUT_QUAD });

            this.timers.remove(this._posTrackerId);
            this._posTrackerId = this.timers.addTimeout(GLib.PRIORITY_DEFAULT, POS_TRACKER_INTERVAL_MS, () => {
                if (this._isHiding || !this.actor) {
                    this._posTrackerId = null;
                    return GLib.SOURCE_REMOVE;
                }
                this._updatePosition();
                return GLib.SOURCE_CONTINUE;
            });

            return GLib.SOURCE_REMOVE;
        };

        this._showDelayId = this.timers.addTimeout(GLib.PRIORITY_DEFAULT, 150, setupUI);
    }

    hide() {
        if (this._isHiding) return;
        this._isHiding = true;

        this.timers.remove(this._showDelayId);
        this._showDelayId = null;

        this.timers.remove(this._posTrackerId);
        this._posTrackerId = null;

        if (this.dockUI && this.dockUI.actor && setMagnifierPauseState) {
            setMagnifierPauseState(this.dockUI.actor, 'context-menu', false);
        }
        if (this.dockUI && this.dockUI._activeContextMenu === this) {
            this.dockUI._activeContextMenu = null;
        }
        if (this.peekManager) this.peekManager.stopPeek();

        if (this.dockUI && this.dockUI.actor) {
            const [px, py] = global.get_pointer();
            const [dx, dy] = this.dockUI.actor.get_transformed_position();
            const [dw, dh] = this.dockUI.actor.get_transformed_size();
            const pad = 15;
            const isInside = px >= dx - pad && px <= dx + dw + pad && py >= dy - pad && py <= dy + dh + pad;

            if (!isInside) {
                resetMagnification(this.dockUI.actor);
            } else {
                const isVertical = this.dockUI.dockPosition === 'LEFT' || this.dockUI.dockPosition === 'RIGHT';
                applyRealtimeFrame(this.dockUI.actor, px, py, isVertical, this.dockUI.settings, Date.now());
            }
        }

        if (this.menuContainer) {
            this.menuContainer.ease({
                opacity: 0,
                scale_x: 0.95,
                scale_y: 0.95,
                duration: 120,
                mode: Clutter.AnimationMode.EASE_IN_QUAD,
                onComplete: () => {
                    if (this.actor && this.actor.get_parent()) Main.layoutManager.removeChrome(this.actor);
                    if (global.stage.get_key_focus() === this.actor) global.stage.set_key_focus(this._previousFocus || null);
                    if (this.actor) this.actor.destroy();
                }
            });
        }
    }
}