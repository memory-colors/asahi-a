// Discrete touchpad pinch detector. Claims matching finger-count pinch gestures on BEGIN
// so GNOME's own handlers never start. Direction dispatched once scale crosses threshold.
import Clutter from 'gi://Clutter';

const PINCH_IN_THRESHOLD = 0.7;
const PINCH_OUT_THRESHOLD = 1.4;

export class DiscretePinchGesture {

    // onPinch(direction): direction is 'in' | 'out'
    constructor(nfingers, onPinch) {
        this._nfingers = new Set(nfingers);
        this._onPinch = onPinch;
        this._state = 'idle'; // idle | accumulating | dispatched
        this._handlerId = global.stage.connect('captured-event::touchpad', this._onEvent.bind(this));
    }

    _onEvent(_actor, event) {
        if (event.type() !== Clutter.EventType.TOUCHPAD_PINCH)
            return Clutter.EVENT_PROPAGATE;

        const phase = event.get_gesture_phase();

        if (phase === Clutter.TouchpadGesturePhase.BEGIN) {
            if (this._nfingers.has(event.get_touchpad_gesture_finger_count())) {
                this._state = 'accumulating';
                return Clutter.EVENT_STOP;
            }
            this._state = 'idle';
            return Clutter.EVENT_PROPAGATE;
        }

        if (this._state === 'idle')
            return Clutter.EVENT_PROPAGATE;

        if (phase === Clutter.TouchpadGesturePhase.UPDATE) {
            if (this._state === 'dispatched')
                return Clutter.EVENT_STOP;

            const scale = event.get_gesture_pinch_scale();
            if (scale > PINCH_IN_THRESHOLD && scale < PINCH_OUT_THRESHOLD)
                return Clutter.EVENT_STOP;

            this._onPinch(scale <= PINCH_IN_THRESHOLD ? 'in' : 'out');
            this._state = 'dispatched';
            return Clutter.EVENT_STOP;
        }

        if (phase === Clutter.TouchpadGesturePhase.END ||
            phase === Clutter.TouchpadGesturePhase.CANCEL) {
            this._state = 'idle';
            return Clutter.EVENT_STOP;
        }

        return Clutter.EVENT_STOP;
    }

    destroy() {
        if (this._handlerId) {
            global.stage.disconnect(this._handlerId);
            this._handlerId = 0;
        }
    }

}
