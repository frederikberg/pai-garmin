import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;

// The decisions of the Computer call that need no network or audio hardware.
module CallLogic {
    // The wait before the next try after the n-th failure in a row, in milliseconds.
    const BACKOFF_MS = [500, 1000, 2000, 4000, 8000];

    function backoff(failures as Number) as Number {
        var i = failures - 1;
        i = i < 0 ? 0 : (i >= BACKOFF_MS.size() ? BACKOFF_MS.size() - 1 : i);
        return BACKOFF_MS[i];
    }

    // Transport failures (negative codes: no phone, timeouts, a full request queue), server errors
    // and the two "try again" codes are worth another try; any other answer is the server's decision.
    function retryable(code as Number) as Boolean {
        return code < 0 || code >= 500 || code == 429 || code == 408;
    }

    // What an audio chunk's 409 means: the server expects chunk `expected` next while the watch
    // holds chunk `sent` unacknowledged, and still has the acknowledged chunks from `base` on.
    // "acked": the server already has it (also when it is ahead); "rewind": it misses chunks the
    // watch still holds; "lost": it misses chunks the watch no longer has.
    function afterConflict(sent as Number, expected as Number, base as Number) as String {
        if (expected > sent) {
            return "acked";
        }
        return expected >= base ? "rewind" : "lost";
    }

    // The watch's own signals, never from the network.
    const CUE_SENT = 0;
    const CUE_YOUR_TURN = 1;
    const CUE_ERROR = 2;
    const CUE_BYE = 3;
    // How the watch buzzes for a signal, as [strength 0-100, length in ms] with strength 0 a pause.
    // "Speak" (the microphone delivers) is one short buzz, "sent" two short ones, an error one long,
    // and a call the watch ended by itself two short ones and a longer one.
    function buzz(kind as Number) as Array<Array<Number>> {
        if (kind == CUE_YOUR_TURN) {
            return [[100, 120]];
        } else if (kind == CUE_SENT) {
            return [[100, 70], [0, 90], [100, 70]];
        } else if (kind == CUE_BYE) {
            return [[100, 70], [0, 90], [100, 70], [0, 90], [100, 300]];
        }
        return [[100, 700]];
    }
}

// What the watch saw during a call, kept for the server's log route in bounded batches. When the
// buffer overflows, the first lines (the cause of an outage) stay and the oldest of the later ones go.
// The last lines are also kept in the app's storage once a turn and at exit, and the next launch puts
// them at the front of its own log if the run did not get to send them.
module Trace {
    const MAX_LINES = 120;
    const KEEP_FIRST = 20;
    // lines kept in storage (a few kB)
    const STORE_LINES = 25;
    const STORE_KEY = "log";
    var lines as Array<Dictionary<String, Object>> = [];
    var dropped as Number = 0;
    // the drop count a batch in flight reported
    var reported as Number = 0;
    // the detailed trace (heartbeat, every request) is on
    var debugOn as Boolean = false;
    // a Computer call is running
    var active as Boolean = false;
    // the app's uptime clock when it started
    var bornAt as Number = 0;

    function add(ev as String, fields as Dictionary?) as Void {
        var line = {"t" => System.getTimer(), "ev" => ev} as Dictionary<String, Object>;
        if (fields != null) {
            var keys = fields.keys();
            for (var i = 0; i < keys.size(); i++) {
                line[keys[i] as String] = fields[keys[i]] as Object;
            }
        }
        echo(line);
        lines.add(line);
        if (lines.size() > MAX_LINES) {
            var head = lines.slice(0, KEEP_FIRST) as Array<Dictionary<String, Object>>;
            var tail = lines.slice(KEEP_FIRST + 1, null) as Array<Dictionary<String, Object>>;
            lines = head;
            lines.addAll(tail);
            dropped += 1;
        }
    }

    // A debug build prints every line; a release build spends nothing on it.
    (:debug)
    function echo(line as Dictionary<String, Object>) as Void {
        System.println("call: " + line);
    }

    (:release)
    function echo(line as Dictionary<String, Object>) as Void {
    }

    // A line of the detailed trace: only while the debug setting is on.
    function debug(ev as String, fields as Dictionary?) as Void {
        if (debugOn) {
            add(ev, fields);
        }
    }

    // Up to count lines for one request; they leave the buffer only through confirm().
    function batch(count as Number) as Array<Dictionary<String, Object>> {
        var n = lines.size() < count ? lines.size() : count;
        var out = lines.slice(0, n) as Array<Dictionary<String, Object>>;
        reported = dropped;
        if (dropped > 0) {
            out.add({"t" => System.getTimer(), "ev" => "log_dropped", "count" => dropped} as Dictionary<String, Object>);
        }
        return out;
    }

    function confirm(count as Number) as Void {
        var n = lines.size() < count ? lines.size() : count;
        lines = lines.slice(n, null) as Array<Dictionary<String, Object>>;
        dropped -= reported;
        reported = 0;
    }

    // The last lines go to storage.
    function persist() as Void {
        var t0 = System.getTimer();
        var keep = lines.size() > STORE_LINES ? lines.slice(lines.size() - STORE_LINES, null) : lines;
        Storage.setValue(STORE_KEY, keep as Array<Storage.ValueType>);
        debug("persist", {"ms" => System.getTimer() - t0, "lines" => keep.size()});
    }

    // What this run could not send is kept for the next launch; nothing is kept when all of it went.
    function keep() as Void {
        if (lines.size() > 0) {
            persist();
        } else {
            Storage.deleteValue(STORE_KEY);
        }
    }

    // At launch: the lines the previous run kept go to the front of the log, closed by a
    // "stored_end" line, and leave with this run's first batches.
    function restore() as Void {
        var value = Storage.getValue(STORE_KEY);
        if (value instanceof Array && value.size() > 0) {
            var old = [] as Array<Dictionary<String, Object>>;
            for (var i = 0; i < value.size(); i++) {
                var line = value[i];
                if (line instanceof Dictionary) {
                    old.add(line as Dictionary<String, Object>);
                }
            }
            old.add({"t" => System.getTimer(), "ev" => "stored_end", "lines" => old.size()} as Dictionary<String, Object>);
            old.addAll(lines);
            lines = old;
            Storage.deleteValue(STORE_KEY);
        }
    }
}
