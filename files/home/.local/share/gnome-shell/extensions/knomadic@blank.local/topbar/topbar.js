/*
 * Knomadic Top Bar - the parts of Dash to Panel this setup actually used, rebuilt around GNOME's stock top panel:
 *   - Activities button hidden, date menu centered, quick settings right (the stock panel already lays these out)
 *   - thickness, background color + opacity, tray font/icon size
 *   - intellihide (ported from Dash to Panel: intellihide.js + proximity.js) and its toggle shortcut
 *   - click empty space to close the Overview, don't open the Overview at login
 *   - date-menu indicator pad removed (clock stays centered), notification banners pushed below a visible bar
 * Everything Dash to Panel did for taskbars, app icons, previews, multi-monitor and vertical panels is intentionally gone.
 * Ported code is GPL-2.0-or-later (Dash to Panel, see that project's COPYING).
 */
import Clutter from 'gi://Clutter'
import GLib from 'gi://GLib'
import Shell from 'gi://Shell'
import St from 'gi://St'

import * as Main from 'resource:///org/gnome/shell/ui/main.js'
import { WindowPreview } from 'resource:///org/gnome/shell/ui/windowPreview.js'
import { ExtensionState } from 'resource:///org/gnome/shell/misc/extensionUtils.js'

import * as Intellihide from './intellihide.js'
import * as Proximity from './proximity.js'
import * as Utils from './utils.js'
import { initContext, destroyContext } from './context.js'

const D2P_UUID = 'dash-to-panel@blank.local'
const KEY_TOGGLE = 'topbar-intellihide-key-toggle'

export class TopBar {
  constructor(settings) {
    this._settings = settings
    this._signals = new Utils.GlobalSignalsHandler()
    this._running = false
  }

  // true when it is safe to start (Dash to Panel must not also be driving the panel)
  static canStart() {
    const d2p = Main.extensionManager?.lookup(D2P_UUID)
    return !d2p || (d2p.state !== ExtensionState.ACTIVE && d2p.state !== ExtensionState.ACTIVATING)
  }

  enable() {
    if (this._running) return
    this._running = true
    initContext(this._settings)

    this._startupOverviewTweak()

    const monitor = Main.layoutManager.primaryMonitor
    const settings = this._settings
    this.host = {
      panelBox: Main.layoutManager.panelBox,
      panel: Main.panel,
      statusArea: Main.panel.statusArea,
      monitor,
      isPrimary: true,
      proximityManager: new Proximity.ProximityManager(),
      geom: {
        vertical: false,
        position: St.Side.TOP,
        dockMode: false,
        dynamic: 0,
        topOffset: 0,
        gsTopPanelHeight: 0,
        // laid-out height of the bar; before the first layout fall back to the configured thickness
        get outerSize() {
          const h = Main.layoutManager.panelBox.height
          return h > 1 ? h : settings.get_int('topbar-size') * Utils.getScaleFactor()
        },
      },
    }

    this._hideActivities()
    this._dateMenuTweaks()

    // GNOME's overview code resets Main.panel.style (transition-duration / null); that would wipe our inline style
    Object.defineProperty(Main.panel, 'style', { configurable: true, set() {} })
    this._applyStyle()

    this.intellihide = new Intellihide.Intellihide(this.host)
    this.intellihide.init()
    this.host.intellihide = this.intellihide

    Utils.removeKeybinding(KEY_TOGGLE)
    Utils.addKeybinding(KEY_TOGGLE, this._settings, () => this.intellihide.toggle(), Shell.ActionMode.NORMAL)

    this._bannerOffset()
    this._enableClickToExit()

    const styleKeys = ['topbar-color', 'topbar-opacity', 'topbar-size', 'topbar-tray-size'].map(k => 'changed::' + k)
    this._signals.add(
      [this._settings, styleKeys, () => this._applyStyle()],
      [Main.layoutManager, 'monitors-changed', () => {
        this.host.monitor = Main.layoutManager.primaryMonitor
        if (this.intellihide?.enabled) this.intellihide.reset()
      }],
      [Utils.getStageTheme(), 'changed', () => this._applyStyle()],
    )
  }

  disable() {
    if (!this._running) return
    this._running = false

    this._signals.destroy()
    this._signals = new Utils.GlobalSignalsHandler()

    Utils.removeKeybinding(KEY_TOGGLE)
    this.intellihide?.destroy()
    this.intellihide = null
    this.host?.proximityManager.destroy()

    delete Main.messageTray._bannerBin.ease
    this._disableClickToExit()

    this._clearTray()
    delete Main.panel.style
    Main.panel.set_style(null)

    this._restoreActivities()
    this._restoreDateMenu()
    this._startupCleanup()
    destroyContext()
    this.host = null
  }

  // ── Overview: don't open at login (GNOME 50 loads extensions late; logic carried over from Dash to Panel) ──
  _startupOverviewTweak() {
    this._realHasOverview = Main.sessionMode.hasOverview
    Main.layoutManager.startInOverview = false
    Main.sessionMode.hasOverview = false

    const restore = () => {
      Main.sessionMode.hasOverview = this._realHasOverview
      if (Main.overview.visible || Main.overview._shown) Main.overview.hide()
    }
    if (Main.layoutManager._startingUp) {
      this._startupCompleteId = Main.layoutManager.connect('startup-complete', restore)
    } else {
      restore()
    }
  }

