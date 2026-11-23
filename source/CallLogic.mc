import Toybox.System;
import Toybox.Lang;

// The decisions of the Computer call that need no network or audio hardware.
module CallLogic {
    // The sample rate of the pieces the server sends.
    const PCM_RATE = 16000;

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

    // A 44-byte WAV header for 16-bit mono PCM of a stream whose length is not known: the player
    // reads the samples that follow until the stream ends.
    function wavHeader(rate as Number) as ByteArray {
        var h = new [0]b;
        h.addAll("RIFF".toUtf8Array() as Array);
        h.addAll(le(0x7FFFFFFF, 4));
        h.addAll("WAVEfmt ".toUtf8Array() as Array);
        h.addAll(le(16, 4));
        h.addAll(le(1, 2));
        h.addAll(le(1, 2));
        h.addAll(le(rate, 4));
        h.addAll(le(rate * 2, 4));
        h.addAll(le(2, 2));
        h.addAll(le(16, 2));
        h.addAll("data".toUtf8Array() as Array);
        h.addAll(le(0x7FFFFFFF, 4));
        return h;
    }

    function le(value as Number, bytes as Number) as Array {
        var out = [];
        for (var i = 0; i < bytes; i++) {
            out.add((value >> (8 * i)) & 0xFF);
        }
        return out;
    }

    // Milliseconds of 16-bit mono PCM at the given rate.
    function pcmMs(bytes as Number, rate as Number) as Number {
        return bytes * 1000 / (rate * 2);
    }
}

// What the watch saw during a call, kept for the server's log route in bounded batches. When the
// buffer overflows, the first lines (the cause of an outage) stay and the oldest of the later ones go.
module Trace {
    const MAX_LINES = 80;
    const KEEP_FIRST = 20;
    var lines as Array<Dictionary<String, Object>> = [];
    var dropped as Number = 0;
    // the drop count a batch in flight reported
    var reported as Number = 0;

    function add(ev as String, fields as Dictionary?) as Void {
        var line = {"t" => System.getTimer(), "ev" => ev} as Dictionary<String, Object>;
        if (fields != null) {
            var keys = fields.keys();
            for (var i = 0; i < keys.size(); i++) {
                line[keys[i] as String] = fields[keys[i]] as Object;
            }
        }
        System.println("call: " + line);
        lines.add(line);
        if (lines.size() > MAX_LINES) {
            var head = lines.slice(0, KEEP_FIRST) as Array<Dictionary<String, Object>>;
            var tail = lines.slice(KEEP_FIRST + 1, null) as Array<Dictionary<String, Object>>;
            lines = head;
            lines.addAll(tail);
            dropped += 1;
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
}
