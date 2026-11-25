import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;
import Toybox.Time;

// The Outbox with nothing in it and nothing sent: a running call holds every request back, so a
// test sees what the Outbox decides without a request going out.
(:test)
module OutboxKit {
    function fresh() as Void {
        clear();
        Outbox.loaded = true;
        Trace.active = true;
    }

    // Every report and part the test left goes, so the next test and the app's start find none.
    function clear() as Void {
        for (var i = 0; i < Outbox.reports.size(); i++) {
            var r = Outbox.reports[i];
            for (var k = 0; k < (r["parts"] as Number); k++) {
                Storage.deleteValue(Outbox.partKey(r["id"] as String, k));
            }
        }
        Outbox.reports = [];
        Outbox.held = {};
        Outbox.inFlight = null;
        Outbox.retryAt = 0;
        Outbox.loaded = false;
        Storage.deleteValue(Outbox.KEY);
        Trace.active = false;
    }

    function answer(next as Number?) as Outcome {
        var o = new Outcome(Outcome.OK);
        o.data = next == null ? {"id" => "r"} : {"next_part" => next.toFloat()};
        return o;
    }

    // The report's field holds the number n.
    function counts(report as Dictionary<String, Object?>?, key as String, n as Number) as Boolean {
        if (report == null) {
            return false;
        }
        var v = report[key];
        return v instanceof Number && v == n;
    }

    // What goes next for the report is [part, end].
    function goes(report as Dictionary<String, Object?>?, part as Number, end as Number) as Boolean {
        var step = report == null ? null : Outbox.next(report);
        return step != null && step[0] == part && step[1] == end;
    }

    function stored(id as String, n as Number) as Boolean {
        return Storage.getValue(Outbox.partKey(id, n)) instanceof ByteArray;
    }

    function report(id as String, parts as Number, sent as Number, done as Boolean) as Dictionary<String, Object?> {
        return {"id" => id, "feel" => null, "at" => 0, "tries" => 0, "parts" => parts, "sent" => sent, "done" => done} as Dictionary<String, Object?>;
    }
}

(:test)
function theNextRequestIsTheFirstMissingPartThenTheEnd(logger as Logger) as Boolean {
    var live = Outbox.next(OutboxKit.report("a", 2, 2, false)) == null;
    var middle = OutboxKit.goes(OutboxKit.report("a", 3, 1, false), 1, 0);
    var last = OutboxKit.goes(OutboxKit.report("a", 3, 2, true), 2, 1);
    var empty = OutboxKit.goes(OutboxKit.report("a", 3, 3, true), 3, 1);
    return live && middle && last && empty;
}

(:test)
function partsGoToStorageAsTheyComeAndTheEndFollows(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", "good", new Time.Moment(100));
    var a = Outbox.append("r", new [Outbox.PART_BYTES]b);
    var b = Outbox.append("r", new [Outbox.PART_BYTES]b);
    var report = Outbox.find("r") as Dictionary<String, Object?>;
    var live = OutboxKit.counts(report, "parts", 2) && !Outbox.isDone(report) && Outbox.ready();
    Outbox.finish("r", "good", new Time.Moment(100), [1, 2, 3]b, true);
    var stored = Storage.getValue(Outbox.partKey("r", 2));
    var list = Storage.getValue(Outbox.KEY);
    var ended = OutboxKit.counts(report, "parts", 3) && Outbox.isDone(report);
    var kept = stored instanceof ByteArray && stored.size() == 3;
    var listed = list instanceof Array && list.size() == 1;
    var ok = a == Outbox.APPEND_OK && b == Outbox.APPEND_OK && live && ended && kept && listed;
    OutboxKit.clear();
    return ok;
}

(:test)
function aShortRecordingBecomesAReportWhenItEnds(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.finish("s", null, new Time.Moment(100), [1, 2]b, false);
    var report = Outbox.find("s");
    var ok = OutboxKit.counts(report, "parts", 1) && OutboxKit.goes(report, 0, 1);
    OutboxKit.clear();
    return ok;
}

(:test)
function aConfirmedPartLeavesTheStorageAndTheNextFollows(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", null, new Time.Moment(100));
    Outbox.append("r", new [Outbox.PART_BYTES]b);
    Outbox.append("r", new [Outbox.PART_BYTES]b);
    Outbox.answered("r", 0, false, OutboxKit.answer(1));
    var report = Outbox.find("r");
    var freed = OutboxKit.counts(report, "sent", 1) && !OutboxKit.stored("r", 0);
    var ok = freed && OutboxKit.stored("r", 1) && Outbox.ready() && Outbox.stored() == Outbox.PART_BYTES;
    // a repeat the server already had: it answers its own count, which never goes back
    Outbox.answered("r", 0, false, OutboxKit.answer(0));
    var kept = OutboxKit.counts(report, "sent", 1);
    // a count beyond what was handed over is not believed past it
    Outbox.answered("r", 1, false, OutboxKit.answer(9));
    var capped = OutboxKit.counts(report, "sent", 2) && !Outbox.ready();
    OutboxKit.clear();
    return ok && kept && capped;
}