  _startupCleanup() {
    if (this._startupCompleteId) {
      Main.layoutManager.disconnect(this._startupCompleteId)
      this._startupCompleteId = 0
      Main.sessionMode.hasOverview = this._realHasOverview
    }
  }

  // ── Activities button ──
  _hideActivities() {
    const container = Main.panel.statusArea.activities?.container
    if (!container) return
    this._activities = container
    container.hide()
    this._activitiesVisId = container.connect('notify::visible', () => {
      if (container.visible) container.hide()
    })
  }

  _restoreActivities() {
    if (!this._activities) return
    this._activities.disconnect(this._activitiesVisId)
    this._activities.show()
    this._activities = null
  }

  // ── date menu: drop the size constraint on the indicator pad so the clock stays centered ──
  // (GNOME 50 has no DateMenu.IndicatorPad class; the pad is an anonymous child with constraints - same trick Dash to Panel used)
  _dateMenuTweaks() {
    const dm = Main.panel.statusArea.dateMenu
    const pad = dm?.get_first_child()?.get_first_child()
    if (!pad) return
    this._padActor = pad
    this._padConstraints = pad.get_constraints()
    pad.clear_constraints()
  }

  _restoreDateMenu() {
    if (!this._padActor) return
    this._padConstraints.forEach(c => this._padActor.add_constraint(c))
    this._padActor = null
    this._padConstraints = null
  }

  // ── thickness, color, opacity, tray size ──
  _applyStyle() {
    const s = this._settings
    const scale = Utils.getScaleFactor()
    const size = s.get_int('topbar-size')
    const bg = Utils.getrgbaColor(s.get_string('topbar-color'), s.get_double('topbar-opacity'))
    Main.panel.set_style(`height: ${size}px; background-color: ${bg};`)
    void scale
    if (this._lastSize !== size) {
      this._lastSize = size
      // the intellihide watch rectangle depends on the bar height; rebuild it once the new height is laid out
      if (this.intellihide?.enabled)
        GLib.idle_add(GLib.PRIORITY_LOW, () => {
          this.intellihide?.enabled && this.intellihide.reset()
          return GLib.SOURCE_REMOVE
        })
    }

    this._applyTray(s.get_int('topbar-tray-size'))
    Main.layoutManager._queueUpdateRegions()
  }

  _applyTray(size) {
    this._clearTray()
    if (size <= 0) return
    this._trayBoxes = [Main.panel._centerBox, Main.panel._rightBox]
    this._trayIds = []
    this._trayBoxes.forEach(box => {
      this._styleSubtree(box, size)
      this._trayIds.push(box.connect('child-added', () => this._queueTray(size)))
    })
  }

  _queueTray(size) {
    if (this._trayIdle) return
    this._trayIdle = GLib.idle_add(GLib.PRIORITY_LOW, () => {
      this._trayIdle = 0
      this._trayBoxes?.forEach(box => this._styleSubtree(box, size))
      return GLib.SOURCE_REMOVE
    })
  }

  _styleSubtree(actor, size) {
    const isBox = actor === Main.panel._centerBox || actor === Main.panel._rightBox
    let style = null
    if (isBox || actor instanceof St.Label) style = `font-size: ${size}px;`
    else if (actor instanceof St.Icon) style = `icon-size: ${size}px;`
    if (style && actor.get_style() !== style) {
      if (actor._knOrigStyle === undefined) actor._knOrigStyle = actor.get_style() ?? ''
      actor.set_style(style + actor._knOrigStyle)
    }
    actor.get_children().forEach(c => this._styleSubtree(c, size))
  }

  _clearTray() {
    if (this._trayIdle) {
      GLib.source_remove(this._trayIdle)
      this._trayIdle = 0
    }
    this._trayBoxes?.forEach((box, i) => {
      box.disconnect(this._trayIds[i])
      const restore = a => {
        if (a._knOrigStyle !== undefined) {
          a.set_style(a._knOrigStyle || null)
          delete a._knOrigStyle
        }
        a.get_children().forEach(restore)
      }
      restore(box)
    })
    this._trayBoxes = null
    this._trayIds = null
  }

  // ── notification banners sit below the bar while it is revealed (struts are off with intellihide) ──
  _bannerOffset() {
    const bin = Main.messageTray._bannerBin
    bin.ease = params => {
      if (params.y === 0 && this.intellihide?.enabled && Main.layoutManager.panelBox.visible)
        params.y += Main.layoutManager.panelBox.height
      Object.getPrototypeOf(bin).ease.call(bin, params)
    }
  }

  // ── click empty space in the Overview to close it ──
  _enableClickToExit() {
    this._clickId = Main.layoutManager.overviewGroup.connect('button-release-event', () => {
      const [x, y] = global.get_pointer()
      const picked = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, x, y)
      if (picked) {
        if (
          (picked.has_style_class_name?.('apps-scroll-view') && !picked.has_style_pseudo_class('first-child')) ||
          Main.overview._overview._controls._searchEntryBin.contains(picked) ||
          picked instanceof WindowPreview
        )
          return Clutter.EVENT_PROPAGATE
      }
      Main.overview.toggle()
      return Clutter.EVENT_STOP
    })
  }

  _disableClickToExit() {
    if (this._clickId) {
      Main.layoutManager.overviewGroup.disconnect(this._clickId)
      this._clickId = 0
    }
  }
}
