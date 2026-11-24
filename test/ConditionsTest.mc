import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

function conditionsData() as Dictionary {
    var hours = [] as Array<Dictionary>;
    for (var i = 0; i < 12; i++) {
        hours.add({"start" => "2023-11-14T" + (10 + i).format("%02d") + ":00:00+00:00", "temp" => 8 + i, "symbol" => i < 6 ? "rain" : "clear",
            "night" => i > 8, "uv" => i < 3 ? 1.2 * i : 0.0});
    }
    return {"reason" => null, "symbol" => "rain", "night" => false, "temp_now" => 7, "temp_min" => 8, "temp_max" => 19, "hours" => hours,
        "uv" => {"now" => 1.2, "peak" => 4.1, "peak_at" => "2023-11-14T13:00:00+00:00"},
        "days" => [
            {"date" => "2026-11-24", "symbol" => "rain", "temp_max" => 14, "temp_min" => 8, "chance" => 90},
            {"date" => "2026-11-25", "symbol" => "clear", "temp_max" => 16, "temp_min" => 7, "chance" => null}
        ]};
}

function stateWith(conditions as Object?) as WeatherState? {
    var now = {"chance" => 70, "verdict" => "rain", "raining_now" => false, "method" => "radar"};
    var later = {"chance" => 40, "verdict" => "maybe", "reason" => null};
    var data = weatherData(now, later, {"place" => "Aachen"});
    data["radar_picture_path"] = "/api/radar-link.png?t=abc";
    if (conditions != null) {
        data["conditions"] = conditions;
    }
    return WeatherState.fromData(data);
}

(:test)
function aFullConditionsBlockIsRead(logger as Logger) as Boolean {
    var c = Conditions.fromData(conditionsData());
    var ok = c.known() && c.symbol.equals("rain") && c.tempNow == 7 && c.tempMin == 8 && c.tempMax == 19;
    ok = c.hours.size() == 12 && c.hours[11].night && !c.hours[0].night && c.hours[2].symbol.equals("rain") && c.hours[7].symbol.equals("clear") && ok;
    ok = c.days.size() == 2 && c.days[0].name.equals("Tue") && c.days[0].chance == 90 && c.days[1].chance == null && c.days[1].tempMin == 7 && ok;
    return ok && c.uvPeakAt != null && same(logger, ConditionsText.uvCaption(c), "peak 4 at " + AlarmTime.hhmm(new Time.Moment(1699966800)));
}

(:test)
function aMissingOrReasonedBlockIsUnknown(logger as Logger) as Boolean {
    var missing = Conditions.fromData(null);
    var wrongType = Conditions.fromData("rain");
    var down = Conditions.fromData({"reason" => "source_unavailable", "symbol" => null, "night" => false, "temp_now" => null, "temp_min" => null,
        "temp_max" => null, "hours" => [], "uv" => null, "days" => []});
    var noHours = conditionsData();
    noHours["hours"] = [];
    return !missing.known() && !wrongType.known() && !down.known() && !Conditions.fromData(noHours).known();
}

(:test)
function aBrokenHourOrDayIsSkipped(logger as Logger) as Boolean {
    var data = conditionsData();
    var hours = data["hours"] as Array<Object>;
    hours[1] = {"start" => "bad", "temp" => 9};
    hours[2] = {"start" => "2023-11-14T12:00:00+00:00"};
    hours[3] = "x";
    data["days"] = [{"date" => "later", "temp_max" => 1, "temp_min" => 0}, {"date" => "2026-11-25", "temp_max" => 3},
        {"date" => "2026-11-26", "temp_max" => 3, "temp_min" => 1}];
    var c = Conditions.fromData(data);
    return c.hours.size() == 9 && c.days.size() == 1 && c.days[0].name.equals("Thu") && c.hours[0].symbol.equals("rain");
}

(:test)
function missingSymbolsReadAsCloudyAndAHourUvAsAGap(logger as Logger) as Boolean {
    var data = conditionsData();
    data["symbol"] = null;
    data["hours"] = [{"start" => "2023-11-14T22:00:00+00:00", "temp" => 4}];
    data["days"] = [{"date" => "2026-11-24", "temp_max" => 5, "temp_min" => 1}];
    var c = Conditions.fromData(data);
    return c.symbol.equals("cloudy") && c.hours[0].symbol.equals("cloudy") && c.hours[0].uv == null && c.days[0].symbol.equals("cloudy");
}

