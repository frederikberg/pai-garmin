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
        swept();
        Later.cancel(Outbox.sweepJob);
        Outbox.sweepJob = 0;
        for (var i = 0; i < Outbox.RESERVE_PARTS; i++) {
            Storage.deleteValue(Outbox.RESERVE_KEY + ":" + i);
        }
        Storage.deleteValue(Outbox.RESERVE_KEY);
        Storage.deleteValue(Outbox.BUDGET_KEY);
        Outbox.budget = Outbox.BUDGET_BYTES;
        Outbox.reports = [];
        Outbox.held = {};
        Outbox.inFlight = null;
        Outbox.retryAt = 0;
        Outbox.loaded = false;
        Storage.deleteValue(Outbox.KEY);
        Trace.active = false;
    }

    // Every deletion waiting is done.
    function swept() as Void {
        for (var i = 0; i < 1000 && Outbox.trash.size() > 0; i++) {
            Outbox.sweep();
        }
    }

    // The server has the recording complete.
    function complete() as Outcome {
        var o = new Outcome(Outcome.OK);
        o.data = {"id" => "r", "complete" => true};
        return o;
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
        return {"id" => id, "feel" => null, "at" => 0, "tries" => 0, "parts" => parts, "sent" => sent, "gaps" => 0, "done" => done} as Dictionary<String, Object?>;
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
    Outbox.answered("r", 0, true, OutboxKit.complete());
    OutboxKit.swept();
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
    OutboxKit.swept();
    var ends = OutboxKit.goes(Outbox.find("r"), 1, 1);
    var ok = ends && !OutboxKit.stored("r", 1) && Outbox.append("r", [1]b) == Outbox.APPEND_GONE;
    OutboxKit.clear();
    return ok;
}

