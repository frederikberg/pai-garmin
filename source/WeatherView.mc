import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

// The Weather sub-app: two rows, the next hour and the next twelve hours, coloured by the server's
// verdict, with where and how old the location is. Enter asks again; Back leaves.
class WeatherView extends WatchUi.View {
    private var _call as Call? = null;
    private var _state as WeatherState? = null;
    // what the screen says when there is no state to show
    private var _message as String = "Loading...";
    private var _updating as Boolean = false;

    function initialize() {
        View.initialize();
    }

    function onShow() as Void {
        if (_call == null) {
            refresh();
        }
    }

    function onHide() as Void {
        var call = _call;
        if (call != null) {
            call.cancel();
            _call = null;
            _updating = false;
        }
    }

    // Enter: ask the server again, keeping the old answer on screen until the new one arrives.
    function refresh() as Void {
        if (_call != null) {
            return;
        }
        _updating = true;
        if (_state == null) {
            _message = "Loading...";
        }
        var call = new Call(method(:onOutcome));
        _call = call;
        WatchUi.requestUpdate();
        call.send(Api.weather());
    }

    function onOutcome(outcome as Outcome) as Void {
        _call = null;
        _updating = false;
        var data = outcome.data;
        var state = data == null ? null : WeatherState.fromData(data);
        if (state != null) {
            _state = state;
        } else {
            _state = null;
            _message = outcome.isOk() ? "Unexpected answer" : outcome.text();
        }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        var state = _state;
        var problem = state == null ? _message : WeatherText.problem(state);
        if (state == null || problem != null) {
            Draw.title(dc, "Weather");
            Draw.paragraph(dc, problem == null ? "" : problem, 30, 80);
            if (_call == null) {
                Draw.hint(dc, "Enter: retry");
            }
            return;
        }
        row(dc, 26, WeatherText.nowLine(state.now), WeatherText.nowCaption(state.now), state.now);
        row(dc, 55, WeatherText.laterLine(state.later), WeatherText.laterCaption(state.later), state.later);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 81 / 100, Graphics.FONT_XTINY, WeatherText.footer(state, Time.now()),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() * 89 / 100, Graphics.FONT_XTINY, _updating ? "Updating..." : "Enter: refresh",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // A headline in the verdict's colour with its caption under it; y is the headline's centre in percent.
    private function row(dc as Graphics.Dc, y as Number, line as String, caption as String, outlook as Outlook) as Void {
        var x = dc.getWidth() / 2;
        dc.setColor(outlook.known() ? Verdict.color(outlook.verdict) : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, dc.getHeight() * y / 100, Graphics.FONT_MEDIUM, line, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, dc.getHeight() * (y + 11) / 100, Graphics.FONT_XTINY, caption, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

class WeatherDelegate extends WatchUi.BehaviorDelegate {
    private var _view as WeatherView;

    function initialize(view as WeatherView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.refresh();
        return true;
    }
}
