import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// The lines a previous run stored (at the end of its last turn, or at its exit) go to the server's log
// once the launch is quiet: after the launch check and while no Computer call is running.
class StoredLog {
    const FIRST_MS = 3000;
    const RETRY_MS = 5000;
    const TRIES = 6;

    private var _timer as Timer.Timer = new Timer.Timer();
    private var _lines as Array? = null;
    private var _tries as Number = 0;

    // Takes the stored lines out of storage; they wait in memory until they are sent.
    function start() as Void {
        _lines = Trace.stored();
        if (_lines != null) {
            Trace.clearStored();
            _timer.start(method(:onTimer), FIRST_MS, false);
        }
    }

    function onTimer() as Void {
        var lines = _lines;
        if (lines == null) {
            return;
        }
        if (!Gate.open || Trace.active || !System.getDeviceSettings().phoneConnected || !ServerConfig.isSet()) {
            _tries += 1;
            if (_tries < TRIES) {
                _timer.start(method(:onTimer), RETRY_MS, false);
            }
            return;
        }
        var body = {"stored" => true, "sent_t" => System.getTimer(), "lines" => lines} as Dictionary<Object, Object>;
        Communications.makeWebRequest(ServerConfig.url() + Api.LOG, body, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => Wire.authorization(),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onResponse));
    }

    function onResponse(code as Number, data as Dictionary or String or Null) as Void {
        if (code >= 200 && code < 300) {
            _lines = null;
        } else {
            _tries += 1;
            if (_tries < TRIES) {
                _timer.start(method(:onTimer), RETRY_MS, false);
            }
        }
    }
}
