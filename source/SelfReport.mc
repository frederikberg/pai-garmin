import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;

// The self-report sub-app's decisions that need no screen, microphone or network.
(:glance)
module SelfReport {
    // The faces, as the server names them.
    const FEELS = ["heavy", "okay", "good"];

    // Where a recording stops by itself: what a watch holds in memory and sends in one request.
    const MAX_BYTES = 65536;

    // The route with its query: id, feel (left out for a skipped face), at, and try for a repeat.
    // The timestamp's plus sign is escaped; a bare one reads as a space.
    function path(id as String, feel as String?, at as String, tries as Number) as String {
        var query = "?id=" + id;
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
// acts on what the calls here answer.
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
        // the audio reached the limit: the recording ends here
        DATA_FULL
    }

    enum {
        PRESS_NONE,
        PRESS_STOP,
        PRESS_SEND
    }

    var state as Number = WAIT;
    var audio as ByteArray = new [0]b;
    // attempts after the first
    var tries as Number = 0;
    var notice as String = "";
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

    function capturing() as Boolean {
        return state == WAIT || state == SPEAK;
    }

    // A window of the recording. What comes while Start stops the microphone is the end of it and kept.
    function data(bytes as ByteArray) as Number {
        if (!_captureOpen) {
            return DATA_KEPT;
        }
        if (audio.size() + bytes.size() > SelfReport.MAX_BYTES) {
            return DATA_FULL;
        }
        audio.addAll(bytes);
        if (state == WAIT) {
            state = SPEAK;
            return DATA_FIRST;
        }
        return DATA_KEPT;
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

    // The audio limit was reached while recording.
    function full() as Boolean {
        if (state == SPEAK) {
            state = STOPPING;
            return true;
        }
        return false;
    }

    function captureEnded() as Void {
        _captureOpen = false;
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
    // while the screen shows the failure.
    function result(ok as Boolean, text as String) as Void {
        if (state == SENDING || state == FAILED) {
            state = ok ? DONE : FAILED;
            notice = ok ? "" : text;
        }
    }
}
