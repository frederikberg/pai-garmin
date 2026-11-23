import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.Math;
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

    // The watch's own cues: short, played at once and never from the network.
    const CUE_SENT = 0;
    const CUE_YOUR_TURN = 1;
    const CUE_ERROR = 2;
    const CUE_RATE = 8000;
    const CUE_TABLE = 64;

    // A cue's notes as [frequency in Hz, length in ms]: "sent" is one short high beep, "your turn"
    // two rising notes, "error" two low falling ones.
    function cueNotes(kind as Number) as Array<Array<Number>> {
        if (kind == CUE_SENT) {
            return [[880, 90]];
        } else if (kind == CUE_YOUR_TURN) {
            return [[660, 80], [990, 110]];
        }
        return [[330, 160], [220, 260]];
    }

    function cueMs(kind as Number) as Number {
        var notes = cueNotes(kind);
        var ms = 0;
        for (var i = 0; i < notes.size(); i++) {
            ms += notes[i][1];
        }
        return ms;
    }

    // A cue as a complete 8 kHz mono 16-bit WAV file. The samples come from a table by whole-number
    // steps: a sine per sample takes too long for the watch to run in one go.
    function cueWav(kind as Number) as ByteArray {
        var notes = cueNotes(kind);
        var table = [] as Array<Number>;
        for (var i = 0; i < CUE_TABLE; i++) {
            table.add((Math.sin(2 * Math.PI * i / CUE_TABLE) * 1000).toNumber());
        }
        var pcm = [] as Array<Number>;
        for (var n = 0; n < notes.size(); n++) {
            var count = CUE_RATE * notes[n][1] / 1000;
            var fade = CUE_RATE / 200;
            var step = notes[n][0] * CUE_TABLE * 256 / CUE_RATE;
            var phase = 0;
            for (var i = 0; i < count; i++) {
                var edge = i < fade ? i : (count - 1 - i < fade ? count - 1 - i : fade);
                var v = table[(phase >> 8) % CUE_TABLE] * 26 * edge / fade;
                phase += step;
                pcm.add(v & 0xFF);
                pcm.add((v >> 8) & 0xFF);
            }
        }
        var wav = new [0]b;
        wav.addAll("RIFF".toUtf8Array() as Array);
        wav.addAll(le(36 + pcm.size(), 4));
        wav.addAll("WAVEfmt ".toUtf8Array() as Array);
        wav.addAll(le(16, 4));
        wav.addAll(le(1, 2));
        wav.addAll(le(1, 2));
        wav.addAll(le(CUE_RATE, 4));
        wav.addAll(le(CUE_RATE * 2, 4));
        wav.addAll(le(2, 2));
        wav.addAll(le(16, 2));
        wav.addAll("data".toUtf8Array() as Array);
        wav.addAll(le(pcm.size(), 4));
        wav.addAll(pcm as Array);
        return wav;
    }

    function le(value as Number, bytes as Number) as Array {
        var out = [];
        for (var i = 0; i < bytes; i++) {
            out.add((value >> (8 * i)) & 0xFF);
        }
        return out;
    }
}

// What the watch saw during a call, kept for the server's log route in bounded batches. When the
// buffer overflows, the first lines (the cause of an outage) stay and the oldest of the later ones go.
// The last lines are also kept in the app's storage at the end of a turn and at exit, to be sent at
// the next launch if the run did not get to send them.
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
        var keep = lines.size() > STORE_LINES ? lines.slice(lines.size() - STORE_LINES, null) : lines;
        Storage.setValue(STORE_KEY, keep as Array<Storage.ValueType>);
    }

    // What the previous run stored, or null.
    function stored() as Array? {
        var value = Storage.getValue(STORE_KEY);
        return value instanceof Array && value.size() > 0 ? value : null;
    }

    function clearStored() as Void {
        Storage.deleteValue(STORE_KEY);
    }
}
