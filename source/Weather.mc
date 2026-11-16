import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;

// How sure the server is that it rains, as one of its verdict words.
module Verdict {
    function color(verdict as String) as Graphics.ColorType {
        if (verdict.equals("rain")) {
            return 0x55AAFF;
        } else if (verdict.equals("maybe")) {
            return Graphics.COLOR_YELLOW;
        } else if (verdict.equals("unlikely") || verdict.equals("dry")) {
            return Graphics.COLOR_GREEN;
        }
        return Graphics.COLOR_LT_GRAY;
    }
}

// One half of the weather answer: the next hour ("now") or the next twelve hours ("later").
class Outlook {
    var chance as Number?;
    var verdict as String;
    // when the rain starts (now: first radar frame with rain, later: most likely start)
    var at as Time.Moment?;
    var reason as String?;

    function initialize(chance as Number?, verdict as String, at as Time.Moment?, reason as String?) {
        self.chance = chance;
        self.verdict = verdict;
        self.at = at;
        self.reason = reason;
    }

    // Whether the server could answer this half at all.
    function known() as Boolean {
        return chance != null && reason == null && !verdict.equals("unknown");
    }
}

// The next hour from the radar, with the details the caption needs.
class NowOutlook extends Outlook {
    var rainingNow as Boolean;
    var endsAt as Time.Moment?;
    var nearestKm as Number?;
    var direction as String?;
    var trend as String?;
    var radar as Boolean;

    function initialize(base as Outlook, rainingNow as Boolean, endsAt as Time.Moment?, nearestKm as Number?, direction as String?, trend as String?, radar as Boolean) {
        Outlook.initialize(base.chance, base.verdict, base.at, base.reason);
        self.rainingNow = rainingNow;
        self.endsAt = endsAt;
        self.nearestKm = nearestKm;
        self.direction = direction;
        self.trend = trend;
        self.radar = radar;
    }
}

// The answer of GET /api/watch/weather, as far as the watch shows it.
class WeatherState {
    var now as NowOutlook;
    var later as Outlook;
    // null when the server has no location for the person
    var place as String?;
    var located as Boolean;
    var recordedAt as Time.Moment?;

    function initialize(now as NowOutlook, later as Outlook, located as Boolean, place as String?, recordedAt as Time.Moment?) {
        self.now = now;
        self.later = later;
        self.located = located;
        self.place = place;
        self.recordedAt = recordedAt;
    }

    // Null for an answer without the two halves.
    static function fromData(data as Dictionary) as WeatherState? {
        var now = data["now"] as Object?;
        var later = data["later"] as Object?;
        if (!(now instanceof Dictionary) || !(later instanceof Dictionary)) {
            return null;
        }
        var location = data["location"] as Object?;
        var place = null;
        var recordedAt = null;
        if (location instanceof Dictionary) {
            var p = location["place"] as Object?;
            place = p instanceof String && p.length() > 0 ? p : null;
            recordedAt = moment(location["recorded_at"] as Object?);
        }
        var nowOutlook = new NowOutlook(outlook(now, "starts_at"), flag(now["raining_now"] as Object?), moment(now["ends_at"] as Object?),
            number(now["nearest_km"] as Object?), text(now["direction"] as Object?), text(now["trend"] as Object?),
            !"forecast".equals(text(now["method"] as Object?)));
        return new WeatherState(nowOutlook, outlook(later, "at"), location instanceof Dictionary, place, recordedAt);
    }

    // timeKey names where the half keeps the time the rain begins
    private static function outlook(d as Dictionary, timeKey as String) as Outlook {
        var verdict = text(d["verdict"] as Object?);
        return new Outlook(number(d["chance"] as Object?), verdict == null ? "unknown" : verdict, moment(d[timeKey] as Object?), text(d["reason"] as Object?));
    }

    private static function flag(v as Object?) as Boolean {
        return v instanceof Boolean && v;
    }

    private static function text(v as Object?) as String? {
        return v instanceof String ? v : null;
    }

    // JSON numbers arrive as Number, Float or Double.
    private static function number(v as Object?) as Number? {
        if (v instanceof Number) {
            return v;
        } else if (v instanceof Float || v instanceof Double) {
            return (v + 0.5).toNumber();
        }
        return null;
    }

    private static function moment(v as Object?) as Time.Moment? {
        return v instanceof String ? AlarmTime.parseIso(v) : null;
    }
}

// The words of the weather screen, apart from its drawing.
module WeatherText {
    // "Now 70 % · 15:20": the chance, and when the rain starts if it is not already raining.
    function nowLine(now as NowOutlook) as String {
        var line = "Now " + chance(now);
        if (now.known() && now.at != null && !now.rainingNow) {
            line += " · " + AlarmTime.hhmm(now.at as Time.Moment);
        }
        return line;
    }

    function laterLine(later as Outlook) as String {
        var line = "Later " + chance(later);
        if (later.known() && later.at != null) {
            line += " · " + AlarmTime.hhmm(later.at as Time.Moment);
        }
        return line;
    }

    function nowCaption(now as NowOutlook) as String {
        if (!now.known()) {
            return reasonText(now);
        }
        if (now.rainingNow) {
            var ends = now.endsAt;
            return ends == null ? "raining now" : "raining now, until " + AlarmTime.hhmm(ends);
        }
        var km = now.nearestKm;
        if (km != null) {
            var dir = now.direction;
            var trend = now.trend;
            return km + " km" + (dir == null ? " away" : " " + dir)
                + ("approaching".equals(trend) ? ", closing in" : "passing".equals(trend) ? ", passing" : "leaving".equals(trend) ? ", moving off" : "");
        }
        return now.radar ? "dry around you" : "forecast only";
    }

    function laterCaption(later as Outlook) as String {
        if (!later.known()) {
            return reasonText(later);
        }
        if (later.verdict.equals("rain")) {
            return "rain likely";
        } else if (later.verdict.equals("maybe")) {
            return "rain possible";
        } else if (later.verdict.equals("unlikely")) {
            return "rain unlikely";
        }
        return "dry all day";
    }

    // The footer: place and how old the stored location is.
    function footer(state as WeatherState, nowMoment as Time.Moment) as String {
        var place = state.place;
        var recorded = state.recordedAt;
        if (recorded == null) {
            return place == null ? "" : place;
        }
        var age = age(nowMoment.value() - recorded.value());
        return place == null ? age : place + " · " + age;
    }

    function age(seconds as Number) as String {
        if (seconds < 120) {
            return "just now";
        } else if (seconds < 3600) {
            return seconds / 60 + " min ago";
        } else if (seconds < 86400) {
            return seconds / 3600 + " h ago";
        }
        return seconds / 86400 + " d ago";
    }

    // What the whole screen says when neither half has an answer; null when at least one does.
    function problem(state as WeatherState) as String? {
        if (state.now.known() || state.later.known()) {
            return null;
        }
        if (!state.located || "no_location".equals(state.now.reason) || "no_location".equals(state.later.reason)) {
            return "No location yet. Pick your iPhone in PAI Settings > Location";
        }
        return "The weather source is not answering. Try again in a minute";
    }

    function chance(o as Outlook) as String {
        var c = o.chance;
        return c == null ? "-" : c + " %";
    }

    function reasonText(o as Outlook) as String {
        return "no_location".equals(o.reason) ? "no location" : "no answer";
    }
}
