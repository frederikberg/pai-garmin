import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// Time entry. A new alarm is set either as a clock time (hour, minute; the default) or as a duration
// from now (hours, minutes, seconds, starting at 0:00:00); a changed alarm is always a clock time.
// Up and Down change the marked number by one and repeat, faster the longer the button is held.
// Enter moves to the next number and the last one confirms. Back moves to the previous number; from
// the first number of a new alarm it reaches the mode choice ("At time" or "In", changed by Up and
// Down), and from there, or from the first number of a changed alarm, it cancels.
class TimeEntryView extends WatchUi.View {
    private var _title as String;
    // the clock time (hour, minute) and the duration (hours, minutes, seconds) are kept apart
    private var _clock as Array<Number>;
    private var _duration as Array<Number> = [0, 0, 0];
    private var _relative as Boolean = false;
    private var _canSwitch as Boolean;
    // the marked number's index, or MODE_FIELD
    private var _field as Number = 0;
    // shown instead of the hint after a save of a zero duration was refused, until the next change
    private var _refused as Boolean = false;
    private var _onPicked as Method(at as Time.Moment) as Void;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _direction as Number = 0;
    private var _repeats as Number = 0;

    static const MODE_FIELD = -1;
    // Delay before a held button starts repeating, then the pause between two steps: it shrinks with
    // every step down to a floor.
    static const FIRST_REPEAT_MS = 400;
    static const SLOWEST_MS = 200;
    static const FASTEST_MS = 40;
    static const SPEEDUP_MS = 12;
    // A held button that never reports its release (a firmware shortcut takes it) stops after this long.
    static const MAX_REPEATS = 80;

    static function repeatPause(repeats as Number) as Number {
        var pause = SLOWEST_MS - repeats * SPEEDUP_MS;
        return pause < FASTEST_MS ? FASTEST_MS : pause;
    }

    // value moved by delta inside 0 .. size - 1, wrapping around.
    static function wrap(value as Number, delta as Number, size as Number) as Number {
        return (value + delta % size + size) % size;
    }

    // The upper bound (exclusive) of each number: hours 0-23, minutes and seconds 0-59.
    static function limits(relative as Boolean) as Array<Number> {
        return relative ? [24, 60, 60] : [24, 60];
    }

    // newAlarm: the entry offers the duration mode and starts on the clock; otherwise it only edits a clock time.
    static function open(title as String, hour as Number, minute as Number, newAlarm as Boolean, onPicked as Method(at as Time.Moment) as Void) as Void {
        var view = new TimeEntryView(title, hour, minute, newAlarm, onPicked);
        WatchUi.pushView(view, new TimeEntryDelegate(view), WatchUi.SLIDE_IMMEDIATE);
    }

    function initialize(title as String, hour as Number, minute as Number, canSwitch as Boolean, onPicked as Method(at as Time.Moment) as Void) {
        View.initialize();
        _title = title;
        _clock = [hour, minute];
        _canSwitch = canSwitch;
        _onPicked = onPicked;
    }

    private function values() as Array<Number> {
        return _relative ? _duration : _clock;
    }

    // The moment the entry stands for, counted from now.
    private function target() as Time.Moment {
        var now = Time.now();
        return _relative
            ? AlarmTime.afterDuration(now, _duration[0], _duration[1], _duration[2])
            : AlarmTime.nextOccurrence(now, _clock[0], _clock[1]);
    }

    private function lastField() as Number {
        return values().size() - 1;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        Draw.title(dc, _title);
        var x = dc.getWidth() / 2;
        var y = dc.getHeight() / 2;
        var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        if (_canSwitch) {
            drawMode(dc, x, dc.getHeight() * 29 / 100);
        }
        var font = _relative ? Graphics.FONT_NUMBER_MEDIUM : Graphics.FONT_NUMBER_HOT;
        var slot = dc.getTextWidthInPixels("00", font);
        var colon = dc.getTextWidthInPixels(":", font);
        var numbers = values();
        var left = x - (numbers.size() * slot + (numbers.size() - 1) * colon) / 2;
        for (var i = 0; i < numbers.size(); i++) {
            var cx = left + i * (slot + colon) + slot / 2;
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            if (i > 0) {
                dc.drawText(cx - slot / 2 - colon / 2, y, font, ":", justify);
            }
            dc.setColor(i == _field ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            // hours of a duration are written without a leading zero and sit against the colon: 0:00:00
            if (_relative && i == 0) {
                dc.drawText(cx + slot / 2, y, font, numbers[i].format("%d"), Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            } else {
                dc.drawText(cx, y, font, numbers[i].format("%02d"), justify);
            }
        }
        // the clock while picking, so the number can be set against it; for a duration, when it ends
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var now = Time.now();
        var below = "Now " + AlarmTime.hhmm(now);
        if (_relative && AlarmTime.durationSeconds(_duration[0], _duration[1], _duration[2]) > 0) {
            below = "Rings " + AlarmTime.clock(target());
        }
        dc.drawText(x, dc.getHeight() * 72 / 100, Graphics.FONT_XTINY, below, justify);
        if (_refused) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, dc.getHeight() * 86 / 100, Graphics.FONT_XTINY, "Set a time first", justify);
        } else {
            Draw.hint(dc, hint());
        }
    }

