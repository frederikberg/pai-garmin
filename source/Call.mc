import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// One request from the screen. The callback runs once, with the answer or with a failure when the
// request cannot go out or nothing answers in time; cancel() drops it for good.
// makeWebRequest has no timeout of its own, hence the watchdog.
class Call {
    const TIMEOUT_MS = 25000;

    private var _callback as Method(outcome as Outcome) as Void;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _open as Boolean = true;
    private var _request as Request? = null;

    function initialize(callback as Method(outcome as Outcome) as Void) {
        _callback = callback;
    }

    function send(request as Request) as Void {
        _request = request;
        if (!ServerConfig.isSet()) {
            finish(Outcome.failed("not_set_up"));
        } else if (!System.getDeviceSettings().phoneConnected) {
            finish(Outcome.failed("no_phone"));
        } else {
            _timer.start(method(:onTimeout), TIMEOUT_MS, false);
            try {
                Wire.send(request, method(:onResponse));
            } catch (ex) {
                finish(Outcome.failed("send_failed"));
            }
        }
    }

    function cancel() as Void {
        _open = false;
        _timer.stop();
    }

    function onResponse(responseCode as Number, data as Dictionary or String or Null) as Void {
        var request = _request;
        finish(Outcome.fromResponse(responseCode, data, request == null || request.json));
    }

    function onTimeout() as Void {
        finish(Outcome.failed("timeout"));
    }

    private function finish(outcome as Outcome) as Void {
        if (_open) {
            cancel();
            _callback.invoke(outcome);
        }
    }
}
