/*
 * Knomadic Top Bar helpers - a trimmed subset of Dash to Panel's utils.js (GPL-2.0-or-later, see that project).
 * Kept: signal/timeout handlers, display helpers, chrome tracking, keybinding helpers, animation helpers.
 */

import Clutter from 'gi://Clutter'
import GLib from 'gi://GLib'
import Meta from 'gi://Meta'
import Shell from 'gi://Shell'
import St from 'gi://St'
import * as Config from 'resource:///org/gnome/shell/misc/config.js'
import * as Main from 'resource:///org/gnome/shell/ui/main.js'

export const BasicHandler = class {
  constructor() {
    this._storage = new Object()
  }

  add(/*unlimited 3-long array arguments*/) {
    // convert arguments object to array, concatenate with generic
    let args = [].concat('generic', [].slice.call(arguments))
    // call addWithLabel with ags as if they were passed arguments
    this.addWithLabel.apply(this, args)
  }

  destroy() {
    for (let label in this._storage) this.removeWithLabel(label)
  }

  addWithLabel(label /* plus unlimited 3-long array arguments*/) {
    if (this._storage[label] == undefined) this._storage[label] = new Array()

    // skip first element of the arguments
    for (let i = 1; i < arguments.length; i++) {
      let item = this._storage[label]
      let handlers = this._create(arguments[i])

      for (let j = 0, l = handlers.length; j < l; ++j) {
        item.push(handlers[j])
      }
    }
  }

  removeWithLabel(label) {
    if (this._storage[label]) {
      for (let i = 0; i < this._storage[label].length; i++) {
        this._remove(this._storage[label][i])
      }

      delete this._storage[label]
    }
  }

  hasLabel(label) {
    return !!this._storage[label]
  }

  /* Virtual methods to be implemented by subclass */
  // create single element to be stored in the storage structure
  _create() {
    throw new Error('no implementation of _create in ' + this)
  }

  // correctly delete single element
  _remove() {
    throw new Error('no implementation of _remove in ' + this)
  }
}

// Manage global signals
export const GlobalSignalsHandler = class extends BasicHandler {
  _create(item) {
    let handlers = []

    item[1] = [].concat(item[1])

    for (let i = 0, l = item[1].length; i < l; ++i) {
      let object = item[0]
      let event = item[1][i]
      let callback = item[2]
      try {
        let id = object.connect(event, callback)

        handlers.push([object, id])
      } catch (e) {
        console.log(e)
      }
    }

    return handlers
  }

  _remove(item) {
    item[0].disconnect(item[1])
  }
}

/**
 * Manage function injection: both instances and prototype can be overridden
 * and restored
 */

export const TimeoutsHandler = class extends BasicHandler {
  _create(item) {
    let name = item[0]
    let delay = item[1]
    let timeoutHandler = item[2]

    this._remove(item)

    this[name] = GLib.timeout_add(GLib.PRIORITY_DEFAULT, delay, () => {
      this[name] = 0
      timeoutHandler()

      return GLib.SOURCE_REMOVE
    })

    return [[name]]
  }

  remove(name) {
    this._remove([name])
  }

  _remove(item) {
    let name = item[0]

    if (this[name]) {
      GLib.Source.remove(this[name])
      this[name] = 0
    }
  }

  getId(name) {
    return this[name] ? this[name] : 0
  }
}


export const DisplayWrapper = {
  getScreen() {
    return global.screen || global.display
  },

  getWorkspaceManager() {
    return global.screen || global.workspace_manager
  },

  getMonitorManager() {
    return global.screen || global.backend.get_monitor_manager()
  },
}