(:test)
function theServersAcceptanceOfTheEndForgetsTheReport(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.finish("r", null, new Time.Moment(100), [1]b, false);
    Outbox.answered("r", 0, true, OutboxKit.answer(null));
    var ok = !Outbox.holds("r") && !OutboxKit.stored("r", 0) && Storage.getValue(Outbox.KEY) == null;
    OutboxKit.clear();
    return ok;
}

(:test)
function aFailedPartStaysAndIsTriedAgainLater(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.finish("r", null, new Time.Moment(100), [1]b, false);
    var report = Outbox.find("r") as Dictionary<String, Object?>;
    report["tries"] = 1;
    Outbox.answered("r", 0, true, Outcome.failed("http_503"));
    var later = Outbox.retryAt > System.getTimer() + 20000;
    var ok = Outbox.holds("r") && later && OutboxKit.stored("r", 0);
    OutboxKit.clear();
    return ok;
}

(:test)
function theServersCapEndsTheReportWithWhatItHas(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", null, new Time.Moment(100));
    Outbox.append("r", new [Outbox.PART_BYTES]b);
    Outbox.append("r", new [Outbox.PART_BYTES]b);
    Outbox.answered("r", 0, false, OutboxKit.answer(1));
    Outbox.answered("r", 1, false, Outcome.failed("http_413"));
    var ends = OutboxKit.goes(Outbox.find("r"), 1, 1);
    var ok = ends && !OutboxKit.stored("r", 1) && Outbox.append("r", [1]b) == Outbox.APPEND_GONE;
    OutboxKit.clear();
    return ok;
}

(:test)
function aRefusedReportIsDroppedWithItsParts(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", null, new Time.Moment(100));
    Outbox.append("r", new [Outbox.PART_BYTES]b);
    Outbox.answered("r", 0, false, Outcome.failed("http_409"));
    var ok = !Outbox.holds("r") && !OutboxKit.stored("r", 0) && Outbox.append("r", [1]b) == Outbox.APPEND_GONE;
    OutboxKit.clear();
    return ok;
}

(:test)
function noRecordingStartsWhenTheBudgetHasNoRoomAndOneRunningStopsAtIt(logger as Logger) as Boolean {
    OutboxKit.fresh();
    var room = Outbox.hasRoom();
    // an older report holding all but three parts of the budget, in the list only
    Outbox.reports.add(OutboxKit.report("old", Outbox.BUDGET_BYTES / Outbox.PART_BYTES - 3, 0, true));
    var still = Outbox.hasRoom();
    Outbox.open("r", null, new Time.Moment(100));
    var first = Outbox.append("r", new [Outbox.PART_BYTES]b);
    var second = Outbox.append("r", new [Outbox.PART_BYTES]b);
    var none = !Outbox.hasRoom();
    Outbox.reports = Outbox.reports.slice(1, null) as Array<Dictionary<String, Object?>>;
    OutboxKit.clear();
    return room && still && first == Outbox.APPEND_OK && second == Outbox.APPEND_BUDGET && none;
}

(:test)
function aReportStoredByTheEarlierVersionGoesAsParts(logger as Logger) as Boolean {
    OutboxKit.clear();
    var id = "0f8fad5b-d9cb-469f-a165-70867728950e";
    Storage.setValue(Outbox.KEY, [{"id" => id, "feel" => "good", "at" => 100, "tries" => 2, "parts" => 2}] as Array<Storage.ValueType>);
    Storage.setValue(Outbox.partKey(id, 0), new [Outbox.PART_BYTES]b);
    Storage.setValue(Outbox.partKey(id, 1), [1, 2, 3]b);
    Outbox.load();
    var report = Outbox.find(id);
    var ok = OutboxKit.counts(report, "sent", 0) && OutboxKit.goes(report, 0, 0);
    if (ok) {
        Trace.active = true;
        Outbox.answered(id, 0, false, OutboxKit.answer(1));
        ok = OutboxKit.goes(report, 1, 1);
    }
    OutboxKit.clear();
    return ok;
}

(:test)
function aRecordingTheLastRunLeftRunningIsEndedAtLoad(logger as Logger) as Boolean {
    OutboxKit.clear();
    Storage.setValue(Outbox.KEY, [OutboxKit.report("r", 1, 0, false)] as Array<Storage.ValueType>);
    Storage.setValue(Outbox.partKey("r", 0), [1]b);
    Outbox.load();
    var ok = OutboxKit.goes(Outbox.find("r"), 0, 1) && Outbox.ready();
    OutboxKit.clear();
    return ok;
}

(:test)
function aPartTheStorageLostEndsTheReportThere(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.reports.add(OutboxKit.report("r", 3, 1, true));
    Storage.setValue(Outbox.partKey("r", 2), [1]b);
    // part 1 is missing: the request for it finds none, and the report ends before it
    Trace.active = false;
    Outbox.inFlight = null;
    Gate.open = false;
    Outbox.send();
    var ok = OutboxKit.goes(Outbox.find("r"), 1, 1) && !OutboxKit.stored("r", 2);
    var call = Outbox.inFlight;
    if (call != null) {
        call.cancel();
    }
    Gate.open = true;
    Gate.waiting = [];
    OutboxKit.clear();
    return ok;
}
