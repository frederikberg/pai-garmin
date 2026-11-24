import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;

// One hour of the twelve: its temperature, symbol and UV index.
class HourSlot {
    var start as Time.Moment;
    var temp as Number;
    var symbol as String;
    var night as Boolean;
    var uv as Float?;

    function initialize(start as Time.Moment, temp as Number, symbol as String, night as Boolean, uv as Float?) {
        self.start = start;
        self.temp = temp;
        self.symbol = symbol;
        self.night = night;
        self.uv = uv;
    }
}

// One day of the daily page.
class DaySlot {
    var name as String;
    var symbol as String;
    var tempMax as Number;
    var tempMin as Number;
    var chance as Number?;

    function initialize(name as String, symbol as String, tempMax as Number, tempMin as Number, chance as Number?) {
        self.name = name;
        self.symbol = symbol;
        self.tempMax = tempMax;
        self.tempMin = tempMin;
        self.chance = chance;
    }
}

// The "conditions" block of the weather answer: the 12-hour symbol and temperatures, the UV
// index and the days ahead.
class Conditions {
    var reason as String? = "source_unavailable";
    var symbol as String = "cloudy";
    var night as Boolean = false;
    var tempNow as Number? = null;
    var tempMin as Number? = null;
    var tempMax as Number? = null;
    var hours as Array<HourSlot> = [] as Array<HourSlot>;
    var uvNow as Float? = null;
    var uvPeak as Float? = null;
    var uvPeakAt as Time.Moment? = null;
    var days as Array<DaySlot> = [] as Array<DaySlot>;

    function initialize() {
    }

    function known() as Boolean {
        return reason == null && tempMin != null && tempMax != null && hours.size() > 0;
    }

    // An answer without the block, or with a broken one, reads as unavailable.
    static function fromData(v as Object?) as Conditions {
        var c = new Conditions();
        if (!(v instanceof Dictionary)) {
            return c;
        }
        var reason = v["reason"] as Object?;
        c.reason = reason instanceof String ? reason : null;
        var symbol = v["symbol"] as Object?;
        c.symbol = symbol instanceof String ? symbol : "cloudy";
        var night = v["night"] as Object?;
        c.night = night instanceof Boolean && night;
        c.tempNow = whole(v["temp_now"] as Object?);
        c.tempMin = whole(v["temp_min"] as Object?);
        c.tempMax = whole(v["temp_max"] as Object?);
        var hours = v["hours"] as Object?;
        if (hours instanceof Array) {
            for (var i = 0; i < hours.size(); i++) {
                var h = hours[i] as Object?;
                if (!(h instanceof Dictionary)) {
                    continue;
                }
                var startText = h["start"] as Object?;
                var start = startText instanceof String ? AlarmTime.parseIso(startText) : null;
                var temp = whole(h["temp"] as Object?);
                var hs = h["symbol"] as Object?;
                var hn = h["night"] as Object?;
                var uv = decimal(h["uv"] as Object?);
                if (start != null && temp != null) {
                    c.hours.add(new HourSlot(start, temp, hs instanceof String ? hs : "cloudy", hn instanceof Boolean && hn, uv));
                }
            }
        }
        var uv = v["uv"] as Object?;
        if (uv instanceof Dictionary) {
            c.uvNow = decimal(uv["now"] as Object?);
            c.uvPeak = decimal(uv["peak"] as Object?);
            var at = uv["peak_at"] as Object?;
            c.uvPeakAt = at instanceof String ? AlarmTime.parseIso(at) : null;
        }
        var days = v["days"] as Object?;
        if (days instanceof Array) {
            for (var i = 0; i < days.size(); i++) {
                var d = days[i] as Object?;
                if (!(d instanceof Dictionary)) {
                    continue;
                }
                var date = d["date"] as Object?;
                var name = date instanceof String ? ConditionsText.dayName(date) : null;
                var max = whole(d["temp_max"] as Object?);
                var min = whole(d["temp_min"] as Object?);
                var ds = d["symbol"] as Object?;
                if (name != null && max != null && min != null) {
                    c.days.add(new DaySlot(name, ds instanceof String ? ds : "cloudy", max, min, whole(d["chance"] as Object?)));
                }
            }
        }
        return c;
    }

    // JSON numbers arrive as Number, Float or Double; halves round away from zero.
    private static function whole(v as Object?) as Number? {
        if (v instanceof Number) {
            return v;
        } else if (v instanceof Float || v instanceof Double) {
            return (v < 0 ? v - 0.5 : v + 0.5).toNumber();
        }
        return null;
    }

    private static function decimal(v as Object?) as Float? {
        if (v instanceof Number || v instanceof Float || v instanceof Double) {
            return v.toFloat();
        }
        return null;
    }
}

// The words and colours of the conditions pages, apart from their drawing.
module ConditionsText {
    const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MONTH_SHIFT = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];

    function degrees(t as Number) as String {
        return t + "°";
    }

    // "Tue" for "2026-11-24", null for anything that is not a date.
    function dayName(date as String) as String? {
        if (date.length() != 10) {
            return null;
        }
        var y = AlarmTime.number(date, 0, 4);
        var m = AlarmTime.number(date, 5, 7);
        var d = AlarmTime.number(date, 8, 10);
        if (y == null || m == null || d == null || m < 1 || m > 12) {
            return null;
        }
        return DAYS[weekday(y, m, d)];
    }

    // 0 for Sunday to 6 for Saturday.
    function weekday(y as Number, m as Number, d as Number) as Number {
        if (m < 3) {
            y -= 1;
        }
        return (y + y / 4 - y / 100 + y / 400 + MONTH_SHIFT[m - 1] + d) % 7;
    }

    function uvWhole(uv as Float) as Number {
        return (uv + 0.5).toNumber();
    }

    function uvBand(uv as Float) as String {
        var n = uvWhole(uv);
        return n >= 11 ? "extreme" : n >= 8 ? "very high" : n >= 6 ? "high" : n >= 3 ? "moderate" : n >= 1 ? "low" : "none";
    }

    function uvColor(uv as Float) as Graphics.ColorType {
        var n = uvWhole(uv);
        return n >= 11 ? 0xFF00FF : n >= 8 ? 0xFF0000 : n >= 6 ? 0xFFAA00 : n >= 3 ? 0xFFFF00 : 0x00FF00;
    }

    function uvLine(c as Conditions) as String {
        var now = c.uvNow;
        return now == null ? "UV -" : "UV " + uvWhole(now) + " · " + uvBand(now);
    }

    function uvCaption(c as Conditions) as String {
        var peak = c.uvPeak;
        var at = c.uvPeakAt;
        if (peak == null || at == null || uvWhole(peak) == 0) {
            return "no UV in the next 12 h";
        }
        return "peak " + uvWhole(peak) + " at " + AlarmTime.hhmm(at);
    }
}
