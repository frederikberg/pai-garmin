import Toybox.Communications;
import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

(:test)
function theSelfReportPathCarriesIdFaceAndTime(logger as Logger) as Boolean {
    var path = SelfReport.path("0f8fad5b-d9cb-469f-a165-70867728950e", "good", "2026-11-24T08:30:00+00:00", 0);
    return path.equals("/api/watch/self-report?id=0f8fad5b-d9cb-469f-a165-70867728950e&feel=good&at=2026-11-24T08:30:00%2B00:00");
}

(:test)
function aSkippedFaceLeavesFeelOutAndARepeatNamesItsAttempt(logger as Logger) as Boolean {
    var path = SelfReport.path("x", null, "t", 2);
    return path.equals("/api/watch/self-report?id=x&at=t&try=2");
}

(:test)
function aUuidIsVersionFourAndDiffersPerCall(logger as Logger) as Boolean {
    var a = SelfReport.uuid();
    var chars = a.toCharArray();
    var shaped = a.length() == 36 && chars[8] == '-' && chars[13] == '-' && chars[18] == '-' && chars[23] == '-' && chars[14] == '4';
    var variant = "89ab".find(chars[19].toString()) != null;
    return shaped && variant && !a.equals(SelfReport.uuid());
}

(:test)
function theSelfReportRequestCarriesTheAudioAsItsBody(logger as Logger) as Boolean {
    var audio = [1, 2, 3]b;
    var request = Api.selfReport("id", "okay", Time.now(), audio, 0);
    var body = request.body;
    return request.method == Communications.HTTP_REQUEST_METHOD_POST && request.params == null && body != null && body.size() == 3
        && request.path.find("feel=okay") != null;
}

(:test)
function aRecordingGoesFromWaitToSpeakToSendingToDone(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    var first = flow.data([1, 2]b);
    var second = flow.data([3]b);
    var early = flow.press() == SelfReportFlow.PRESS_STOP;
    // the last window arrives while the microphone stops
    flow.data([4]b);
    var held = !flow.readyToSend(false);
    flow.captureEnded();
    var ready = flow.readyToSend(false);
    flow.sending();
    flow.result(true, "");
    return first == SelfReportFlow.DATA_FIRST && second == SelfReportFlow.DATA_KEPT && early && held && ready
        && flow.state == SelfReportFlow.DONE && flow.audio.size() == 4;
}

(:test)
function aPressBeforeTheMicrophoneDeliversDoesNothing(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    return flow.press() == SelfReportFlow.PRESS_NONE && flow.state == SelfReportFlow.WAIT;
}

(:test)
function aFailedSendKeepsTheAudioAndStartSendsItAgain(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data([1, 2, 3]b);
    flow.press();
    flow.captureEnded();
    flow.sending();
    flow.result(false, "Request failed (http_503)");
    var failed = flow.state == SelfReportFlow.FAILED && flow.notice.length() > 0;
    var again = flow.press() == SelfReportFlow.PRESS_SEND;
    return failed && again && flow.tries == 1 && flow.state == SelfReportFlow.SENDING && flow.audio.size() == 3;
}

(:test)
function theEndOfTheMicrophoneIsNotWaitedForForever(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data([1]b);
    flow.press();
    return !flow.readyToSend(false) && flow.readyToSend(true);
}

(:test)
function aRecordingStopsAtTheLimitWithoutKeepingTheOverflow(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data(new [SelfReport.MAX_BYTES - 1]b);
    var full = flow.data([1, 2]b) == SelfReportFlow.DATA_FULL;
    return full && flow.full() && flow.state == SelfReportFlow.STOPPING && flow.audio.size() == SelfReport.MAX_BYTES - 1;
}

(:test)
function aMicrophoneThatCannotStartBreaksTheFlowWithItsReason(logger as Logger) as Boolean {
    var a = new SelfReportFlow();
    a.micStarted(1);
    var b = new SelfReportFlow();
    b.micStarted(2);
    return a.state == SelfReportFlow.BROKEN && a.notice.find("Opus") != null && b.state == SelfReportFlow.BROKEN && b.notice.find("busy") != null;
}