(:test)
function negativeHalvesRoundAwayFromZero(logger as Logger) as Boolean {
    var data = conditionsData();
    data["temp_now"] = -0.5;
    data["temp_min"] = -2.5;
    data["temp_max"] = 0.4;
    data["hours"] = [{"start" => "2023-11-14T22:00:00+00:00", "temp" => 1.5}, {"start" => "2023-11-14T23:00:00+00:00", "temp" => -0.4}];
    var c = Conditions.fromData(data);
    var ok = c.tempNow == -1 && c.tempMin == -3 && c.tempMax == 0 && c.hours[0].temp == 2 && c.hours[1].temp == 0;
    return ok && same(logger, ConditionsText.degrees(c.hours[1].temp), "0°");
}

(:test)
function daysGetTheirWeekdayByArithmetic(logger as Logger) as Boolean {
    var a = ConditionsText.dayName("2026-11-24");
    var b = ConditionsText.dayName("2028-02-29");
    var c = ConditionsText.dayName("2000-01-01");
    return "Tue".equals(a) && "Tue".equals(b) && "Sat".equals(c) && ConditionsText.dayName("garbage") == null
        && ConditionsText.dayName("2026-13-01") == null && ConditionsText.dayName("2026-1-1") == null;
}

(:test)
function uvBandsChangeAtTheirBoundaries(logger as Logger) as Boolean {
    var ok = same(logger, ConditionsText.uvBand(0.4), "none") && same(logger, ConditionsText.uvBand(0.5), "low");
    ok = same(logger, ConditionsText.uvBand(2.4), "low") && same(logger, ConditionsText.uvBand(2.5), "moderate") && ok;
    ok = same(logger, ConditionsText.uvBand(5.4), "moderate") && same(logger, ConditionsText.uvBand(5.5), "high") && ok;
    ok = same(logger, ConditionsText.uvBand(7.4), "high") && same(logger, ConditionsText.uvBand(7.5), "very high") && ok;
    ok = same(logger, ConditionsText.uvBand(10.4), "very high") && same(logger, ConditionsText.uvBand(10.5), "extreme") && ok;
    ok = ConditionsText.uvColor(1.0) == 0x00FF00 && ConditionsText.uvColor(2.5) == 0xFFFF00 && ConditionsText.uvColor(5.5) == 0xFFAA00 && ok;
    return ok && ConditionsText.uvColor(7.5) == 0xFF0000 && ConditionsText.uvColor(10.5) == 0xFF00FF;
}

(:test)
function uvLineAndCaptionsSayWhatIsLeft(logger as Logger) as Boolean {
    var c = Conditions.fromData(conditionsData());
    var ok = same(logger, ConditionsText.uvLine(c), "UV 1 · low");
    var night = conditionsData();
    night["uv"] = {"now" => 0.0, "peak" => 0.0, "peak_at" => null};
    var n = Conditions.fromData(night);
    ok = same(logger, ConditionsText.uvLine(n), "UV 0 · none") && same(logger, ConditionsText.uvCaption(n), "no UV in the next 12 h") && ok;
    var faint = conditionsData();
    faint["uv"] = {"now" => 0.2, "peak" => 0.3, "peak_at" => "2023-11-14T13:00:00+00:00"};
    ok = same(logger, ConditionsText.uvCaption(Conditions.fromData(faint)), "no UV in the next 12 h") && ok;
    var noUv = conditionsData();
    noUv["uv"] = null;
    return ok && same(logger, ConditionsText.uvLine(Conditions.fromData(noUv)), "UV -");
}

(:test)
function conditionsAloneKeepTheScreenWorking(logger as Logger) as Boolean {
    var noRain = {"chance" => null, "verdict" => "unknown", "reason" => "source_unavailable"};
    var data = weatherData(noRain, noRain, {"place" => "Aachen"});
    data["conditions"] = conditionsData();
    var state = WeatherState.fromData(data);
    return state != null && WeatherText.problem(state) == null;
}

function pageIds(state as WeatherState?) as Array<Number> {
    return state == null ? [] as Array<Number> : WeatherPages.list(state);
}

