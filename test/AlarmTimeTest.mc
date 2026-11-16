import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

(:test)
function nextOccurrenceIsAheadOnTheWallClock(logger as Logger) as Boolean {
    var now = Time.now();
    for (var h = 0; h < 24; h += 5) {
        for (var m = 0; m < 60; m += 29) {
            var at = AlarmTime.nextOccurrence(now, h, m);
            var ahead = at.value() - now.value();
            if (ahead <= 0 || ahead > AlarmTime.DAY_SECONDS + 3600) {
                logger.debug("hour " + h + " minute " + m + " is " + ahead + " s ahead");
                return false;
            }
            if (AlarmTime.hour(at) != h || AlarmTime.minute(at) != m || AlarmTime.secondsOfDay(at) % 60 != 0) {
                logger.debug("hour " + h + " minute " + m + " lands on " + AlarmTime.hhmm(at));
                return false;
            }
        }
    }
    return true;
}

(:test)
function currentMinuteMovesToTomorrow(logger as Logger) as Boolean {
    var now = Time.now();
    var at = AlarmTime.nextOccurrence(now, AlarmTime.hour(now), AlarmTime.minute(now));
    return at.value() - now.value() > AlarmTime.DAY_SECONDS - 120;
}

(:test)
function theExactMinuteMovesToTomorrow(logger as Logger) as Boolean {
    var now = Time.now();
    var onTheMinute = new Time.Moment(now.value() - AlarmTime.secondsOfDay(now) % 60);
    var at = AlarmTime.nextOccurrence(onTheMinute, AlarmTime.hour(onTheMinute), AlarmTime.minute(onTheMinute));
    logger.debug("ahead " + (at.value() - onTheMinute.value()));
    return at.value() - onTheMinute.value() > AlarmTime.DAY_SECONDS - 3700;
}

(:test)
function isoWritesUtcWithOffset(logger as Logger) as Boolean {
    var text = AlarmTime.toIso(new Time.Moment(1700000000));
    logger.debug(text);
    return text.equals("2023-11-14T22:13:20+00:00");
}

(:test)
function isoRoundTrips(logger as Logger) as Boolean {
    var moment = new Time.Moment(1762761600 + 8 * 86400 + 9 * 3600 + 8 * 60 + 7);
    var parsed = AlarmTime.parseIso(AlarmTime.toIso(moment));
    return parsed != null && parsed.value() == moment.value();
}

(:test)
function isoReadsOffsetsFractionsAndZ(logger as Logger) as Boolean {
    var utc = AlarmTime.parseIso("2023-11-14T22:13:20+00:00");
    var zulu = AlarmTime.parseIso("2023-11-14T22:13:20Z");
    var shifted = AlarmTime.parseIso("2023-11-14T23:43:20+01:30");
    var behind = AlarmTime.parseIso("2023-11-14T20:13:20-02:00");
    var fraction = AlarmTime.parseIso("2023-11-14T22:13:20.123456+00:00");
    var bare = AlarmTime.parseIso("2023-11-14T22:13:20");
    var all = [utc, zulu, shifted, behind, fraction, bare] as Array<Time.Moment?>;
    for (var i = 0; i < all.size(); i++) {
        var one = all[i];
        if (one == null || one.value() != 1700000000) {
            logger.debug("variant " + i + " is " + (one == null ? "null" : one.value()));
            return false;
        }
    }
    return true;
}

(:test)
function isoRejectsGarbage(logger as Logger) as Boolean {
    return AlarmTime.parseIso("") == null && AlarmTime.parseIso("tomorrow") == null
        && AlarmTime.parseIso("2023-11-14 22:13:20") == null && AlarmTime.parseIso("2023-11-14T22:13:20+0x:00") == null;
}

(:test)
function dayLabelsCountFromToday(logger as Logger) as Boolean {
    var now = Time.now();
    var tomorrow = new Time.Moment(now.value() + AlarmTime.DAY_SECONDS);
    var later = new Time.Moment(now.value() + 3 * AlarmTime.DAY_SECONDS);
    return AlarmTime.dayLabel(now, now).equals("Today") && AlarmTime.dayLabel(tomorrow, now).equals("Tomorrow")
        && AlarmTime.dayLabel(later, now).length() == 3;
}
