import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;

// The self-report sub-app's decisions that need no screen, microphone or network.
(:glance)
module SelfReport {
    // The faces, as the server names them.
    const FEELS = ["heavy", "okay", "good"];

    // Where a recording stops by itself: the most audio the server takes for one recording
    // (docs/api.md, Self-report), less a part's room for the windows that come while it stops.
    const MAX_BYTES = 8388608 - 32768;

    // The route with its query: id, the part's number, end on the last one, feel (left out for a
    // skipped face), at, and try for a repeat. The timestamp's plus sign is escaped; a bare one
    // reads as a space.
    function path(id as String, part as Number, end as Boolean, feel as String?, at as String, tries as Number) as String {
        var query = "?id=" + id + "&part=" + part;
        if (end) {
            query += "&end=1";
        }
        if (feel != null) {
            query += "&feel=" + feel;
        }
        query += "&at=" + escapePlus(at);
        if (tries > 0) {
            query += "&try=" + tries;
        }
        return Api.SELF_REPORT + query;
    }

    function escapePlus(text as String) as String {
        var out = "";
        var chars = text.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            out += chars[i] == '+' ? "%2B" : chars[i].toString();
        }
        return out;
    }

    var seeded as Boolean = false;

    // A random version 4 UUID. The generator is seeded from the clock once per launch, so two
    // launches differ and two calls within the same millisecond do not repeat each other.
    function uuid() as String {
        if (!seeded) {
            seeded = true;
            Math.srand(System.getTimer() + Time.now().value());
        }
        var hex = "0123456789abcdef";
        var out = "";
        for (var i = 0; i < 32; i++) {
            var digit = Math.rand() % 16;
            if (i == 12) {
                digit = 4;
            } else if (i == 16) {
                digit = 8 + digit % 4;
            }
            out += hex.substring(digit, digit + 1);
            if (i == 7 || i == 11 || i == 15 || i == 19) {
                out += "-";
            }
        }
        return out;
    }
}

// Where a self-report stands, from the microphone starting to the server having it. The screen
// acts on what the calls here answer. The audio not yet handed to the Outbox is the tail: a full
// part of it goes to the Outbox while the recording runs, the rest when it ends.
class SelfReportFlow {
    enum {
        // the microphone is starting
        WAIT,
        // the microphone delivers
        SPEAK,
        // Start ended the recording; the last audio is coming
        STOPPING,
        SENDING,
        // the server has it
        DONE,
        // the server did not take it; Start tries again
        FAILED,
        // nothing can be recorded
        BROKEN
    }

    enum {
        DATA_KEPT,
        // the first data of the recording: the microphone is live
        DATA_FIRST,
        // the tail holds a full part
        DATA_PART,
        // the recording reached SelfReport.MAX_BYTES: it ends here
        DATA_FULL
    }

    enum {
        PRESS_NONE,
        PRESS_STOP,
        PRESS_SEND
    }

    var state as Number = WAIT;
    var audio as ByteArray = new [0]b;
    // everything recorded, handed over or not
    var bytes as Number = 0;
    // attempts after the first
    var tries as Number = 0;
    var notice as String = "";
    // the watch's storage took no more: the recording stopped there
    var filled as Boolean = false;
    private var _captureOpen as Boolean = false;

    // code as Recorder.start answers: 0 recording began, 1 the watch cannot capture Opus, 2 starting failed.
    function micStarted(code as Number) as Void {
        if (code == 0) {
            _captureOpen = true;
        } else {
            broken(code == 1 ? "This watch cannot capture Opus" : "Microphone busy");
        }
    }

    function broken(text as String) as Void {
        state = BROKEN;
        notice = text;
        _captureOpen = false;
    }

    // The storage is full before anything was recorded: the microphone does not start.
    function noRoom() as Void {
        filled = true;
        broken("Recordings wait for the phone. They go once it is back");
    }

    function capturing() as Boolean {
        return state == WAIT || state == SPEAK;
    }

    function captureOpen() as Boolean {
        return _captureOpen;
    }

    // A window of the recording. What comes while Start stops the microphone is the end of it and kept.
    function data(chunk as ByteArray) as Number {
        if (!_captureOpen) {
            return DATA_KEPT;
        }
        audio.addAll(chunk);
        bytes += chunk.size();
        if (state == WAIT) {
            state = SPEAK;
            return DATA_FIRST;
        }
        if (state != SPEAK) {
            return DATA_KEPT;
        }
        if (bytes >= SelfReport.MAX_BYTES) {
            return DATA_FULL;
        }
        return audio.size() >= Outbox.PART_BYTES ? DATA_PART : DATA_KEPT;
    }

    // The first part of the tail, which leaves it.
    function takePart() as ByteArray {
        var n = Outbox.PART_BYTES < audio.size() ? Outbox.PART_BYTES : audio.size();
        var part = audio.slice(0, n);
        audio = audio.slice(n, null);
        return part;
    }

    // Start: ends a recording the microphone has delivered, or sends again after a failure.
    function press() as Number {
        if (state == SPEAK) {
            state = STOPPING;
            return PRESS_STOP;
        }
        if (state == FAILED) {
            tries += 1;
            state = SENDING;
            return PRESS_SEND;
        }
        return PRESS_NONE;
    }

    // The recording reached its limit, or the server's.
    function full() as Boolean {
        if (state == SPEAK) {
            state = STOPPING;
            return true;
        }
        return false;
    }

    // The storage took no more: the recording ends, and the screen says why until the server has it.
    function storageFull() as Boolean {
        filled = true;
        notice = "Recording stopped. It goes once the phone is back";
        return full();
    }

    function captureEnded() as Void {
        _captureOpen = false;
    }

    // The microphone started again after the watch stopped it (code as Recorder.start answers): its
    // new stream follows in the same recording. A start that failed ends the recording.
    function resumed(code as Number) as Boolean {
        if (code == 0) {
            _captureOpen = true;
            return true;
        }
        _captureOpen = false;
        if (!full()) {
            broken("Microphone busy");
        }
        return false;
    }

    // The microphone is done, or has been given up on: the request may go.
    function readyToSend(patient as Boolean) as Boolean {
        return state == STOPPING && (patient || !_captureOpen);
    }

    function sending() as Void {
        _captureOpen = false;
        state = SENDING;
    }

    // An answer about the recording: the one the screen waits for, or one of the Outbox's own tries
    // while the screen shows the failure. A full storage stays the reason shown until it went.
    function result(ok as Boolean, text as String) as Void {
        if (state == SENDING || state == FAILED) {
            state = ok ? DONE : FAILED;
            if (ok || !filled) {
                notice = ok ? "" : text;
            }
        }
    }
}
