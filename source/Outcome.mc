import Toybox.Communications;
import Toybox.Lang;
import Toybox.Time;

// One alarm of the server, either armed or ringing.
(:glance)
class Alarm {
    var id as String;
    var name as String;
    var fireAt as Time.Moment;

    function initialize(id as String, name as String, fireAt as Time.Moment) {
        self.id = id;
        self.name = name;
        self.fireAt = fireAt;
    }

    // Null for an entry without an id or a readable fire_at.
    static function fromData(data as Object?) as Alarm? {
        if (!(data instanceof Dictionary)) {
            return null;
        }
        var id = data["id"] as Object?;
        var name = data["name"] as Object?;
        var fireAt = data["fire_at"] as Object?;
        var moment = fireAt instanceof String ? AlarmTime.parseIso(fireAt) : null;
        if (!(id instanceof String) || moment == null) {
            return null;
        }
        return new Alarm(id, name instanceof String ? name : "Alarm", moment);
    }
}

// The answer of GET /api/watch/alarm: the armed alarms by fire time, and the ringing ones.
(:glance)
class AlarmState {
    var alarms as Array<Alarm>;
    var ringing as Array<Alarm>;

    function initialize(alarms as Array<Alarm>, ringing as Array<Alarm>) {
        self.alarms = alarms;
        self.ringing = ringing;
    }

    static function fromData(data as Dictionary) as AlarmState {
        return new AlarmState(parse(data["alarms"] as Object?), parse(data["ringing"] as Object?));
    }

    private static function parse(items as Object?) as Array<Alarm> {
        var list = [] as Array<Alarm>;
        if (items instanceof Array) {
            for (var i = 0; i < items.size(); i++) {
                var alarm = Alarm.fromData(items[i] as Object?);
                if (alarm != null) {
                    list.add(alarm);
                }
            }
        }
        return list;
    }

    // The one line the glance shows.
    function summary(now as Time.Moment) as String {
        if (ringing.size() > 0) {
            return "Alarm ringing";
        }
        if (alarms.size() == 0) {
            return "No alarms";
        }
        var next = alarms[0].fireAt;
        var day = AlarmTime.dayLabel(next, now);
        return "Next " + AlarmTime.clock(next) + (day.equals("Today") ? "" : " " + day);
    }
}

// How one call ended.
(:glance)
class Outcome {
    enum {
        OK,
        // HTTP 401: the watch key is wrong
        REJECTED,
        // no usable answer: transport error, other HTTP status, no phone, not set up
        FAILED
    }

    var kind as Number;
    // a local code (not_set_up, no_phone, timeout, send_failed) or http_<status>
    var code as String? = null;
    var state as AlarmState? = null;
    // the parsed JSON object of a successful answer, for screens that read other routes
    var data as Dictionary? = null;

    function initialize(kind as Number) {
        self.kind = kind;
    }

    static function failed(code as String) as Outcome {
        var o = new Outcome(FAILED);
        o.code = code;
        return o;
    }

    // responseCode is the HTTP status, or a negative Connect IQ transport error. expectsBody is false
    // for DELETE and dismiss, whose answer is not read: the simulator reports an empty 204 as -400, so the
    // call counts as sent and whoever asked reads the state again.
    static function fromResponse(responseCode as Number, data as Dictionary or String or Null, expectsBody as Boolean) as Outcome {
        if (responseCode == 401) {
            return new Outcome(REJECTED);
        }
        if (responseCode == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return failed("no_phone");
        }
        if (responseCode == Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE && !expectsBody) {
            return new Outcome(OK);
        }
        if (responseCode < 200 || responseCode > 299) {
            return failed("http_" + responseCode);
        }
        var o = new Outcome(OK);
        if (data instanceof Dictionary) {
            o.data = data;
            o.state = AlarmState.fromData(data);
        }
        return o;
    }

    // A JSON number of an answer as an integer, whatever type it arrives as (the simulator hands
    // them over as Floats); null for anything else.
    static function number(v as Object?) as Number? {
        if (v instanceof Number || v instanceof Long || v instanceof Float || v instanceof Double) {
            return v.toNumber();
        }
        return null;
    }

    function isOk() as Boolean {
        return kind == OK;
    }

    // What the screen says about a failure.
    function text() as String {
        if (kind == REJECTED) {
            return "Watch key rejected. Check it in the Garmin Connect app";
        }
        var c = code;
        if ("not_set_up".equals(c)) {
            return "Set the server URL and watch key in the Garmin Connect app";
        }
        if ("no_phone".equals(c)) {
            return "Phone not connected. Connect it and try again";
        }
        if ("timeout".equals(c)) {
            return "The server did not answer";
        }
        return "Request failed (" + (c == null ? "unknown" : c) + ")";
    }
}
