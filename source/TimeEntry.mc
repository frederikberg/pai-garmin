import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

// Hour and minute entry: Up and Down change the marked number by one and repeat, faster the longer
// the button is held. Enter moves from the hour to the minute and then confirms, Back moves from the
// minute to the hour and then cancels.
class TimeEntryView extends WatchUi.View {
    private var _title as String;
    private var _hour as Number;
    private var _minute as Number;
    private var _onMinute as Boolean = false;
    private var _onPicked as Method(hour as Number, minute as Number) as Void;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _direction as Number = 0;
    private var _repeats as Number = 0;

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

    static function open(title as String, hour as Number, minute as Number, onPicked as Method(hour as Number, minute as Number) as Void) as Void {
        var view = new TimeEntryView(title, hour, minute, onPicked);
        WatchUi.pushView(view, new TimeEntryDelegate(view), WatchUi.SLIDE_IMMEDIATE);
    }

    function initialize(title as String, hour as Number, minute as Number, onPicked as Method(hour as Number, minute as Number) as Void) {
        View.initialize();
        _title = title;
        _hour = hour;
        _minute = minute;
        _onPicked = onPicked;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        Draw.title(dc, _title);
        var x = dc.getWidth() / 2;
        var y = dc.getHeight() / 2;
        var font = Graphics.FONT_NUMBER_HOT;
        var gap = dc.getTextWidthInPixels("00", font) / 2 + dc.getTextWidthInPixels(":", font) / 2;
        var justify = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, ":", justify);
        dc.setColor(_onMinute ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x - gap, y, font, _hour.format("%02d"), justify);
        dc.setColor(_onMinute ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + gap, y, font, _minute.format("%02d"), justify);
        Draw.hint(dc, _onMinute ? "Enter: save" : "Enter: minutes");
    }

    // Up adds, Down subtracts; both wrap around.
    function change(delta as Number) as Void {
        if (_onMinute) {
            _minute = (_minute + delta + 60) % 60;
        } else {
            _hour = (_hour + delta + 24) % 24;
        }
        WatchUi.requestUpdate();
    }

    // A button went down: one step now, then repeats while it stays down.
    function hold(delta as Number) as Void {
        change(delta);
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
        if (_onMinute) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            _onPicked.invoke(_hour, _minute);
        } else {
            _onMinute = true;
            WatchUi.requestUpdate();
        }
    }

    function back() as Void {
        if (_onMinute) {
            _onMinute = false;
            WatchUi.requestUpdate();
        } else {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        }
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
