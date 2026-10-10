// SPDX-FileCopyrightText: 2011 John Stowers <john.stowers@gmail.com>
// SPDX-FileCopyrightText: 2011 Giovanni Campagna <gcampagna@src.gnome.org>
// SPDX-FileCopyrightText: 2011 Elad Alfassa <el.il@doom.co.il>
// SPDX-FileCopyrightText: 2014 Florian Müllner <fmuellner@gnome.org>
//
// SPDX-License-Identifier: GPL-2.0-or-later
//
// "User Themes", merged into Knomadic 2026-10-07 (was user-theme@gnome-shell-extensions.gcampax.github.com).
// Logic is the stock extension's, unchanged except that the theme name lives in Knomadic's 'theme-name' key and
// the class takes the settings object instead of calling getSettings(). util.js is an unmodified copy.

import Gio from 'gi://Gio';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {getThemeDirs, getModeThemeDirs} from './util.js';

const SETTINGS_KEY = 'theme-name';
const OLD_UUID = 'user-theme@gnome-shell-extensions.gcampax.github.com';

export class ThemeManager {
    constructor(settings) {
        this._settings = settings;
    }

    // Don't fight the stock extension: skip while it is still enabled.
    static canStart() {
        return !global.settings.get_strv('enabled-extensions').includes(OLD_UUID);
    }

    enable() {
        this._settings.connectObject(`changed::${SETTINGS_KEY}`,
            this._changeTheme.bind(this), this);
        this._changeTheme();
    }

    disable() {
        this._settings?.disconnectObject(this);

        Main.setThemeStylesheet(null);
        Main.loadTheme();
    }

    _changeTheme() {
        let stylesheet = null;
        const themeName = this._settings.get_string(SETTINGS_KEY);

        if (themeName) {
            const stylesheetPaths = getThemeDirs()
                .map(dir => `${dir}/${themeName}/gnome-shell/gnome-shell.css`);

            stylesheetPaths.push(...getModeThemeDirs()
                .map(dir => `${dir}/${themeName}.css`));

            stylesheet = stylesheetPaths.find(path => {
                const file = Gio.file_new_for_path(path);
                return file.query_exists(null);
            });
        }

        if (stylesheet)
            log(`loading user theme: ${stylesheet}`);
        else
            log('loading default theme (Adwaita)');
        Main.setThemeStylesheet(stylesheet);
        Main.loadTheme();
    }
}
