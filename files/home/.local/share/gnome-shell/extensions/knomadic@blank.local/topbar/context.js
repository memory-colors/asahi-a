/*
 * Knomadic Top Bar - shared settings context for the ported Dash to Panel modules.
 * The ported code reads keys like 'intellihide-use-pointer'; PrefixedSettings maps them to Knomadic's
 * 'topbar-intellihide-use-pointer' keys, so the intellihide logic stays close to the original.
 */
import Gio from 'gi://Gio'

const PREFIX = 'topbar-'

class PrefixedSettings {
  constructor(settings) {
    this._s = settings
  }

  get_boolean(k) { return this._s.get_boolean(PREFIX + k) }
  get_int(k) { return this._s.get_int(PREFIX + k) }
  get_double(k) { return this._s.get_double(PREFIX + k) }
  get_string(k) { return this._s.get_string(PREFIX + k) }
  set_int(k, v) { return this._s.set_int(PREFIX + k, v) }

  connect(signal, cb) {
    return this._s.connect(signal.replace(/^changed::/, 'changed::' + PREFIX), cb)
  }

  disconnect(id) { this._s.disconnect(id) }
}

export let SETTINGS = null
export let NOTIFICATIONSSETTINGS = null

export function initContext(settings) {
  SETTINGS = new PrefixedSettings(settings)
  NOTIFICATIONSSETTINGS = new Gio.Settings({ schema_id: 'org.gnome.desktop.notifications' })
}

export function destroyContext() {
  SETTINGS = null
  NOTIFICATIONSSETTINGS = null
}
