import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

// Logs and reports a mismatch, so a failing test names the line.
function same(logger as Logger, got as String, want as String) as Boolean {
    if (!got.equals(want)) {
        logger.debug("got '" + got + "', want '" + want + "'");
    }
    return got.equals(want);
}

function weatherData(now as Dictionary, later as Dictionary, location as Dictionary?) as Dictionary {
    return {"location" => location, "now" => now, "later" => later};
}

(:test)
function rainAheadReadsAsTwoRows(logger as Logger) as Boolean {
    var now = {"chance" => 70, "verdict" => "rain", "raining_now" => false, "starts_at" => "2023-11-14T22:13:20+00:00",
        "nearest_km" => 8.2, "direction" => "W", "trend" => "approaching", "method" => "radar", "reason" => null};
    var later = {"chance" => 40, "verdict" => "maybe", "at" => "2023-11-15T06:00:00+00:00", "reason" => null};
    var place = {"place" => "Aachen", "recorded_at" => "2023-11-14T22:00:00+00:00"};
    var state = WeatherState.fromData(weatherData(now, later, place));
    if (state == null) {
        return false;
    }
    var ok = same(logger, WeatherText.nowLine(state.now), "Now 70 % · " + AlarmTime.hhmm(new Time.Moment(1700000000)));
    ok = same(logger, WeatherText.nowCaption(state.now), "8 km W, closing in") && ok;
    ok = same(logger, WeatherText.laterLine(state.later), "Later 40 % · " + AlarmTime.hhmm(new Time.Moment(1700028000))) && ok;
    ok = same(logger, WeatherText.laterCaption(state.later), "rain possible") && ok;
    ok = same(logger, WeatherText.footer(state, new Time.Moment(1699999200 + 12 * 60)), "Aachen · 12 min ago") && ok;
    return ok && WeatherText.problem(state) == null;
}

(:test)
function rainingNowAndDryAreWorded(logger as Logger) as Boolean {
    var raining = {"chance" => 100, "verdict" => "rain", "raining_now" => true, "ends_at" => "2023-11-14T22:13:20+00:00", "method" => "radar"};
    var dry = {"chance" => 3, "verdict" => "dry", "raining_now" => false, "nearest_km" => null, "method" => "radar"};
    var forecast = {"chance" => 20, "verdict" => "unlikely", "raining_now" => false, "method" => "forecast"};
    var dryLater = {"chance" => 5, "verdict" => "dry", "at" => null};
    var a = WeatherState.fromData(weatherData(raining, dryLater, null));
    var b = WeatherState.fromData(weatherData(dry, dryLater, null));
    var c = WeatherState.fromData(weatherData(forecast, dryLater, null));
    if (a == null || b == null || c == null) {
        return false;
    }
    var ok = same(logger, WeatherText.nowLine(a.now), "Now 100 %");
    ok = same(logger, WeatherText.nowCaption(a.now), "raining now, until " + AlarmTime.hhmm(new Time.Moment(1700000000))) && ok;
    ok = same(logger, WeatherText.nowCaption(b.now), "dry around you") && ok;
    ok = same(logger, WeatherText.nowCaption(c.now), "forecast only") && ok;
    ok = same(logger, WeatherText.laterLine(b.later), "Later 5 %") && ok;
    return same(logger, WeatherText.laterCaption(b.later), "dry all day") && ok;
}

(:test)
function unknownStatesSayWhatToDo(logger as Logger) as Boolean {
    var noLocation = {"chance" => null, "verdict" => "unknown", "reason" => "no_location"};
    var down = {"chance" => null, "verdict" => "unknown", "reason" => "source_unavailable", "at" => "2023-11-14T22:13:20+00:00"};
    var fine = {"chance" => 10, "verdict" => "unlikely", "reason" => null};
    var a = WeatherState.fromData(weatherData(noLocation, noLocation, null));
    var b = WeatherState.fromData(weatherData(down, down, {"place" => null}));
    var half = WeatherState.fromData(weatherData(fine, down, {"place" => "Aachen"}));
    if (a == null || b == null || half == null) {
        return false;
    }
    var first = WeatherText.problem(a);
    var second = WeatherText.problem(b);
    var ok = first != null && first.find("PAI Settings") != null;
    ok = second != null && second.find("not answering") != null && ok;
    ok = WeatherText.problem(half) == null && ok;
    ok = same(logger, WeatherText.laterCaption(half.later), "no answer") && ok;
    return same(logger, WeatherText.laterLine(half.later), "Later -") && ok;
}

(:test)
function ageIsWordedByUnit(logger as Logger) as Boolean {
    var ok = same(logger, WeatherText.age(30), "just now");
    ok = same(logger, WeatherText.age(-5), "just now") && ok;
    ok = same(logger, WeatherText.age(600), "10 min ago") && ok;
    ok = same(logger, WeatherText.age(7300), "2 h ago") && ok;
    return same(logger, WeatherText.age(200000), "2 d ago") && ok;
}

(:test)
function anAnswerWithoutTheHalvesIsRejected(logger as Logger) as Boolean {
    return WeatherState.fromData({"now" => {"chance" => 1}}) == null && WeatherState.fromData({}) == null;
}

(:test)
function laterNamesTheHeaviestHourAndAmount(logger as Logger) as Boolean {
    var now = {"chance" => 3, "verdict" => "dry", "raining_now" => false, "method" => "radar"};
    var later = {"chance" => 100, "verdict" => "rain", "at" => "2023-11-14T22:13:20+00:00", "reason" => null,
        "heaviest_at" => "2023-11-15T06:00:00+00:00", "total_mm" => 3.6,
        "hours" => [
            {"start" => "2023-11-14T22:00:00+00:00", "chance" => 40, "precipitation_mm" => 0.2, "intensity" => "light"},
            {"start" => "bad", "chance" => 50, "precipitation_mm" => 0.2, "intensity" => "light"},
            {"start" => "2023-11-14T23:00:00+00:00", "chance" => 95.6, "precipitation_mm" => 2.4, "intensity" => "moderate"}
        ]};
    var data = weatherData(now, later, null);
    data["radar_picture_path"] = "/api/watch/weather/radar.png?t=abc";
    var state = WeatherState.fromData(data);
    var light = WeatherState.fromData(weatherData(now, {"chance" => 60, "verdict" => "rain", "heaviest_at" => "2023-11-15T06:00:00+00:00", "total_mm" => 0.36}, null));
    if (state == null || light == null) {
        return false;
    }
    var hours = state.later.hours;
    var ok = hours.size() == 2 && hours[1].chance == 96 && hours[1].intensity.equals("moderate");
    ok = same(logger, WeatherText.laterCaption(state.later), "heaviest " + AlarmTime.hhmm(new Time.Moment(1700028000)) + " · 4 mm") && ok;
    ok = same(logger, WeatherText.laterCaption(light.later), "heaviest " + AlarmTime.hhmm(new Time.Moment(1700028000)) + " · 0.4 mm") && ok;
    return ok && "/api/watch/weather/radar.png?t=abc".equals(state.picturePath) && light.picturePath == null;
}

(:test)
function textNearTheEdgeOfARoundScreenGetsLessWidth(logger as Logger) as Boolean {
    var middle = Draw.chord(260, 260, true, 130, 20);
    var high = Draw.chord(260, 260, true, 40, 20);
    var square = Draw.chord(260, 260, false, 40, 20);
    logger.debug("middle " + middle + ", high " + high + ", square " + square);
    return middle > 200 && high < 170 && high > 100 && square > middle && Draw.chord(260, 260, true, 2, 20) == 0;
}