let unredirectEnabled = true
export const setDisplayUnredirect = (enable) => {
  let gsVersion = Config.PACKAGE_VERSION

  if (gsVersion < '50' && !Meta.is_wayland_compositor()) return

  let v48 = gsVersion >= '48'

  if (enable && !unredirectEnabled)
    v48
      ? global.compositor.enable_unredirect()
      : Meta.enable_unredirect_for_display(global.display)
  else if (!enable && unredirectEnabled)
    v48
      ? global.compositor.disable_unredirect()
      : Meta.disable_unredirect_for_display(global.display)

  unredirectEnabled = enable
}


export const getCurrentWorkspace = function () {
  return DisplayWrapper.getWorkspaceManager().get_active_workspace()
}


export const getStageTheme = function () {
  return St.ThemeContext.get_for_stage(global.stage)
}

export const getScaleFactor = function () {
  return getStageTheme().scale_factor || 1
}


export const addChrome = (actor, params) => {
  Main.layoutManager.addChrome(actor, getChromeParams(params))
}

export const trackChrome = (actor, params) => {
  Main.layoutManager.trackChrome(actor, getChromeParams(params))
}

function getChromeParams(params) {
  if (Config.PACKAGE_VERSION >= '50') delete params.affectsInputRegion

  return params
}

export const getTrackedActorData = (actor) => {
  let trackedIndex = Main.layoutManager._findActor(actor)

  if (trackedIndex >= 0) return Main.layoutManager._trackedActors[trackedIndex]
}


export const addKeybinding = function (key, settings, handler, modes) {
  if (!Main.wm._allowedKeybindings[key]) {
    Main.wm.addKeybinding(
      key,
      settings,
      Meta.KeyBindingFlags.NONE,
      modes || Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
      handler,
    )
  }
}

export const removeKeybinding = function (key) {
  if (Main.wm._allowedKeybindings[key]) {
    Main.wm.removeKeybinding(key)
  }
}


// "#rrggbb" / "rgb(r,g,b)" / "rgba(...)" -> {red, green, blue} (0-255)
export const getrgbColor = function (color) {
  if (typeof color !== 'string') return { red: color.red, green: color.green, blue: color.blue }
  let m = color.trim().match(/^#?([0-9a-f]{6})$/i)
  if (m) {
    let n = parseInt(m[1], 16)
    return { red: (n >> 16) & 255, green: (n >> 8) & 255, blue: n & 255 }
  }
  m = color.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i)
  if (m) return { red: +m[1], green: +m[2], blue: +m[3] }
  return { red: 0, green: 0, blue: 0 }
}

// css rgba() string (no trailing semicolon)
export const getrgbaColor = function (color, alpha) {
  if (alpha <= 0) return 'transparent'
  let rgb = getrgbColor(color)
  return 'rgba(' + rgb.red + ',' + rgb.green + ',' + rgb.blue + ',' + Math.round(Math.min(1, alpha) * 100) / 100 + ')'
}

export const animate = function (actor, options) {
  //the original animations used Tweener instead of Clutter animations, so we
  //use "time" and "delay" properties defined in seconds, as opposed to Clutter
  //animations "duration" and "delay" which are defined in milliseconds
  if (options.delay) {
    options.delay = options.delay * 1000
  }

  options.duration = options.time * 1000
  delete options.time

  if (options.transition) {
    //map Tweener easing equations to Clutter animation modes
    options.mode =
      {
        easeInCubic: Clutter.AnimationMode.EASE_IN_CUBIC,
        easeInOutCubic: Clutter.AnimationMode.EASE_IN_OUT_CUBIC,
        easeInOutQuad: Clutter.AnimationMode.EASE_IN_OUT_QUAD,
        easeOutQuad: Clutter.AnimationMode.EASE_OUT_QUAD,
      }[options.transition] || Clutter.AnimationMode.LINEAR

    delete options.transition
  }

  let params = [options]

  if ('value' in options && actor instanceof St.Adjustment) {
    params.unshift(options.value)
    delete options.value
  }

  actor.ease.apply(actor, params)
}

export const stopAnimations = function (actor) {
  actor.remove_all_transitions()
}

