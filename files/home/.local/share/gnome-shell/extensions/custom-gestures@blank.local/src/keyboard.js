// Minimal virtual-keyboard helper, adapted from touchpad-gesture-customization@coooolapps.com's
// src/utils/keyboard.js (copied rather than imported, so this extension stays independent).
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';

const DELAY_BETWEEN_KEY_PRESS = 10; // ms
const timeoutIds = new Set();

class VirtualKeyboard {

    constructor() {
        const seat = Clutter.get_default_backend().get_default_seat();
        this._virtualDevice = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    }

    sendKeys(keys) {
        const keyEvents = [];
        keys.forEach(key => keyEvents.push([key, Clutter.KeyState.RELEASED]));
        keys.slice().reverse().forEach(key => keyEvents.push([key, Clutter.KeyState.PRESSED]));
        let timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, DELAY_BETWEEN_KEY_PRESS, () => {
            const keyEvent = keyEvents.pop();
            if (keyEvent !== undefined)
                this._sendKey(...keyEvent);

            if (keyEvents.length === 0) {
                timeoutIds.delete(timeoutId);
                timeoutId = 0;
                return GLib.SOURCE_REMOVE;
            }

            return GLib.SOURCE_CONTINUE;
        });
        if (timeoutId)
            timeoutIds.add(timeoutId);
    }

    _sendKey(keyval, keyState) {
        this._virtualDevice.notify_keyval(Clutter.get_current_event_time() * 1000, keyval, keyState);
    }

}

let _keyboard;

export function sendKeys(keys) {
    _keyboard = _keyboard ?? new VirtualKeyboard();
    _keyboard.sendKeys(keys);
}

export function cleanup() {
    timeoutIds.forEach(id => GLib.Source.remove(id));
    timeoutIds.clear();
    _keyboard = undefined;
}