    // "At time" and "In" side by side; the chosen one is white, green while the choice itself is marked.
    private function drawMode(dc as Graphics.Dc, x as Number, y as Number) as Void {
        var font = Graphics.FONT_XTINY;
        var gap = dc.getWidth() * 14 / 100;
        var marked = _field == MODE_FIELD;
        var chosen = marked ? Graphics.COLOR_GREEN : Graphics.COLOR_WHITE;
        dc.setColor(_relative ? Graphics.COLOR_DK_GRAY : chosen, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x - gap, y, font, "At time", Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(_relative ? chosen : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + gap, y, font, "In", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function hint() as String {
        if (_field == MODE_FIELD) {
            return "Up/Down: switch";
        }
        if (_field == lastField()) {
            return "Enter: save";
        }
        if (_field == 0 && _canSwitch) {
            return "Back: At time / In";
        }
        return _field == 0 ? "Enter: minutes" : "Enter: seconds";
    }

    // Up adds, Down subtracts; both wrap around. On the mode choice either one switches the mode.
    function change(delta as Number) as Void {
        _refused = false;
        if (_field == MODE_FIELD) {
            _relative = !_relative;
        } else {
            var numbers = values();
            numbers[_field] = wrap(numbers[_field], delta, limits(_relative)[_field]);
        }
        WatchUi.requestUpdate();
    }

    // A button went down: one step now, then repeats while it stays down (not on the mode choice,
    // where every step would switch again).
    function hold(delta as Number) as Void {
        change(delta);
        if (_field == MODE_FIELD) {
            return;
        }
        _direction = delta;
        _repeats = 0;
        _timer.start(method(:onRepeat), FIRST_REPEAT_MS, false);
    }

    function release() as Void {
        _direction = 0;
        _timer.stop();
    }

    function onRepeat() as Void {
        if (_direction == 0) {
            return;
        }
        change(_direction);
        _repeats += 1;
        if (_repeats < MAX_REPEATS) {
            _timer.start(method(:onRepeat), repeatPause(_repeats), false);
        }
    }

    function onHide() as Void {
        release();
    }

    function confirm() as Void {
        if (_field == MODE_FIELD) {
            _field = 0;
        } else if (_field < lastField()) {
            _field += 1;
        } else if (_relative && AlarmTime.durationSeconds(_duration[0], _duration[1], _duration[2]) == 0) {
            _refused = true;
        } else {
            var at = target();
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            _onPicked.invoke(at);
            return;
        }
        WatchUi.requestUpdate();
    }

    function back() as Void {
        _refused = false;
        if (_field > 0) {
            _field -= 1;
        } else if (_field == 0 && _canSwitch) {
            _field = MODE_FIELD;
        } else {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            return;
        }
        WatchUi.requestUpdate();
    }
}

class TimeEntryDelegate extends WatchUi.BehaviorDelegate {
    private var _view as TimeEntryView;

    function initialize(view as TimeEntryView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.confirm();
        return true;
    }

    // Up and Down act when they go down and repeat until released; the platform's own behaviours for
    // the same presses do nothing.
    function onKeyPressed(evt as WatchUi.KeyEvent) as Boolean {
        var key = evt.getKey();
        if (key == WatchUi.KEY_UP) {
            _view.hold(1);
        } else if (key == WatchUi.KEY_DOWN) {
            _view.hold(-1);
        }
        return false;
    }

    function onKeyReleased(evt as WatchUi.KeyEvent) as Boolean {
        _view.release();
        return false;
    }

    function onPreviousPage() as Boolean {
        return true;
    }

    function onNextPage() as Boolean {
        return true;
    }

    // Up held.
    function onMenu() as Boolean {
        return true;
    }

    function onBack() as Boolean {
        _view.back();
        return true;
    }
}