function samePages(logger as Logger, got as Array<Number>, want as Array<Number>) as Boolean {
    if (got.size() != want.size()) {
        logger.debug("got " + got + ", want " + want);
        return false;
    }
    for (var i = 0; i < got.size(); i++) {
        if (got[i] != want[i]) {
            logger.debug("got " + got + ", want " + want);
            return false;
        }
    }
    return true;
}

(:test)
function theListHoldsThePagesTheAnswerFills(logger as Logger) as Boolean {
    var all = [WeatherPages.ROWS, WeatherPages.HOURS, WeatherPages.TEMP, WeatherPages.UV, WeatherPages.DAYS, WeatherPages.RADAR] as Array<Number>;
    var ok = samePages(logger, pageIds(stateWith(conditionsData())), all);

    // the forecast is down: the rain pages stay
    ok = samePages(logger, pageIds(stateWith({"reason" => "source_unavailable"})), [WeatherPages.ROWS, WeatherPages.HOURS, WeatherPages.RADAR] as Array<Number>) && ok;
    ok = samePages(logger, pageIds(stateWith(null)), [WeatherPages.ROWS, WeatherPages.HOURS, WeatherPages.RADAR] as Array<Number>) && ok;

    // the later half is down: no bars page, the forecast pages stay
    var noRain = {"chance" => null, "verdict" => "unknown", "reason" => "source_unavailable"};
    var data = weatherData({"chance" => 70, "verdict" => "rain", "raining_now" => false, "method" => "radar"}, noRain, {"place" => "Aachen"});
    data["conditions"] = conditionsData();
    ok = samePages(logger, pageIds(WeatherState.fromData(data)), [WeatherPages.ROWS, WeatherPages.TEMP, WeatherPages.UV, WeatherPages.DAYS] as Array<Number>) && ok;

    // no picture, no UV, no days
    var bare = conditionsData();
    bare["uv"] = null;
    bare["days"] = [];
    data["later"] = {"chance" => 40, "verdict" => "maybe"};
    data["conditions"] = bare;
    return samePages(logger, pageIds(WeatherState.fromData(data)), [WeatherPages.ROWS, WeatherPages.HOURS, WeatherPages.TEMP] as Array<Number>) && ok;
}

(:test)
function aWholeScreenProblemLeavesOnlyTheRows(logger as Logger) as Boolean {
    var noRain = {"chance" => null, "verdict" => "unknown", "reason" => "no_location"};
    var state = WeatherState.fromData(weatherData(noRain, noRain, null));
    return samePages(logger, pageIds(state), [WeatherPages.ROWS] as Array<Number>);
}

(:test)
function aFailedRefreshKeepsAnAnswerForThirtyMinutes(logger as Logger) as Boolean {
    var arrived = new Time.Moment(1700000000);
    var ok = WeatherText.keepsAfterFailure(arrived, new Time.Moment(1700000000 + 29 * 60));
    ok = !WeatherText.keepsAfterFailure(arrived, new Time.Moment(1700000000 + 31 * 60)) && ok;
    ok = !WeatherText.keepsAfterFailure(arrived, new Time.Moment(1700000000 + 30 * 60)) && ok;
    return ok && same(logger, WeatherText.staleNote(arrived), "not updated · " + AlarmTime.hhmm(arrived));
}

(:test)
function aRefreshThatKnowsNothingKeepsAYoungAnswer(logger as Logger) as Boolean {
    var good = stateWith(conditionsData());
    var noRain = {"chance" => null, "verdict" => "unknown", "reason" => "source_unavailable"};
    var data = weatherData(noRain, noRain, {"place" => "Aachen"});
    data["conditions"] = {"reason" => "source_unavailable", "symbol" => null, "night" => false, "temp_now" => null, "temp_min" => null,
        "temp_max" => null, "hours" => [], "uv" => null, "days" => []};
    var down = WeatherState.fromData(data);
    if (good == null || down == null) {
        return false;
    }
    var arrived = good.arrivedAt.value();
    var young = new Time.Moment(arrived + 29 * 60);
    var old = new Time.Moment(arrived + 31 * 60);
    var ok = WeatherText.keepsOver(good, down, young) && !WeatherText.keepsOver(good, down, old);
    // a failed request, an answer with something to show, nothing on screen, an answer that was itself empty
    ok = WeatherText.keepsOver(good, null, young) && !WeatherText.keepsOver(good, good, young) && ok;
    return ok && !WeatherText.keepsOver(null, down, young) && !WeatherText.keepsOver(down, down, young);
}
