import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Hour and minute entry: Up and Down change the marked number, Enter moves from the hour to the
// minute and then confirms, Back moves from the minute to the hour and then cancels.
class TimeEntryView extends WatchUi.View {
    private var _title as String;
    private var _hour as Number;
    private var _minute as Number;
    private var _onMinute as Boolean = false;
    private var _onPicked as Method(hour as Number, minute as Number) as Void;

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

    function onPreviousPage() as Boolean {
        _view.change(1);
        return true;
    }

    function onNextPage() as Boolean {
        _view.change(-1);
        return true;
    }

    function onBack() as Boolean {
        _view.back();
        return true;
    }
}
