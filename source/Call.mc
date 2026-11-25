import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// One request from the screen. The callback runs once, with the answer or with a failure when the
// request cannot go out or nothing answers in time; cancel() drops it for good.
// makeWebRequest has no timeout of its own, hence the watchdog.
class Call {
    const TIMEOUT_MS = 25000;

    private var _callback as Method(outcome as Outcome) as Void;
    // the watchdog's job in Later, 0 when none waits
    private var _watchdog as Number = 0;
    private var _open as Boolean = true;
    private var _request as Request? = null;
    // counted in Idle.busy while out
    private var _counted as Boolean = false;

    function initialize(callback as Method(outcome as Outcome) as Void) {
        _callback = callback;
    }

    // Goes out once the check made at launch is over (Gate); until then the call waits.
    function send(request as Request) as Void {
        _request = request;
        if (Gate.open) {
            sendNow(request);
        } else {
            Gate.waiting.add(self);
        }
    }

    // Called by Gate when the wait is over.
    function release() as Void {
        var request = _request;
        if (request != null) {
            sendNow(request);
        }
    }

    // Goes out at once, past the gate: the check itself and the dismiss it triggers.
    function sendNow(request as Request) as Void {
        _request = request;
        if (!ServerConfig.isSet()) {
            finish(Outcome.failed("not_set_up"));
        } else if (!System.getDeviceSettings().phoneConnected) {
            finish(Outcome.failed("no_phone"));
        } else {
            Idle.busy += 1;
            _counted = true;
            _watchdog = Later.at(TIMEOUT_MS, method(:onTimeout));
            try {
                Wire.send(request, method(:onResponse));
            } catch (ex) {
                finish(Outcome.failed("send_failed"));
            }
        }
    }

    function cancel() as Void {
        if (_counted) {
            _counted = false;
            Idle.busy -= 1;
        }
        _open = false;
        Gate.waiting.remove(self);
        if (_watchdog != 0) {
            Later.cancel(_watchdog);
            _watchdog = 0;
        }
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
            Idle.poke(Idle.DELAY_MS);
        }
    }
}