(:test)
function onlyA422DropsAReportWithItsParts(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", null, new Time.Moment(100));
    Outbox.append("r", new [Outbox.PART_BYTES]b);
    // any other refusal is tried again, and nothing is lost meanwhile
    Outbox.answered("r", 0, false, Outcome.failed("http_409"));
    Outbox.answered("r", 0, false, Outcome.failed("http_403"));
    Outbox.answered("r", 0, false, Outcome.failed("http_400"));
    var kept = Outbox.holds("r") && OutboxKit.stored("r", 0) && Outbox.retryAt > System.getTimer();
    Outbox.answered("r", 0, false, Outcome.failed("http_422"));
    OutboxKit.swept();
    var ok = kept && !Outbox.holds("r") && !OutboxKit.stored("r", 0) && Outbox.append("r", [1]b) == Outbox.APPEND_GONE;
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
function aPartTheStorageLostIsSkippedAndTheOnesAfterItStillGo(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.reports.add(OutboxKit.report("r", 4, 1, true));
    Storage.setValue(Outbox.partKey("r", 2), [1]b);
    Storage.setValue(Outbox.partKey("r", 3), [2]b);
    // slot 1 is missing: the request goes with slot 2 under the number 1
    Trace.active = false;
    Outbox.inFlight = null;
    Gate.open = false;
    Outbox.send();
    var report = Outbox.find("r");
    var skipped = OutboxKit.goes(report, 1, 0) && OutboxKit.counts(report, "gaps", 1) && OutboxKit.stored("r", 2);
    var call = Outbox.inFlight;
    if (call != null) {
        call.cancel();
    }
    Outbox.inFlight = null;
    Trace.active = true;
    // the server has it: slot 2 goes, slot 3 is the last part, number 2
    Outbox.answered("r", 1, false, OutboxKit.answer(2));
    var ok = skipped && !OutboxKit.stored("r", 2) && OutboxKit.goes(report, 2, 1) && Outbox.unsent("r") == 1;
    Gate.open = true;
    Gate.waiting = [];
    OutboxKit.clear();
    return ok;
}

(:test)
function aPartAnswerWithoutACountIsNotTheEnd(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", null, new Time.Moment(100));
    Outbox.append("r", new [Outbox.PART_BYTES]b);
    Outbox.answered("r", 0, false, OutboxKit.answer(null));
    var kept = Outbox.holds("r") && OutboxKit.stored("r", 0) && Outbox.retryAt > System.getTimer();
    // the server says the recording is complete already: the rest is dropped
    var done = new Outcome(Outcome.OK);
    done.data = {"id" => "r", "complete" => true};
    Outbox.answered("r", 0, false, done);
    OutboxKit.swept();
    var ok = kept && !Outbox.holds("r") && !OutboxKit.stored("r", 0);
    OutboxKit.clear();
    return ok;
}

(:test)
function aConfirmationLeavesNoPartBehindAfterALoad(logger as Logger) as Boolean {
    OutboxKit.clear();
    // the list says the server has part 0, but the run stopped before deleting it
    Storage.setValue(Outbox.KEY, [OutboxKit.report("r", 2, 1, true)] as Array<Storage.ValueType>);
    Storage.setValue(Outbox.partKey("r", 0), [1]b);
    Storage.setValue(Outbox.partKey("r", 1), [2]b);
    Outbox.load();
    var ok = !OutboxKit.stored("r", 0) && OutboxKit.stored("r", 1) && OutboxKit.goes(Outbox.find("r"), 1, 1);
    OutboxKit.clear();
    return ok;
}

(:test)
function aForgottenReportsPartsGoAFewAtATime(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.reports.add(OutboxKit.report("r", 3 * Outbox.SWEEP_KEYS, 0, true));
    for (var k = 0; k < 3 * Outbox.SWEEP_KEYS; k++) {
        Storage.setValue(Outbox.partKey("r", k), [1]b);
    }
    Outbox.forget("r");
    var waits = OutboxKit.stored("r", 0) && Outbox.trash.size() == 1;
    Outbox.sweep();
    var some = !OutboxKit.stored("r", Outbox.SWEEP_KEYS - 1) && OutboxKit.stored("r", Outbox.SWEEP_KEYS);
    // what the run did not get to is deleted after the next load
    Outbox.loaded = false;
    Outbox.trash = [];
    Outbox.load();
    OutboxKit.swept();
    var all = !OutboxKit.stored("r", 3 * Outbox.SWEEP_KEYS - 1) && Storage.getValue(Outbox.TRASH_KEY) == null;
    OutboxKit.clear();
    return waits && some && all;
}

(:test)
function theFirstFullStorageFreesTheReserveAndTeachesTheBudget(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", null, new Time.Moment(100));
    var reserved = Storage.getValue(Outbox.RESERVE_KEY) != null && Storage.getValue(Outbox.RESERVE_KEY + ":0") instanceof ByteArray;
    Outbox.reports.add(OutboxKit.report("old", 10, 0, true));
    Outbox.deviceFull(true);
    var freed = Storage.getValue(Outbox.RESERVE_KEY) == null && Storage.getValue(Outbox.RESERVE_KEY + ":1") == null;
    var learned = Storage.getValue(Outbox.BUDGET_KEY);
    var taught = learned instanceof Number && learned == (10 - Outbox.RESERVE_PARTS) * Outbox.PART_BYTES && Outbox.budget == learned;
    // the next run starts from what was learned
    Outbox.reports = [];
    Outbox.budget = Outbox.BUDGET_BYTES;
    Outbox.loaded = false;
    Storage.deleteValue(Outbox.KEY);
    Outbox.load();
    var kept = Outbox.budget == (10 - Outbox.RESERVE_PARTS) * Outbox.PART_BYTES;
    OutboxKit.clear();
    return reserved && freed && taught && kept;
}

(:test)
function theMenuSaysHowManyRecordingsWait(logger as Logger) as Boolean {
    var none = Home.waitingLabel(0) == null;
    var one = Home.waitingLabel(1);
    return none && one != null && one.equals("1 waiting");
}

(:test)
function aGapGoesOnFromTheServersCountWithTheNextStoredPart(logger as Logger) as Boolean {
    OutboxKit.fresh();
    // the server has confirmed 3 parts, the watch deleted them, then the server lost the last two
    Outbox.reports.add(OutboxKit.report("r", 5, 3, true));
    Storage.setValue(Outbox.partKey("r", 3), [1]b);
    Storage.setValue(Outbox.partKey("r", 4), [2]b);
    var bare = Outcome.failed("http_409");
    // without its body the gap is tried again later
    Outbox.answered("r", 3, false, bare);
    var report = Outbox.find("r");
    var waits = OutboxKit.counts(report, "sent", 3) && Outbox.retryAt > System.getTimer();
    var gap = Outcome.failed("http_409");
    gap.body = {"next_part" => 1.0};
    Outbox.answered("r", 3, false, gap);
    // slot 3 goes next under the number 1, slot 4 as number 2 ends the report
    var ok = waits && OutboxKit.goes(report, 1, 0) && OutboxKit.stored("r", 3) && OutboxKit.counts(report, "gaps", 2);
    Outbox.answered("r", 1, false, OutboxKit.answer(2));
    ok = ok && OutboxKit.goes(report, 2, 1) && !OutboxKit.stored("r", 3);
    OutboxKit.clear();
    return ok;
}

(:test)
function aRepeatedLastPartTheServerOnlyCountsIsFollowedByTheEnd(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.finish("r", null, new Time.Moment(100), [1]b, false);
    // the server had the part already and ignores its end: it answers its count
    Outbox.answered("r", 0, true, OutboxKit.answer(1));
    var report = Outbox.find("r");
    var ok = Outbox.holds("r") && OutboxKit.goes(report, 1, 1) && !OutboxKit.stored("r", 0);
    Outbox.answered("r", 1, true, OutboxKit.complete());
    ok = ok && !Outbox.holds("r");
    OutboxKit.clear();
    return ok;
}

(:test)
function aServerThatLostTheWholeRecordingDropsIt(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.reports.add(OutboxKit.report("r", 4, 2, true));
    Storage.setValue(Outbox.partKey("r", 2), [1]b);
    Storage.setValue(Outbox.partKey("r", 3), [2]b);
    var lost = Outcome.failed("http_409");
    lost.body = {"next_part" => 0.0};
    Outbox.answered("r", 2, false, lost);
    OutboxKit.swept();
    var ok = !Outbox.holds("r") && !OutboxKit.stored("r", 2) && !OutboxKit.stored("r", 3);
    OutboxKit.clear();
    return ok;
}

(:test)
function aFullStorageWithPartsStillToDeleteTeachesNoBudget(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.open("r", null, new Time.Moment(100));
    Outbox.reports.add(OutboxKit.report("old", 10, 0, true));
    Outbox.deviceFull(false);
    var ok = Storage.getValue(Outbox.RESERVE_KEY) == null && Storage.getValue(Outbox.BUDGET_KEY) == null && Outbox.budget == Outbox.BUDGET_BYTES;
    OutboxKit.clear();
    return ok;
}

(:test)
function aRecordingPastTheLearnedBudgetWithoutAnErrorClearsIt(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.budget = 4 * Outbox.PART_BYTES;
    Storage.setValue(Outbox.BUDGET_KEY, Outbox.budget);
    Outbox.open("r", null, new Time.Moment(100));
    var codes = [] as Array<Number>;
    for (var i = 0; i < 5; i++) {
        codes.add(Outbox.append("r", new [16]b));
    }
    // the reserve covers the end, so the learned budget is tried one part further, and that part went in
    var goes = codes[2] == Outbox.APPEND_OK && codes[3] == Outbox.APPEND_OK && codes[4] == Outbox.APPEND_OK;
    var ok = goes && Outbox.budget == Outbox.BUDGET_BYTES && Storage.getValue(Outbox.BUDGET_KEY) == null;
    OutboxKit.clear();
    return ok;
}

(:test)
function aReportFailingForDaysGoesBehindTheOthers(logger as Logger) as Boolean {
    OutboxKit.fresh();
    Outbox.reports.add(OutboxKit.report("a", 1, 0, true));
    Outbox.reports.add(OutboxKit.report("b", 1, 0, true));
    Storage.setValue(Outbox.partKey("a", 0), [1]b);
    Outbox.answered("a", 0, true, Outcome.failed("http_409"));
    var first = Outbox.reports[0]["id"];
    var stays = first instanceof String && first.equals("a");
    Outbox.reports[0]["failing_since"] = Time.now().value() - Outbox.STUCK_S;
    Outbox.answered("a", 0, true, Outcome.failed("http_409"));
    var head = Outbox.reports[0]["id"];
    var last = Outbox.reports[1]["id"];
    var moved = head instanceof String && head.equals("b") && last instanceof String && last.equals("a");
    OutboxKit.clear();
    return stays && moved;
}
