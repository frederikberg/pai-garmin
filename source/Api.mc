import Toybox.Communications;
import Toybox.Lang;
import Toybox.Time;

// One call of the watch API. params is sent as a JSON body; json says whether the answer has one.
(:glance)
class Request {
    var method as Communications.HttpRequestMethod;
    var path as String;
    var params as Dictionary<String, String>?;
    var json as Boolean;

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
    const VOICE_CALL = "/api/watch/voice/call";
    const VOICE_TEST = "/api/watch/voice/test";

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
}
