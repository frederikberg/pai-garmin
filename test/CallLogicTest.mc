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

(:test)
function theTurnSignalsAreBuzzesThatDiffer(logger as Logger) as Boolean {
    var speak = CallLogic.buzz(CallLogic.CUE_YOUR_TURN);
    var sent = CallLogic.buzz(CallLogic.CUE_SENT);
    var error = CallLogic.buzz(CallLogic.CUE_ERROR);
    // one short buzz to speak, two short ones (with a pause) when sent, one long one for an error
    return speak.size() == 1 && sent.size() == 3 && sent[1][0] == 0 && sent[0][1] < 200 && error.size() == 1
        && error[0][1] > 4 * speak[0][1];
}

(:test)
function whatARunKeptLeadsTheNextRunsLogOnce(logger as Logger) as Boolean {
    Trace.lines = [];
    Trace.add("old", null);
    Trace.keep();
    // the next run: a line of its own exists before the kept ones are read
    Trace.lines = [];
    Trace.add("new", null);
    Trace.restore();
    var order = Trace.lines.size() == 3 && (Trace.lines[0]["ev"] as String).equals("old")
        && (Trace.lines[1]["ev"] as String).equals("stored_end") && (Trace.lines[2]["ev"] as String).equals("new");
    Trace.restore();
    var once = Trace.lines.size() == 3;
    // a run that sent everything leaves nothing behind, also where an earlier run had
    Trace.add("unsent", null);
    Trace.keep();
    Trace.lines = [];
    Trace.keep();
    Trace.restore();
    var nothing = Trace.lines.size() == 0;
    return order && once && nothing;
}
