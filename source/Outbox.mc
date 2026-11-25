import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;

// Self-reports the server has not confirmed yet. A recording is put here when it ends, saved on the
// watch in parts (a stored value holds at most 32 KB), and sent until the server takes it: at once,
// again by itself after a failure, and at the next start of the app. The id stays the same, so a
// repeat is never counted twice. Nothing goes out while a Computer call runs.
module Outbox {
    const KEY = "outbox";
    const PART_BYTES = 16384;
    // the most reports kept; the oldest goes when a new one comes
    const MAX_REPORTS = 3;

    // the reports waiting, oldest first: id, feel (or null), at (seconds), tries, parts
    var reports as Array<Dictionary<String, Object?>> = [];
    // their audio while this run holds it, by id
    var audio as Dictionary<String, ByteArray> = {};
    var loaded as Boolean = false;
    // the uptime clock before which no retry goes, after a failure
    var retryAt as Number = 0;
    var inFlight as Call? = null;
    // the screen waiting for the answer about its report, if any
    var listener as Method(outcome as Outcome) as Void or Null = null;
    var listenerId as String? = null;

    function load() as Void {
        if (loaded) {
            return;
        }
        loaded = true;
        var value = Storage.getValue(KEY);
        if (value instanceof Array) {
            for (var i = 0; i < value.size(); i++) {
                var r = value[i];
                if (r instanceof Dictionary && r["id"] instanceof String) {
                    reports.add(r as Dictionary<String, Object?>);
                }
            }
        }
    }

    function pending() as Boolean {
        load();
        return reports.size() > 0;
    }

    // A recording that ended: kept on the watch until the server has it.
    function put(id as String, feel as String?, at as Time.Moment, bytes as ByteArray) as Void {
        load();
        if (reports.size() >= MAX_REPORTS) {
            Trace.add("outbox_full", {"dropped" => reports[0]["id"] as String});
            forget(reports[0]["id"] as String);
        }
        var parts = split(bytes, PART_BYTES);
        var report = {"id" => id, "feel" => feel, "at" => at.value(), "tries" => 0, "parts" => parts.size()} as Dictionary<String, Object?>;
        reports.add(report);
        audio[id] = bytes;
        try {
            for (var i = 0; i < parts.size(); i++) {
                Storage.setValue(partKey(id, i), parts[i]);
            }
            save();
        } catch (ex) {
            // the watch keeps it only while the app runs
            Trace.add("outbox_unsaved", {"error" => ex.getErrorMessage()});
        }
    }

    // Sends the oldest report now, unless a request for one is already out or a call runs.
    function send() as Void {
        load();
        if (inFlight != null || reports.size() == 0) {
            return;
        }
        if (Trace.active) {
            // after the call
            Idle.poke(10000);
            return;
        }
        var report = reports[0];
        var id = report["id"] as String;
        var bytes = audioOf(report);
        if (bytes == null) {
            Trace.add("outbox_lost", {"id" => id});
            forget(id);
            send();
            return;
        }
        var tries = report["tries"] as Number;
        report["tries"] = tries + 1;
        var call = new Call(new OutboxAnswer(id).method(:onAnswer));
        inFlight = call;
        Trace.add("self_report_upload", {"bytes" => bytes.size(), "tries" => tries});
        call.send(Api.selfReport(id, report["feel"] as String?, new Time.Moment(report["at"] as Number), bytes, tries));
    }

    function answered(id as String, outcome as Outcome) as Void {
        inFlight = null;
        if (outcome.isOk()) {
            Trace.add("self_report_sent", {});
            forget(id);
        } else {
            Trace.add("self_report_failed", {"code" => outcome.code});
            Idle.urgent = true;
            try {
                save();
            } catch (ex) {
            }
            retryAt = System.getTimer() + retryMs(outcome);
            Idle.poke(retryMs(outcome));
        }
        var l = listener;
        if (l != null && id.equals(listenerId)) {
            l.invoke(outcome);
        }
        if (outcome.isOk() && reports.size() > 0) {
            Idle.poke(Idle.DELAY_MS);
        }
    }

    // The next try: soon while only the phone link is missing (checking it sends nothing), later
    // when the server or the link failed.
    function retryMs(outcome as Outcome) as Number {
        return "no_phone".equals(outcome.code) ? 5000 : 30000;
    }

    function audioOf(report as Dictionary<String, Object?>) as ByteArray? {
        var id = report["id"] as String;
        var held = audio[id];
        if (held != null) {
            return held;
        }
        var parts = [] as Array<ByteArray>;
        for (var i = 0; i < (report["parts"] as Number); i++) {
            var part = Storage.getValue(partKey(id, i));
            if (!(part instanceof ByteArray)) {
                return null;
            }
            parts.add(part);
        }
        return join(parts);
    }

    function forget(id as String) as Void {
        for (var i = 0; i < reports.size(); i++) {
            if (id.equals(reports[i]["id"])) {
                var parts = reports[i]["parts"] as Number;
                for (var k = 0; k < parts; k++) {
                    Storage.deleteValue(partKey(id, k));
                }
                reports = (reports.slice(0, i) as Array<Dictionary<String, Object?>>).addAll(reports.slice(i + 1, null));
                break;
            }
        }
        audio.remove(id);
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

    function join(parts as Array<ByteArray>) as ByteArray {
        var out = new [0]b;
        for (var i = 0; i < parts.size(); i++) {
            out.addAll(parts[i]);
        }
        return out;
    }
}

class OutboxAnswer {
    private var _id as String;

    function initialize(id as String) {
        _id = id;
    }

    function onAnswer(outcome as Outcome) as Void {
        Outbox.answered(_id, outcome);
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
    var timer as Timer.Timer? = null;
    var logOut as Boolean = false;
    // a line worth sending soon was written (a failed upload): the log goes without waiting for a full batch
    var urgent as Boolean = false;
    var logBatch as Number = 0;

    function poke(ms as Number) as Void {
        var t = timer;
        if (t == null) {
            t = new Timer.Timer();
            timer = t;
        }
        t.stop();
        t.start(new IdleRun().method(:run), ms, false);
    }

    function run() as Void {
        if (busy > 0 || !Gate.open) {
            poke(DELAY_MS);
            return;
        }
        if (Trace.active) {
            // a call carries the log itself; a waiting self-report goes after it
            if (Outbox.pending()) {
                poke(10000);
            }
            return;
        }
        if (!System.getDeviceSettings().phoneConnected) {
            if (Outbox.pending()) {
                poke(5000);
            }
            return;
        }
        if (Outbox.pending()) {
            var wait = Outbox.retryAt - System.getTimer();
            if (wait <= 0) {
                Outbox.send();
                return;
            }
            poke(wait);
        }
        if (!logOut && (Trace.lines.size() >= LOG_BATCH || urgent && Trace.lines.size() > 0)) {
            urgent = false;
            sendLog();
        }
    }

    function sendLog() as Void {
        logOut = true;
        logBatch += 1;
        var count = Trace.lines.size() < LOG_BATCH ? Trace.lines.size() : LOG_BATCH;
        var lines = Trace.batch(count);
        var call = new Call(new IdleLog(count).method(:onAnswer));
        call.send(Api.appLog(logBatch, lines));
    }

    function logged(count as Number, outcome as Outcome) as Void {
        logOut = false;
        // a call that began meanwhile carries the lines itself
        if (outcome.isOk() && !Trace.active) {
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
