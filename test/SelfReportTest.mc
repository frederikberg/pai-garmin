import Toybox.Communications;
import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

(:test)
function theSelfReportPathCarriesIdFaceAndTime(logger as Logger) as Boolean {
    var path = SelfReport.path("0f8fad5b-d9cb-469f-a165-70867728950e", 0, false, "good", "2026-11-24T08:30:00+00:00", 0);
    return path.equals("/api/watch/self-report?id=0f8fad5b-d9cb-469f-a165-70867728950e&part=0&feel=good&at=2026-11-24T08:30:00%2B00:00");
}

(:test)
function aSkippedFaceLeavesFeelOutAndARepeatOfTheLastPartNamesItsAttempt(logger as Logger) as Boolean {
    var path = SelfReport.path("x", 3, true, null, "t", 2);
    return path.equals("/api/watch/self-report?id=x&part=3&end=1&at=t&try=2");
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
    var request = Api.selfReport("id", 0, false, "okay", Time.now(), audio, 0);
    var body = request.body;
    var empty = Api.selfReport("id", 4, true, "okay", Time.now(), null, 0);
    return request.method == Communications.HTTP_REQUEST_METHOD_POST && request.params == null && body != null && body.size() == 3
        && request.path.find("feel=okay") != null && empty.body == null && empty.params == null && empty.path.find("part=4&end=1") != null;
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
function aRecordingStopsAtTheServersCapKeepingTheLastWindow(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data([1]b);
    flow.bytes = SelfReport.MAX_BYTES - 2;
    var before = flow.data([2]b) == SelfReportFlow.DATA_KEPT;
    var full = flow.data([3]b) == SelfReportFlow.DATA_FULL;
    return before && full && flow.full() && flow.state == SelfReportFlow.STOPPING && flow.audio.size() == 3;
}

(:test)
function aFullPartOfTheTailIsHandedOverAndTheRestStays(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data([0]b);
    var below = flow.data(new [Outbox.PART_BYTES - 2]b) == SelfReportFlow.DATA_KEPT;
    var part = flow.data([7, 8, 9]b) == SelfReportFlow.DATA_PART;
    var taken = flow.takePart();
    return below && part && taken.size() == Outbox.PART_BYTES && flow.audio.size() == 2 && flow.audio[1] == 9
        && flow.bytes == Outbox.PART_BYTES + 2;
}

(:test)
function theStreamAfterAMicrophoneRestartJoinsTheSameRecording(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data([1]b);
    // the watch stopped the microphone: what comes before the restart is not kept
    flow.captureEnded();
    var closed = flow.data([1]b) == SelfReportFlow.DATA_KEPT && flow.bytes == 1;
    var again = flow.resumed(0);
    // its first data says the microphone is live again, once
    var live = flow.data([2]b) == SelfReportFlow.DATA_FIRST;
    var then = flow.data([3]b) == SelfReportFlow.DATA_KEPT;
    return closed && again && live && then && flow.state == SelfReportFlow.SPEAK && flow.bytes == 3 && flow.audio.size() == 3;
}

(:test)
function aMicrophoneThatDoesNotStartAgainEndsTheRecordingOrBreaksAnEmptyOne(logger as Logger) as Boolean {
    var speaking = new SelfReportFlow();
    speaking.micStarted(0);
    speaking.data([1]b);
    speaking.captureEnded();
    var ends = !speaking.resumed(2) && speaking.state == SelfReportFlow.STOPPING && speaking.readyToSend(false);
    var waiting = new SelfReportFlow();
    waiting.micStarted(0);
    waiting.captureEnded();
    return ends && !waiting.resumed(2) && waiting.state == SelfReportFlow.BROKEN;
}

(:test)
function aFullStorageEndsTheRecordingAndStaysTheReasonUntilItWent(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data([1]b);
    var ended = flow.storageFull() && flow.state == SelfReportFlow.STOPPING && flow.filled;
    flow.sending();
    flow.result(false, "Phone not connected");
    var kept = flow.state == SelfReportFlow.FAILED && flow.notice.find("stopped") != null;
    flow.press();
    flow.result(true, "");
    return ended && kept && flow.state == SelfReportFlow.DONE && flow.notice.length() == 0;
}

(:test)
function aMicrophoneThatCannotStartBreaksTheFlowWithItsReason(logger as Logger) as Boolean {
    var a = new SelfReportFlow();
    a.micStarted(1);
    var b = new SelfReportFlow();
    b.micStarted(2);
    return a.state == SelfReportFlow.BROKEN && a.notice.find("Opus") != null && b.state == SelfReportFlow.BROKEN && b.notice.find("busy") != null;
}

(:test)
function aRecordingSplitForStorageKeepsEveryByteInOrder(logger as Logger) as Boolean {
    var bytes = new [0]b;
    for (var i = 0; i < 32769; i++) {
        bytes.add(i % 251);
    }
    var parts = Outbox.split(bytes, 16384);
    return parts.size() == 3 && parts[0].size() == 16384 && parts[2].size() == 1 && parts[1][0] == bytes[16384]
        && parts[2][0] == bytes[32768] && Outbox.split(new [0]b, 16384).size() == 0;
}

(:test)
function aRefusedRecordingOffersNoTryAgain(logger as Logger) as Boolean {
    var flow = new SelfReportFlow();
    flow.micStarted(0);
    flow.data([1]b);
    flow.press();
    flow.captureEnded();
    flow.sending();
    flow.refuse("Request failed (http_422). The server refused the recording");
    return flow.refused && flow.state == SelfReportFlow.BROKEN && flow.press() == SelfReportFlow.PRESS_NONE;
}
