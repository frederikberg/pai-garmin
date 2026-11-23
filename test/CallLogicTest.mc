import Toybox.Lang;
import Toybox.Test;

(:test)
function backoffGrowsAndStopsAtTheCeiling(logger as Logger) as Boolean {
    return CallLogic.backoff(1) == 500 && CallLogic.backoff(3) == 2000 && CallLogic.backoff(5) == 8000
        && CallLogic.backoff(40) == 8000 && CallLogic.backoff(0) == 500;
}

(:test)
function onlyTransportAndServerErrorsAreRetried(logger as Logger) as Boolean {
    return CallLogic.retryable(-104) && CallLogic.retryable(-101) && CallLogic.retryable(-300)
        && CallLogic.retryable(503) && CallLogic.retryable(429)
        && !CallLogic.retryable(400) && !CallLogic.retryable(404) && !CallLogic.retryable(422);
}

(:test)
function aConflictIsAckedRewoundOrLost(logger as Logger) as Boolean {
    return CallLogic.afterConflict(3, 4, 0).equals("acked") && CallLogic.afterConflict(3, 7, 0).equals("acked")
        && CallLogic.afterConflict(3, 3, 0).equals("rewind") && CallLogic.afterConflict(3, 1, 1).equals("rewind")
        && CallLogic.afterConflict(3, 0, 2).equals("lost");
}

(:test)
function cuesAreDistinctCompleteWavFiles(logger as Logger) as Boolean {
    var sent = CallLogic.cueWav(CallLogic.CUE_SENT);
    var turn = CallLogic.cueWav(CallLogic.CUE_YOUR_TURN);
    var error = CallLogic.cueWav(CallLogic.CUE_ERROR);
    // 44 bytes of header, then 16-bit samples at 8 kHz
    return sent.size() == 44 + 8 * 90 * 2 && turn.size() == 44 + 8 * 190 * 2 && error.size() == 44 + 8 * 420 * 2
        && CallLogic.cueMs(CallLogic.CUE_YOUR_TURN) == 190 && sent[0] == 0x52 && sent[8] == 0x57 && sent[36] == 0x64
        && CallLogic.cueNotes(CallLogic.CUE_SENT)[0][0] != CallLogic.cueNotes(CallLogic.CUE_YOUR_TURN)[0][0];
}

(:test)
function traceKeepsAFixedNumberOfLines(logger as Logger) as Boolean {
    Trace.lines = [];
    Trace.dropped = 0;
    Trace.reported = 0;
    for (var i = 0; i < Trace.MAX_LINES + 5; i++) {
        Trace.add("x", {"i" => i});
    }
    var kept = Trace.lines.size() == Trace.MAX_LINES && Trace.dropped == 5 && (Trace.lines[0]["i"] as Number) == 0
        && (Trace.lines[Trace.KEEP_FIRST]["i"] as Number) == Trace.KEEP_FIRST + 5;
    var batch = Trace.batch(20);
    Trace.confirm(20);
    var rest = Trace.lines.size() == Trace.MAX_LINES - 20 && Trace.dropped == 0;
    Trace.lines = [];
    return kept && batch.size() == 21 && rest;
}
