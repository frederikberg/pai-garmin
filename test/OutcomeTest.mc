import Toybox.Communications;
import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

(:test)
function stateKeepsReadableAlarmsInOrder(logger as Logger) as Boolean {
    var data = {
        "alarms" => [
            {"id" => "a1", "name" => "Wake", "fire_at" => "2023-11-14T22:13:20+00:00"},
            {"id" => "a2", "fire_at" => "2023-11-15T06:00:00+00:00"},
            {"name" => "no id", "fire_at" => "2023-11-15T07:00:00+00:00"},
            {"id" => "a3", "name" => "bad time", "fire_at" => "soon"},
            "not an alarm"
        ],
        "ringing" => [{"id" => "r1", "name" => "Now", "fire_at" => "2023-11-14T22:13:20+00:00"}]
    };
    var state = Outcome.fromResponse(200, data, true).state;
    if (state == null || state.alarms.size() != 2 || state.ringing.size() != 1) {
        return false;
    }
    return state.alarms[0].id.equals("a1") && state.alarms[0].fireAt.value() == 1700000000
        && state.alarms[1].name.equals("Alarm") && state.ringing[0].name.equals("Now");
}

(:test)
function summaryNamesWhatTheGlanceShows(logger as Logger) as Boolean {
    var now = Time.now();
    var soon = new Alarm("a", "Alarm", new Time.Moment(now.value() + 60));
    var ringing = new Alarm("r", "Alarm", now);
    return new AlarmState([], []).summary(now).equals("No alarms")
        && new AlarmState([soon], [ringing]).summary(now).equals("Alarm ringing")
        && new AlarmState([soon], []).summary(now).find("Next " + AlarmTime.hhmm(soon.fireAt)) == 0;
}

(:test)
function responsesMapToOutcomes(logger as Logger) as Boolean {
    return Outcome.fromResponse(200, {"alarms" => [], "ringing" => []}, true).isOk()
        && Outcome.fromResponse(204, null, false).isOk()
        && Outcome.fromResponse(204, null, false).state == null
        && Outcome.fromResponse(401, null, true).kind == Outcome.REJECTED
        && Outcome.fromResponse(500, null, true).kind == Outcome.FAILED
        && "http_500".equals(Outcome.fromResponse(500, null, true).code)
        && "no_phone".equals(Outcome.fromResponse(Communications.BLE_CONNECTION_UNAVAILABLE, null, true).code);
}

(:test)
function anEmptyAnswerIsOnlyAnErrorWhereABodyIsExpected(logger as Logger) as Boolean {
    var empty = Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE;
    return Outcome.fromResponse(empty, null, false).isOk() && !Outcome.fromResponse(empty, null, true).isOk();
}
