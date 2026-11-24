import Toybox.Communications;
import Toybox.Lang;
import Toybox.Time;

// One call of the watch API. params is sent as a JSON body, or body as raw Ogg Opus audio instead;
// json says whether the answer has one.
(:glance)
class Request {
    var method as Communications.HttpRequestMethod;
    var path as String;
    var params as Dictionary<String, String>?;
    var json as Boolean;
    var body as ByteArray? = null;

    function initialize(method as Communications.HttpRequestMethod, path as String, params as Dictionary<String, String>?, json as Boolean) {
        self.method = method;
        self.path = path;
        self.params = params;
        self.json = json;
    }
}

(:glance)
module Api {
    const ALARM = "/api/watch/alarm";
    const WEATHER = "/api/watch/weather";
    const SELF_REPORT = "/api/watch/self-report";
    const VOICE_CALL = "/api/watch/voice/call";
    // the log of the watch outside a call
    const LOG = "/api/watch/log";

    function alarms() as Request {
        return new Request(Communications.HTTP_REQUEST_METHOD_GET, ALARM, null, true);
    }

    function weather() as Request {
        return new Request(Communications.HTTP_REQUEST_METHOD_GET, WEATHER, null, true);
    }

    function create(fireAt as Time.Moment) as Request {
        return new Request(Communications.HTTP_REQUEST_METHOD_POST, ALARM, {"fire_at" => AlarmTime.toIso(fireAt)}, true);
    }

    function update(id as String, fireAt as Time.Moment) as Request {
        return new Request(Communications.HTTP_REQUEST_METHOD_PUT, ALARM + "/" + id, {"fire_at" => AlarmTime.toIso(fireAt)}, true);
    }

    function remove(id as String) as Request {
        return new Request(Communications.HTTP_REQUEST_METHOD_DELETE, ALARM + "/" + id, null, false);
    }

    function dismissAll() as Request {
        return new Request(Communications.HTTP_REQUEST_METHOD_POST, ALARM + "/dismiss", null, false);
    }

    // A spoken self-report: the recorded audio, the client's id (a retry carries the same one),
    // the face (null for a skipped one) and when recording began. tries is the attempt number, 0
    // for the first; the simulator answers an identical repeat of a failed request from memory.
    function selfReport(id as String, feel as String?, at as Time.Moment, audio as ByteArray, tries as Number) as Request {
        var request = new Request(Communications.HTTP_REQUEST_METHOD_POST, SelfReport.path(id, feel, AlarmTime.toIso(at), tries), null, true);
        request.body = audio;
        return request;
    }
}
