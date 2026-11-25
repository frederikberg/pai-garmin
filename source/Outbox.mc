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
    // stores. A watch that has less says so with a full-storage error, which ends the recording too.
    const BUDGET_BYTES = 8388608;
    // the most reports kept (their list is one stored value); none starts beyond it
    const MAX_REPORTS = 20;
    // the server decodes the whole recording before it answers the last part (docs/api.md)
    const END_TIMEOUT_MS = 60000;

    enum {
        APPEND_OK,
        // the part is kept, and the budget has no room for another besides the recording's end
        APPEND_BUDGET,
        // the storage refused the part: it is kept only while the app runs
        APPEND_DEVICE,
        // the report is over (refused, or the server's cap reached): it takes nothing more
        APPEND_GONE
    }

    // The reports waiting, oldest first: id, feel (or null), at (seconds), tries (attempts at the
    // part that goes next), parts (handed over so far), sent (parts the server has, whose storage is
    // freed) and done (the recording ended: its last part ends the report). A report stored by an
    // earlier version has no sent and no done, which read as 0 and true.
    var reports as Array<Dictionary<String, Object?>> = [];
    // parts the storage did not take, by key, while this run holds them
    var held as Dictionary<String, ByteArray> = {};
    var loaded as Boolean = false;
    // the uptime clock before which no retry goes, after a failure
    var retryAt as Number = 0;
    var inFlight as Call? = null;
    // the screen waiting for the answer about its report, if any
    var listener as Method(outcome as Outcome) as Void or Null = null;
    var listenerId as String? = null;

    // The reports an earlier run left. Every one of them is done: a recording ends with the run
    // that made it.
    function load() as Void {
        if (loaded) {
            return;
        }
        loaded = true;
        var value = Storage.getValue(KEY);
        if (value instanceof Array) {
            for (var i = 0; i < value.size(); i++) {
                var r = value[i];
                if (r instanceof Dictionary && r["id"] instanceof String && r["parts"] instanceof Number) {
                    var report = r as Dictionary<String, Object?>;
                    if (!(report["sent"] instanceof Number)) {
                        report["sent"] = 0;
                    }
                    if (!(report["tries"] instanceof Number)) {
                        report["tries"] = 0;
                    }
                    report["done"] = true;
                    reports.add(report);
                }
            }
        }
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
        var parts = report["parts"] as Number;
        var done = isDone(report);
        if (sent < parts) {
            return [sent, done && sent == parts - 1 ? 1 : 0];
        }
        return done ? [parts, 1] : null;
    }

    // The bytes the parts not yet confirmed take, counting each as a full part.
    function stored() as Number {
        var n = 0;
        for (var i = 0; i < reports.size(); i++) {
            n += (reports[i]["parts"] as Number) - (reports[i]["sent"] as Number);
        }
        return n * PART_BYTES;
    }

    // A new recording may start: the list has a place and the budget room for two parts.
    function hasRoom() as Boolean {
        load();
        return reports.size() < MAX_REPORTS && stored() + 2 * PART_BYTES <= BUDGET_BYTES;
    }

    // A recording begins to hand over parts.
    function open(id as String, feel as String?, at as Time.Moment) as Void {
        load();
        reports.add({"id" => id, "feel" => feel, "at" => at.value(), "tries" => 0, "parts" => 0, "sent" => 0, "done" => false} as Dictionary<String, Object?>);
        try {
            save();
        } catch (ex) {
        }
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
        return stored() + 2 * PART_BYTES <= BUDGET_BYTES ? APPEND_OK : APPEND_BUDGET;
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
    // then the part. What the storage does not take stays in memory; a list that names a part the
    // storage lacks ends the report there at the next start (send).
    function keep(report as Dictionary<String, Object?>, bytes as ByteArray) as Boolean {
        var id = report["id"] as String;
        var n = report["parts"] as Number;
        report["parts"] = n + 1;
        var t0 = System.getTimer();
        try {
            save();
            Storage.setValue(partKey(id, n), bytes);
        } catch (ex) {
            held[partKey(id, n)] = bytes;
            return false;
        }
        Trace.debug("self_report_stored", {"part" => n, "bytes" => bytes.size(), "ms" => System.getTimer() - t0, "kept_bytes" => stored()});
        return true;
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
    // call runs.
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
        if (step == null) {
            return;
        }
        var part = step[0];
        var end = step[1] == 1;
        var bytes = null;
        if (part < (report["parts"] as Number)) {
            bytes = partOf(id, part);
            if (bytes == null) {
                // the storage lost it: the server gets the recording up to here
                Trace.add("outbox_lost", {"id" => id, "part" => part});
                cut(report, part);
                send();
                return;
            }
        }
        var tries = report["tries"] as Number;
        report["tries"] = tries + 1;
        var call = new Call(new OutboxAnswer(id, part, end).method(:onAnswer));
        if (end) {
            call.timeoutMs = END_TIMEOUT_MS;
        }
        inFlight = call;
        call.send(Api.selfReport(id, part, end, report["feel"] as String?, new Time.Moment(report["at"] as Number), bytes, tries));
    }

    // The report ends at part n: what came after it is dropped, and the next request is its end.
    function cut(report as Dictionary<String, Object?>, n as Number) as Void {
        var id = report["id"] as String;
        var parts = report["parts"] as Number;
        for (var k = n; k < parts; k++) {
            drop(id, k);
        }
        report["parts"] = n;
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
        var nextPart = data != null ? data["next_part"] as Object? : null;
        if (report == null) {
            // forgotten while the request was out: nothing to change
        } else if (outcome.isOk() && nextPart instanceof Number) {
            confirm(report, nextPart);
            Trace.add("self_report_part", {"part" => part, "next" => nextPart, "tries" => (report["tries"] as Number) - 1});
            report["tries"] = 0;
            try {
                save();
            } catch (ex) {
            }
        } else if (outcome.isOk()) {
            // the end was taken, or the server has the recording complete already (a repeat)
            Trace.add("self_report_sent", {"parts" => report["parts"] as Number});
            forget(id);
        } else if ("http_413".equals(outcome.code)) {
            // the recording reached the server's cap: it ends with what the server has
            Trace.add("self_report_capped", {"part" => part});
            cut(report, report["sent"] as Number);
        } else if (refused(outcome)) {
            // the server will never take this one (undecodable audio, lost parts): it would block the rest
            Trace.add("self_report_refused", {"code" => outcome.code, "part" => part});
            Idle.urgent = true;
            forget(id);
        } else {
            Trace.add("self_report_failed", {"code" => outcome.code, "part" => part});
            Idle.urgent = true;
            try {
                save();
            } catch (ex) {
            }
            var wait = retryMs(outcome, report["tries"] as Number);
            retryAt = System.getTimer() + wait;
            Idle.poke(wait);
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

    // The server has the parts before n: their storage is freed. A number outside what was handed
    // over changes nothing.
    function confirm(report as Dictionary<String, Object?>, n as Number) as Void {
        var id = report["id"] as String;
        var sent = report["sent"] as Number;
        var parts = report["parts"] as Number;
        var upTo = n < parts ? n : parts;
        for (var k = sent; k < upTo; k++) {
            drop(id, k);
        }
        if (upTo > sent) {
            report["sent"] = upTo;
        }
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

    // A status the server answers the same way however often it is asked: a 4xx other than a
    // rejected key (which the owner fixes in the settings), a timeout or too many requests.
    function refused(outcome as Outcome) as Boolean {
        var code = outcome.code;
        return outcome.kind == Outcome.FAILED && code != null && code.find("http_4") == 0
            && !code.equals("http_401") && !code.equals("http_408") && !code.equals("http_429");
    }

    function drop(id as String, n as Number) as Void {
        held.remove(partKey(id, n));
        Storage.deleteValue(partKey(id, n));
    }

    function forget(id as String) as Void {
        for (var i = 0; i < reports.size(); i++) {
            if (id.equals(reports[i]["id"])) {
                var parts = reports[i]["parts"] as Number;
                for (var k = reports[i]["sent"] as Number; k < parts; k++) {
                    drop(id, k);
                }
                reports = (reports.slice(0, i) as Array<Dictionary<String, Object?>>).addAll(reports.slice(i + 1, null));
                break;
            }
        }
        try {
            save();
        } catch (ex) {
        }
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
