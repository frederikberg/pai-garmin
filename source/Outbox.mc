import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Self-reports the server has not confirmed yet, kept on the watch in parts of PART_BYTES (a stored
// value holds at most 32 KB): a recording hands over a part as soon as its audio fills one, and the
// rest when it ends. The parts go one request at a time, in order, while the phone is there: at once,
// again by itself after a failure, and at the next start of the app; a part the server confirmed is
// deleted. The id stays the same, so a repeat is never counted twice. Nothing goes out while a
// Computer call runs.
module Outbox {
    const KEY = "outbox";
    const PART_BYTES = 16384;
    // What the parts may take in storage. The simulator gives these watches 10 MiB of app storage,
    // which the app itself is reported to count against; the rest stays for everything else the app
    // stores. A watch that has less says so with a full-storage error: the budget learned then
    // (BUDGET_KEY) holds for every recording after it.
    const BUDGET_BYTES = 8388608;
    const BUDGET_KEY = "outbox:budget";
    // A learned budget never goes below this, so a short recording can always start when none waits.
    const MIN_BUDGET_BYTES = 3 * PART_BYTES;
    // Two values held from the first recording on, deleted at the first full-storage error so the
    // recording's end, the list and the log still fit.
    const RESERVE_KEY = "outbox:reserve";
    const RESERVE_PARTS = 2;
    // the most reports kept (their list is one stored value); none starts beyond it
    const MAX_REPORTS = 20;
    // parts whose storage is freed are deleted a few at a time, so a long report never holds the watch
    const TRASH_KEY = "outbox:trash";
    const SWEEP_KEYS = 8;
    const SWEEP_MS = 200;
    // a storage write that took longer is always logged
    const SLOW_WRITE_MS = 200;

    enum {
        APPEND_OK,
        // the part is kept, and the budget has no room for another besides the recording's end
        APPEND_BUDGET,
        // the storage refused the part: the recording ends
        APPEND_DEVICE,
        // the report is over (refused, or the server's cap reached): it takes nothing more
        APPEND_GONE
    }

    // The reports waiting, oldest first: id, feel (or null), at (seconds), tries (attempts at the
    // part that goes next), parts (stored so far, in slots 0 to parts - 1), sent (parts the server
    // has), gaps (slots skipped because the storage lost them; they all lie before the next part, so
    // slot sent + gaps goes next, under the number sent) and done (the recording ended: its last part
    // ends the report). A report stored by an earlier version has no sent, gaps or done, which read
    // as 0, 0 and true.
    var reports as Array<Dictionary<String, Object?>> = [];
    // parts the storage did not take, by key, while this run holds them
    var held as Dictionary<String, ByteArray> = {};
    // slots whose storage is freed but not deleted yet, as [id, from, to)
    var trash as Array<Array<Object>> = [];
    var sweepJob as Number = 0;
    var loaded as Boolean = false;
    var budget as Number = BUDGET_BYTES;
    // how long the last part's storage write took
    var lastWriteMs as Number = 0;
    // the uptime clock before which no retry goes, after a failure
    var retryAt as Number = 0;
    var inFlight as Call? = null;
    // the screen waiting for the answer about its report, if any
    var listener as Method(outcome as Outcome) as Void or Null = null;
    var listenerId as String? = null;

    // The reports an earlier run left. Every one of them is done: a recording ends with the run
    // that made it. The part a confirmation may have left behind (sent is saved before the part is
    // deleted) goes, and so do the slots the last run did not get to delete.
    function load() as Void {
        if (loaded) {
            return;
        }
        loaded = true;
        var learned = Storage.getValue(BUDGET_KEY);
        if (learned instanceof Number && learned < budget) {
            budget = learned;
        }
        var bin = Storage.getValue(TRASH_KEY);
        if (bin instanceof Array) {
            for (var i = 0; i < bin.size(); i++) {
                if (bin[i] instanceof Array) {
                    trash.add(bin[i] as Array<Object>);
                }
            }
        }
        var value = Storage.getValue(KEY);
        if (value instanceof Array) {
            for (var i = 0; i < value.size(); i++) {
                var r = value[i];
                if (r instanceof Dictionary && r["id"] instanceof String && r["parts"] instanceof Number) {
                    var report = r as Dictionary<String, Object?>;
                    for (var f = 0; f < 3; f++) {
                        var field = ["sent", "gaps", "tries"][f];
                        if (!(report[field] instanceof Number)) {
                            report[field] = 0;
                        }
                    }
                    report["done"] = true;
                    var next = slot(report);
                    if (next > 0) {
                        Storage.deleteValue(partKey(report["id"] as String, next - 1));
                    }
                    reports.add(report);
                }
            }
        }
        if (trash.size() > 0) {
            sweepLater();
        }
    }

    // The slot that goes next.
    function slot(report as Dictionary<String, Object?>) as Number {
        return (report["sent"] as Number) + (report["gaps"] as Number);
    }

    function find(id as String) as Dictionary<String, Object?>? {
        for (var i = 0; i < reports.size(); i++) {
            if (id.equals(reports[i]["id"])) {
                return reports[i];
            }
        }
        return null;
    }

    function isDone(report as Dictionary<String, Object?>) as Boolean {
        var done = report["done"];
        return done instanceof Boolean && done;
    }

    function holds(id as String) as Boolean {
        return find(id) != null;
    }

    function pending() as Boolean {
        load();
        return reports.size() > 0;
    }

    // How many reports wait.
    function count() as Number {
        load();
        return reports.size();
    }

    // A part can go now: the oldest report has one, or its end.
    function ready() as Boolean {
        load();
        return reports.size() > 0 && next(reports[0]) != null;
    }

    // What goes next for a report, as [part, end (1 or 0)]: the first part the server lacks, ending
    // the report when it is its last; once the server has every part of a recording that ended, an
    // empty end. Null while a recording runs and its next part is not handed over yet.
    function next(report as Dictionary<String, Object?>) as [Number, Number] or Null {
        var sent = report["sent"] as Number;
        var at = slot(report);
        var parts = report["parts"] as Number;
        var done = isDone(report);
        if (at < parts) {
            return [sent, done && at == parts - 1 ? 1 : 0];
        }
        return done ? [sent, 1] : null;
    }

    // The parts of report id stored and not yet confirmed.
    function unsent(id as String) as Number {
        var report = find(id);
        return report == null ? 0 : (report["parts"] as Number) - slot(report);
    }

    // The bytes the parts not yet confirmed take, counting each as a full part.
    function stored() as Number {
        var n = 0;
        for (var i = 0; i < reports.size(); i++) {
            n += (reports[i]["parts"] as Number) - slot(reports[i]);
        }
        return n * PART_BYTES;
    }

    // A new recording may start: the list has a place and the budget room for two parts.
    function hasRoom() as Boolean {
        load();
        return reports.size() < MAX_REPORTS && stored() + 2 * PART_BYTES <= budget;
    }

    // A recording begins to hand over parts. The reserve is put aside first if it is missing.
    function open(id as String, feel as String?, at as Time.Moment) as Void {
        load();
        if (Storage.getValue(RESERVE_KEY) == null) {
            try {
                for (var i = 0; i < RESERVE_PARTS; i++) {
                    Storage.setValue(RESERVE_KEY + ":" + i, new [PART_BYTES]b);
                }
                Storage.setValue(RESERVE_KEY, RESERVE_PARTS);
            } catch (ex) {
            }
        }
        reports.add({"id" => id, "feel" => feel, "at" => at.value(), "tries" => 0, "parts" => 0, "sent" => 0, "gaps" => 0, "done" => false} as Dictionary<String, Object?>);
        changed();
    }

    // The next part of a running recording. The answer says whether it may go on: OK, or why not;
    // the part itself is kept in every case but GONE. Room is left for the recording's end.
    function append(id as String, bytes as ByteArray) as Number {
        var report = find(id);
        if (report == null || isDone(report)) {
            return APPEND_GONE;
        }
        if (!keep(report, bytes)) {
            return APPEND_DEVICE;
        }
        return stored() + 2 * PART_BYTES <= budget ? APPEND_OK : APPEND_BUDGET;
    }

    // The recording ended with tail as its last audio. A recording that never filled a part
    // (opened false) becomes a report now; one whose report is gone, or over, keeps nothing more.
    function finish(id as String, feel as String?, at as Time.Moment, tail as ByteArray, opened as Boolean) as Void {
        load();
        var report = find(id);
        if (report == null) {
            if (opened) {
                return;
            }
            open(id, feel, at);
            report = find(id);
        }
        if (report == null || isDone(report)) {
            return;
        }
        var parts = split(tail, PART_BYTES);
        for (var i = 0; i < parts.size(); i++) {
            keep(report, parts[i]);
        }
        report["done"] = true;
        try {
            save();
        } catch (ex) {
        }
    }

    // A part joins its report: the list first, so a part never sits in storage that no list names,
    // then the part. The first time the storage is full the reserve makes room for this part and
    // the recording's end; the answer is false then, and the recording stops. What the storage still
    // does not take stays in memory; a list that names a part the storage lacks skips it (send).
    function keep(report as Dictionary<String, Object?>, bytes as ByteArray) as Boolean {
        var id = report["id"] as String;
        var n = report["parts"] as Number;
        report["parts"] = n + 1;
        if (write(id, n, bytes)) {
            return true;
        }
        if (Storage.getValue(RESERVE_KEY) != null) {
            deviceFull();
            if (write(id, n, bytes)) {
                return false;
            }
        }
        held[partKey(id, n)] = bytes;
        return false;
    }

    function write(id as String, n as Number, bytes as ByteArray) as Boolean {
        var t0 = System.getTimer();
        try {
            save();
            Storage.setValue(partKey(id, n), bytes);
        } catch (ex) {
            lastWriteMs = System.getTimer() - t0;
            return false;
        }
        lastWriteMs = System.getTimer() - t0;
        var line = {"part" => n, "bytes" => bytes.size(), "ms" => lastWriteMs, "kept_bytes" => stored()};
        if (lastWriteMs > SLOW_WRITE_MS) {
            Trace.add("self_report_slow_write", line);
        } else {
            Trace.debug("self_report_stored", line);
        }
        return true;
    }

    // The storage refused a write: the reserve goes, and what the parts take now, less the
    // reserve, is the budget from here on.
    function deviceFull() as Void {
        var learned = stored() - RESERVE_PARTS * PART_BYTES;
        if (learned < MIN_BUDGET_BYTES) {
            learned = MIN_BUDGET_BYTES;
        }
        for (var i = 0; i < RESERVE_PARTS; i++) {
            Storage.deleteValue(RESERVE_KEY + ":" + i);
        }
        Storage.deleteValue(RESERVE_KEY);
        if (learned < budget) {
            budget = learned;
        }
        try {
            Storage.setValue(BUDGET_KEY, budget);
        } catch (ex) {
        }
    }

    function partOf(id as String, n as Number) as ByteArray? {
        var part = held[partKey(id, n)];
        if (part != null) {
            return part;
        }
        var value = Storage.getValue(partKey(id, n));
        return value instanceof ByteArray ? value : null;
    }

    // Asks for the next part at once when the phone is there and no retry is planned; else Idle
    // sends it when that changes.
    function kick() as Void {
        var wait = retryAt - System.getTimer();
        if (System.getDeviceSettings().phoneConnected && wait <= 0) {
            send();
        } else if (Idle.job == 0) {
            Idle.poke(wait > 0 ? wait : 5000);
        }
    }

    // Sends the next part of the oldest report now, unless a request for one is already out or a
    // call runs. A part the storage lost is skipped: the server gets the recording without it.
    function send() as Void {
        load();
        if (inFlight != null || reports.size() == 0) {
            return;
        }
        if (Trace.active) {
            // the call's end pokes Idle
            return;
        }
        var report = reports[0];
        var id = report["id"] as String;
        var step = next(report);
        var bytes = null;
        while (step != null && slot(report) < (report["parts"] as Number)) {
            bytes = partOf(id, slot(report));
            if (bytes != null) {
                break;
            }
            Trace.add("outbox_lost", {"id" => id, "part" => slot(report)});
            report["gaps"] = (report["gaps"] as Number) + 1;
            step = next(report);
        }
        if (step == null) {
            return;
        }
        var part = step[0];
        var end = step[1] == 1;
        var tries = report["tries"] as Number;
        report["tries"] = tries + 1;
        var call = new Call(new OutboxAnswer(id, part, end).method(:onAnswer));
        inFlight = call;
        call.send(Api.selfReport(id, part, end, report["feel"] as String?, new Time.Moment(report["at"] as Number), bytes, tries));
    }

    // The report ends with what the server has: what is stored after it is dropped, and the next
    // request is its end.
    function cut(report as Dictionary<String, Object?>) as Void {
        var at = slot(report);
        discard(report["id"] as String, at, report["parts"] as Number);
        report["parts"] = at;
        report["done"] = true;
        try {
            save();
        } catch (ex) {
        }
    }

    // The server's answer about part n of report id.
    function answered(id as String, part as Number, end as Boolean, outcome as Outcome) as Void {
        inFlight = null;
        var report = find(id);
        var data = outcome.data;
        var nextPart = Outcome.number(data != null ? data["next_part"] as Object? : null);
        var complete = data != null && data["complete"] instanceof Boolean && data["complete"] as Boolean;
        var ok = outcome.isOk();
        if (report == null) {
            // forgotten while the request was out: nothing to change
        } else if (ok && (complete || end)) {
            // the end was taken, or the server has the recording complete already
            Trace.add("self_report_sent", {"part" => part});
            forget(id);
        } else if (ok && nextPart != null) {
            // every 32nd part only, so a long report leaves room in the log for the rest
            var line = {"part" => part, "next" => nextPart, "tries" => (report["tries"] as Number) - 1};
            confirm(report, nextPart);
            if (part % 32 == 0) {
                Trace.add("self_report_part", line);
            } else {
                Trace.debug("self_report_part", line);
            }
        } else if (resumeAt(report, outcome)) {
            // the server lacks parts the watch already deleted: the rest goes on from its count, and
            // the screen hears no failure
            outcome = new Outcome(Outcome.OK);
        } else if ("http_413".equals(outcome.code)) {
            // the recording reached the server's cap: it ends with what the server has
            Trace.add("self_report_capped", {"part" => part});
            cut(report);
        } else if (refused(outcome)) {
            // the server will never take this one (bad audio or parameters): it would block the rest
            Trace.add("self_report_refused", {"code" => outcome.code, "part" => part});
            Idle.urgent = true;
            forget(id);
        } else {
            // an answer that says nothing about the parts counts as a failure, and so does any other status
            var code = ok ? "no_count" : outcome.code;
            Trace.add("self_report_failed", {"code" => code, "part" => part});
            Idle.urgent = true;
            try {
                save();
            } catch (ex) {
            }
            var wait = retryMs(outcome, report["tries"] as Number);
            retryAt = System.getTimer() + wait;
            Idle.poke(wait);
            if (ok) {
                outcome = Outcome.failed("no_count");
            }
        }
        // the screen hears about its own report, and about any failure, since its report waits behind it
        var l = listener;
        if (l != null && (id.equals(listenerId) || !outcome.isOk())) {
            l.invoke(outcome);
        }
        if (outcome.isOk() || "http_413".equals(outcome.code)) {
            // the next part goes straight after this one
            if (ready()) {
                send();
            }
        }
    }

    // The server has the parts before n: sent is saved first, then their storage is freed, so a
    // stop in between leaves at most one part, which the next load deletes. A number outside what
    // was handed over changes nothing.
    function confirm(report as Dictionary<String, Object?>, n as Number) as Void {
        var sent = report["sent"] as Number;
        var gaps = report["gaps"] as Number;
        var upTo = n + gaps < (report["parts"] as Number) ? n : (report["parts"] as Number) - gaps;
        if (upTo <= sent) {
            return;
        }
        report["sent"] = upTo;
        report["tries"] = 0;
        try {
            save();
        } catch (ex) {
        }
        var id = report["id"] as String;
        for (var k = sent + gaps; k < upTo + gaps; k++) {
            drop(id, k);
        }
    }

    // A gap (409) whose answer names the server's count m below the part sent: the watch deleted
    // the parts between when they were confirmed, so that slice is lost, and the next stored part
    // goes under the number m. Without the count the part is tried again like any failure.
    function resumeAt(report as Dictionary<String, Object?>, outcome as Outcome) as Boolean {
        if (!"http_409".equals(outcome.code)) {
            return false;
        }
        var body = outcome.body;
        var m = Outcome.number(body != null ? body["next_part"] as Object? : null);
        var sent = report["sent"] as Number;
        if (m == null || m < 0 || m >= sent) {
            return false;
        }
        Trace.add("outbox_gap", {"sent" => sent, "next" => m});
        report["gaps"] = (report["gaps"] as Number) + sent - m;
        report["sent"] = m;
        report["tries"] = 0;
        try {
            save();
        } catch (ex) {
        }
        return true;
    }

    // The next try: soon while only the phone link is missing (checking it sends nothing), later
    // when the server or the link failed, and longer with every failure in a row (an upload that
    // timed out may still be on its way), up to ten minutes.
    function retryMs(outcome as Outcome, failures as Number) as Number {
        if ("no_phone".equals(outcome.code)) {
            return 5000;
        }
        var wait = 30000;
        for (var i = 1; i < failures && wait < 600000; i++) {
            wait *= 2;
        }
        return wait < 600000 ? wait : 600000;
    }

    // The one status after which the server never takes the report: 422, bad audio or parameters.
    // Every other one is tried again, and the reports behind it wait.
    function refused(outcome as Outcome) as Boolean {
        return outcome.kind == Outcome.FAILED && "http_422".equals(outcome.code);
    }

    function drop(id as String, n as Number) as Void {
        held.remove(partKey(id, n));
        Storage.deleteValue(partKey(id, n));
    }

    function forget(id as String) as Void {
        for (var i = 0; i < reports.size(); i++) {
            if (id.equals(reports[i]["id"])) {
                discard(id, slot(reports[i]), reports[i]["parts"] as Number);
                reports = (reports.slice(0, i) as Array<Dictionary<String, Object?>>).addAll(reports.slice(i + 1, null));
                break;
            }
        }
        changed();
    }

    // Slots from to to of report id go: what this run holds at once, the stored ones a few at a time.
    function discard(id as String, from as Number, to as Number) as Void {
        for (var k = from; k < to; k++) {
            held.remove(partKey(id, k));
        }
        if (from < to) {
            trash.add([id, from, to] as Array<Object>);
            saveTrash();
            sweepLater();
        }
    }

    function sweepLater() as Void {
        if (sweepJob == 0) {
            sweepJob = Later.at(SWEEP_MS, new OutboxSweep().method(:run));
        }
    }

    // Deletes up to SWEEP_KEYS of the slots waiting, and comes back for the rest.
    function sweep() as Void {
        sweepJob = 0;
        var left = SWEEP_KEYS;
        while (left > 0 && trash.size() > 0) {
            var range = trash[0];
            var id = range[0] as String;
            var from = range[1] as Number;
            var to = range[2] as Number;
            while (left > 0 && from < to) {
                Storage.deleteValue(partKey(id, from));
                from += 1;
                left -= 1;
            }
            if (from < to) {
                range[1] = from;
            } else {
                trash = trash.slice(1, null) as Array<Array<Object>>;
            }
        }
        saveTrash();
        if (trash.size() > 0) {
            sweepLater();
        }
    }

    function saveTrash() as Void {
        try {
            if (trash.size() == 0) {
                Storage.deleteValue(TRASH_KEY);
            } else {
                Storage.setValue(TRASH_KEY, trash as Array<Storage.ValueType>);
            }
        } catch (ex) {
        }
    }

    // The list was saved after a report came or went, and the menu shows how many wait.
    function changed() as Void {
        try {
            save();
        } catch (ex) {
        }
        Home.showWaiting(reports.size());
    }

    function save() as Void {
        if (reports.size() == 0) {
            Storage.deleteValue(KEY);
        } else {
            Storage.setValue(KEY, reports as Array<Storage.ValueType>);
        }
    }

    function partKey(id as String, n as Number) as String {
        return KEY + ":" + id + ":" + n;
    }

    function split(bytes as ByteArray, size as Number) as Array<ByteArray> {
        var parts = [] as Array<ByteArray>;
        for (var at = 0; at < bytes.size(); at += size) {
            var end = at + size < bytes.size() ? at + size : bytes.size();
            parts.add(bytes.slice(at, end));
        }
        return parts;
    }
}

class OutboxSweep {
    function initialize() {
    }

    function run() as Void {
        Outbox.sweep();
    }
}

class OutboxAnswer {
    private var _id as String;
    private var _part as Number;
    private var _end as Boolean;

    function initialize(id as String, part as Number, end as Boolean) {
        _id = id;
        _part = part;
        _end = end;
    }

    function onAnswer(outcome as Outcome) as Void {
        Outbox.answered(_id, _part, _end, outcome);
    }
}

// Work that waits for a quiet moment: no request of the screen out, no call, no alarm check. Then a
// waiting self-report goes, or else the log lines the app has gathered, once a batch is full or a
// failure wants telling. Every answered request pokes it, so this follows a few seconds after one.
module Idle {
    const DELAY_MS = 3000;
    // lines a log request carries
    const LOG_BATCH = 20;

    // requests of the screen in flight (Call counts them)
    var busy as Number = 0;
    // the job in Later, 0 when none waits
    var job as Number = 0;
    // the uptime clock before which no log goes, after a failed one
    var logRetryAt as Number = 0;
    // a call began while a log request was out: its answer must not confirm lines the call took
    var logStale as Boolean = false;
    var logOut as Boolean = false;
    // a line worth sending soon was written (a failed upload): the log goes without waiting for a full batch
    var urgent as Boolean = false;
    var logBatch as Number = 0;

    function poke(ms as Number) as Void {
        Later.cancel(job);
        job = Later.at(ms, new IdleRun().method(:run));
    }

    function run() as Void {
        job = 0;
        if (busy > 0 || !Gate.open) {
            poke(DELAY_MS);
            return;
        }
        if (Trace.active) {
            // a call carries the log itself; its end pokes again
            return;
        }
        if (!System.getDeviceSettings().phoneConnected) {
            if (Outbox.ready()) {
                poke(5000);
            }
            return;
        }
        if (Outbox.ready()) {
            var wait = Outbox.retryAt - System.getTimer();
            if (wait <= 0) {
                Outbox.send();
                return;
            }
            poke(wait);
        }
        if (!logOut && System.getTimer() >= logRetryAt && (Trace.lines.size() >= LOG_BATCH || urgent && Trace.lines.size() > 0)) {
            urgent = false;
            sendLog();
        }
    }

    function sendLog() as Void {
        logOut = true;
        logStale = false;
        logBatch += 1;
        var count = Trace.lines.size() < LOG_BATCH ? Trace.lines.size() : LOG_BATCH;
        var lines = Trace.batch(count);
        var call = new Call(new IdleLog(count).method(:onAnswer));
        call.send(Api.appLog(logBatch, lines));
    }

    function logged(count as Number, outcome as Outcome) as Void {
        logOut = false;
        if (!outcome.isOk()) {
            logRetryAt = System.getTimer() + 60000;
            return;
        }
        // a call that began meanwhile carries the lines itself
        if (!Trace.active && !logStale) {
            Trace.confirm(count);
            if (Trace.lines.size() >= LOG_BATCH) {
                poke(DELAY_MS);
            }
        }
    }
}

class IdleRun {
    function initialize() {
    }

    function run() as Void {
        Idle.run();
    }
}

class IdleLog {
    private var _count as Number;

    function initialize(count as Number) {
        _count = count;
    }

    function onAnswer(outcome as Outcome) as Void {
        Idle.logged(_count, outcome);
    }
}
