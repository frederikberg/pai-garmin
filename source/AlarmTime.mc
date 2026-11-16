import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;

// Alarm times: picked as hour and minute on the watch, sent to the server as UTC, shown in local time.
(:glance)
module AlarmTime {
    const DAY_SECONDS = 86400;

    // The next time the local clock shows hour:minute, counted from now: today when still ahead,
    // otherwise tomorrow.
    function nextOccurrence(now as Time.Moment, hour as Number, minute as Number) as Time.Moment {
        var target = hour * 3600 + minute * 60;
        var delta = target - secondsOfDay(now);
        if (delta <= 0) {
            delta += DAY_SECONDS;
        }
        var fire = now.value() + delta;
        // a day that is not 24 hours long (clock change) lands off the wall time: move it back onto it
        var drift = target - secondsOfDay(new Time.Moment(fire));
        if (drift > DAY_SECONDS / 2) {
            drift -= DAY_SECONDS;
        } else if (drift < -DAY_SECONDS / 2) {
            drift += DAY_SECONDS;
        }
        return new Time.Moment(fire + drift > now.value() ? fire + drift : fire);
    }

    function secondsOfDay(moment as Time.Moment) as Number {
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        return info.hour * 3600 + info.min * 60 + info.sec;
    }

    function hour(moment as Time.Moment) as Number {
        return Gregorian.info(moment, Time.FORMAT_SHORT).hour;
    }

    function minute(moment as Time.Moment) as Number {
        return Gregorian.info(moment, Time.FORMAT_SHORT).min;
    }

    // Local time of day, 24 hour clock.
    function hhmm(moment as Time.Moment) as String {
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        return (info.hour as Number).format("%02d") + ":" + (info.min as Number).format("%02d");
    }

    // "Today", "Tomorrow" or the weekday abbreviation.
    function dayLabel(moment as Time.Moment, now as Time.Moment) as String {
        var day = Gregorian.info(moment, Time.FORMAT_SHORT);
        if (sameDay(day, Gregorian.info(now, Time.FORMAT_SHORT))) {
            return "Today";
        }
        if (sameDay(day, Gregorian.info(new Time.Moment(now.value() + DAY_SECONDS), Time.FORMAT_SHORT))) {
            return "Tomorrow";
        }
        return Gregorian.info(moment, Time.FORMAT_MEDIUM).day_of_week as String;
    }

    function sameDay(a as Gregorian.Info, b as Gregorian.Info) as Boolean {
        return a.year == b.year && a.month == b.month && a.day == b.day;
    }

    // ISO 8601 in UTC with an explicit offset, the form the server takes.
    function toIso(moment as Time.Moment) as String {
        var i = Gregorian.utcInfo(moment, Time.FORMAT_SHORT);
        return (i.year as Number).format("%04d") + "-" + (i.month as Number).format("%02d") + "-" + (i.day as Number).format("%02d")
            + "T" + (i.hour as Number).format("%02d") + ":" + (i.min as Number).format("%02d") + ":" + (i.sec as Number).format("%02d") + "+00:00";
    }

    // Reads YYYY-MM-DDTHH:MM:SS followed by an optional fraction and Z or +HH:MM / -HH:MM. A text
    // without an offset counts as UTC. Null when the text is not a timestamp.
    function parseIso(text as String) as Time.Moment? {
        if (text.length() < 19 || !"--T::".equals(charAt(text, 4) + charAt(text, 7) + charAt(text, 10) + charAt(text, 13) + charAt(text, 16))) {
            return null;
        }
        var year = number(text, 0, 4);
        var month = number(text, 5, 7);
        var day = number(text, 8, 10);
        var hour = number(text, 11, 13);
        var minute = number(text, 14, 16);
        var second = number(text, 17, 19);
        if (year == null || month == null || day == null || hour == null || minute == null || second == null) {
            return null;
        }
        var utc = Gregorian.moment({:year => year, :month => month, :day => day, :hour => hour, :minute => minute, :second => second});
        var at = 19;
        if (charAt(text, at).equals(".")) {
            at += 1;
            while (isDigit(text, at)) {
                at += 1;
            }
        }
        var sign = charAt(text, at);
        if (!sign.equals("+") && !sign.equals("-")) {
            return utc;
        }
        var offsetHour = number(text, at + 1, at + 3);
        var offsetMinute = number(text, at + 4, at + 6);
        if (offsetHour == null || offsetMinute == null) {
            return null;
        }
        var offset = offsetHour * 3600 + offsetMinute * 60;
        return new Time.Moment(utc.value() - (sign.equals("+") ? offset : -offset));
    }

    function charAt(text as String, index as Number) as String {
        return index < text.length() ? text.substring(index, index + 1) as String : "";
    }

    function isDigit(text as String, index as Number) as Boolean {
        return index < text.length() && text.toCharArray()[index] >= '0' && text.toCharArray()[index] <= '9';
    }

    function number(text as String, from as Number, to as Number) as Number? {
        for (var i = from; i < to; i++) {
            if (!isDigit(text, i)) {
                return null;
            }
        }
        return (text.substring(from, to) as String).toNumber();
    }
}
