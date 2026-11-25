import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// The glance-list entry: the app name over the next alarm, or that one rings. It starts from the last line it
// remembered and refreshes from the server while it is on screen. An alarm it finds ringing is
// stopped at once, with one short buzz.
(:glance, :glanceView)
class PaiGlance extends WatchUi.GlanceView {
    const REFRESH_MS = 15000;
    const STORAGE_KEY = "glance";

    private var _text as String;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _stopping as Boolean = false;

    function initialize() {
        GlanceView.initialize();
        var remembered = Application.Storage.getValue(STORAGE_KEY);
        _text = remembered instanceof String ? remembered : "";
    }

    function onShow() as Void {
        refresh();
        _timer.start(method(:refresh), REFRESH_MS, true);
    }

    function onHide() as Void {
        _timer.stop();
    }

    function refresh() as Void {
        if (ServerConfig.isSet()) {
            Wire.send(Api.alarms(), method(:onResponse));
        }
    }

    function onResponse(responseCode as Number, data as Dictionary or String or Null) as Void {
        var state = Outcome.fromResponse(responseCode, data, true).state;
        if (state != null && state.ringing.size() > 0 && !_stopping) {
            _stopping = true;
            Wire.send(Api.dismissAll(), method(:onDismissed));
        }
        if (state != null) {
            _text = state.summary(Time.now());
            try {
                Application.Storage.setValue(STORAGE_KEY, _text);
            } catch (ex) {
                // a full store keeps the last summary; the glance shows the new one meanwhile
            }
            WatchUi.requestUpdate();
        }
    }

    function onDismissed(responseCode as Number, data as Dictionary or String or Null) as Void {
        _stopping = false;
        if (Outcome.fromResponse(responseCode, data, false).isOk()) {
            Buzz.once();
            refresh();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, dc.getHeight() * 30 / 100, Graphics.FONT_GLANCE, "PAI",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, dc.getHeight() * 70 / 100, Graphics.FONT_GLANCE, _text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
