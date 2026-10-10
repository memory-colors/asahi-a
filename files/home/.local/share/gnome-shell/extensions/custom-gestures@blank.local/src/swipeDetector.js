// Unified touchpad swipe router. Claims 3-finger and 4-finger swipe events on BEGIN
// (returns EVENT_STOP immediately) so GNOME's own built-in overview/workspace-switch
// gesture handlers never see them. Direction is determined once accumulated delta
// crosses THRESHOLD_PX, then dispatched to the appropriate handler.
//
// This replaces the previous per-axis DiscreteSwipeGesture approach, which propagated
// early UPDATE events (before direction was known), letting GNOME's continuous-animation
// handlers start running in the background and making the gesture appear to "pass through"
// to the built-in behaviors.
import Clutter from 'gi://Clutter';

const THRESHOLD_PX = 20;

// Finger counts we own entirely - no other handler should see these.
const OWNED_FINGER_COUNTS = new Set([3, 4]);

export class TouchpadGestureRouter {

    // handlers: plain object keyed by '<nfingers>-<orientation>', e.g.
    //   { '3-vertical': fn(direction), '3-horizontal': fn(direction), ... }
    // direction is 'up'|'down' for vertical, 'left'|'right' for horizontal.
    constructor(handlers) {
        this._handlers = handlers;
        this._state = 'idle'; // idle | accumulating | dispatched
        this._fingers = 0;
        this._cumX = 0;
        this._cumY = 0;
        this._handlerId = global.stage.connect('captured-event::touchpad', this._onEvent.bind(this));
    }

    _onEvent(_actor, event) {
        if (event.type() !== Clutter.EventType.TOUCHPAD_SWIPE)
            return Clutter.EVENT_PROPAGATE;

        const phase = event.get_gesture_phase();

        if (phase === Clutter.TouchpadGesturePhase.BEGIN) {
            const n = event.get_touchpad_gesture_finger_count();
            if (OWNED_FINGER_COUNTS.has(n)) {
                this._state = 'accumulating';
                this._fingers = n;
                this._cumX = 0;
                this._cumY = 0;
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

            const [dx, dy] = event.get_gesture_motion_delta_unaccelerated();
            this._cumX += dx;
            this._cumY += dy;

            const distance = Math.sqrt(this._cumX * this._cumX + this._cumY * this._cumY);
            if (distance < THRESHOLD_PX)
                return Clutter.EVENT_STOP;

            const orientation = Math.abs(this._cumX) > Math.abs(this._cumY) ? 'horizontal' : 'vertical';
            const direction = orientation === 'vertical'
                ? (this._cumY > 0 ? 'down' : 'up')
                : (this._cumX > 0 ? 'right' : 'left');

            const handler = this._handlers[`${this._fingers}-${orientation}`];
            if (handler)
                handler(direction);

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
