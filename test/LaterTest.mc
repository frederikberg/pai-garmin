import Toybox.Lang;
import Toybox.Test;

(:test)
class LaterProbe {
    var ran as Array<String> = [];
    var other as Number = 0;

    function first() as Void {
        ran.add("first");
        Later.cancel(other);
    }

    function second() as Void {
        ran.add("second");
    }

    function late() as Void {
        ran.add("late");
    }
}

(:test)
function aDueJobRunsOnceAndCanCancelAnotherDueOne(logger as Logger) as Boolean {
    Later.jobs = [];
    var probe = new LaterProbe();
    Later.at(0, probe.method(:first));
    probe.other = Later.at(0, probe.method(:second));
    Later.at(60000, probe.method(:late));
    Later.fire();
    Later.fire();
    var waiting = Later.jobs.size();
    Later.jobs = [];
    return probe.ran.size() == 1 && probe.ran[0].equals("first") && waiting == 1;
}

(:test)
function aFailedUploadWaitsLongerEachTimeButNotForever(logger as Logger) as Boolean {
    var server = Outcome.failed("http_503");
    var phone = Outcome.failed("no_phone");
    return Outbox.retryMs(phone, 7) == 5000 && Outbox.retryMs(server, 1) == 30000 && Outbox.retryMs(server, 2) == 60000
        && Outbox.retryMs(server, 30) == 600000;
}

(:test)
function onlyAnAnswerThatNeverChangesDropsAReport(logger as Logger) as Boolean {
    return Outbox.refused(Outcome.failed("http_422")) && !Outbox.refused(Outcome.failed("http_503"))
        && !Outbox.refused(Outcome.failed("http_429")) && !Outbox.refused(Outcome.failed("timeout"))
        && !Outbox.refused(Outcome.failed("no_phone"));
}

(:test)
function aGapOrAForbiddenAnswerIsTriedAgain(logger as Logger) as Boolean {
    var gap = !Outbox.refused(Outcome.failed("http_409"));
    return gap && !Outbox.refused(Outcome.failed("http_403")) && !Outbox.refused(Outcome.failed("http_400"));
}
