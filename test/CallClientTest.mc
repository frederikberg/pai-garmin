import Toybox.Lang;
import Toybox.Test;

// The device the client talks to, replaced by a recorder: requests wait until the test answers them,
// and time moves when the test says so.
(:test)
class FakeEnv extends CallEnv {
    var clock as Number = 0;
    var requests as Array<Dictionary> = [];
    var audioBytes as Number = 0;

    function initialize() {
        CallEnv.initialize();
    }

    function now() as Number {
        return clock;
    }

    function check() as Number {
        return 0;
    }

    function baseUrl() as String {
        return "https://example.com";
    }

    function gateOpen() as Boolean {
        return true;
    }

    function debugLog() as Boolean {
        return false;
    }

    function startClock(tick as Method() as Void, ms as Number) as Void {
    }

    function stopClock() as Void {
    }

    (:typecheck(false))
    function request(url as String, params as Object?, options as Dictionary, callback as Method) as Void {
        if (url.find("/audio") != null && options[:body] != null) {
            audioBytes += (options[:body] as ByteArray).size();
        }
        requests.add({:url => url, :params => params, :body => options[:body], :callback => callback, :open => true});
    }

    function asked(part as String) as Boolean {
        for (var i = 0; i < requests.size(); i++) {
            if ((requests[i][:url] as String).find(part) != null) {
                return true;
            }
        }
        return false;
    }

    // Answers the oldest open request whose address contains part; false when there is none.
    function reply(part as String, code as Number, data as Object?) as Boolean {
        for (var i = 0; i < requests.size(); i++) {
            var r = requests[i];
            if ((r[:open] as Boolean) && (r[:url] as String).find(part) != null) {
                r[:open] = false;
                (r[:callback] as Method).invoke(code, data);
                return true;
            }
        }
        return false;
    }

    // The address of the one request in flight; an empty string when there is none or several.
    function onlyOpen() as String {
        var url = "";
        var count = 0;
        for (var i = 0; i < requests.size(); i++) {
            if (requests[i][:open] as Boolean) {
                count += 1;
                url = requests[i][:url] as String;
            }
        }
        return count == 1 ? url : "";
    }

    // Answers the request in flight.
    function replyOnly(code as Number, data as Object?) as Void {
        for (var i = 0; i < requests.size(); i++) {
            var r = requests[i];
            if (r[:open] as Boolean) {
                r[:open] = false;
                (r[:callback] as Method).invoke(code, data);
                return;
            }
        }
    }

    // The wait asked of the oldest open events request.
    function eventsWait() as Number {
        for (var i = 0; i < requests.size(); i++) {
            var r = requests[i];
            if ((r[:open] as Boolean) && (r[:url] as String).find("/events") != null) {
                var params = r[:params] as Dictionary;
                return params["wait"] as Number;
            }
        }
        return -1;
    }

    // The body of the oldest open request whose address contains part.
    function bodyOf(part as String) as ByteArray? {
        for (var i = 0; i < requests.size(); i++) {
            var r = requests[i];
            if ((r[:open] as Boolean) && (r[:url] as String).find(part) != null) {
                return r[:body] as ByteArray?;
            }
        }
        return null;
    }

    // The position of the first request whose address contains part, in the order they went out.
    function indexOf(part as String) as Number {
        for (var i = 0; i < requests.size(); i++) {
            if ((requests[i][:url] as String).find(part) != null) {
                return i;
            }
        }
        return -1;
    }

    // The position of the first request whose address ends with suffix.
    function indexEnding(suffix as String) as Number {
        for (var i = 0; i < requests.size(); i++) {
            var url = requests[i][:url] as String;
            if (url.length() >= suffix.length() && (url.substring(url.length() - suffix.length(), url.length()) as String).equals(suffix)) {
                return i;
            }
        }
        return -1;
    }

    // Answers what the request in flight asks until an events request is the one in flight.
    function settleUntilEvents() as Void {
        for (var round = 0; round < 60; round++) {
            var url = onlyOpen();
            if (url.length() == 0 || url.find("/events") != null || url.find("/piece/") != null) {
                return;
            }
            replyOnly(200, {});
        }
    }

    // Answers the request in flight, again and again, with what its content does not matter for: events
    // with nothing new, the rest with an empty answer. Stops at a piece, which the test answers itself.
    function settle() as Void {
        for (var round = 0; round < 60; round++) {
            var url = onlyOpen();
            if (url.length() == 0 || url.find("/piece/") != null) {
                return;
            }
            if (url.find("/events") != null) {
                reply("/events", 200, {"cursor" => 0, "events" => []});
            } else {
                replyOnly(200, {});
            }
        }
    }
}

(:test)
class FakeIo {
    var client as CallClient? = null;
    var captures as Number = 0;
    var startResult as Number = 0;
    var played as Array<Number> = [];
    var cues as Array<Number> = [];
    var closedCalls as Number = 0;
    var busyNow as Boolean = false;

    function io() as CallIo {
        return new CallIo(method(:startCapture), method(:stopCapture), method(:play), method(:stopPlayback), method(:changed),
            method(:cue), method(:closed), method(:busy));
    }

    function cue(kind as Number) as Boolean {
        cues.add(kind);
        return true;
    }

    function busy() as Boolean {
        return busyNow;
    }

    function closed() as Void {
        closedCalls += 1;
    }

    function startCapture() as Number {
        if (startResult == 0) {
            captures += 1;
        }
        return startResult;
    }

    function stopCapture() as Void {
    }

    function play(n as Number, ms as Number, pcm as ByteArray) as Void {
        played.add(n);
    }

    // the screen's player reports back when it is stopped
    function stopPlayback() as Void {
        var c = client;
        if (c != null) {
            c.playbackIdle();
        }
    }

    function changed() as Void {
    }
}

(:test)
module Kit {
function opened(env as FakeEnv, io as FakeIo) as CallClient {
    Trace.lines = [];
    Trace.dropped = 0;
    Trace.reported = 0;
    var c = new CallClient(io.io(), env);
    io.client = c;
    c.start();
    c.tick();
    // the microphone delivers, which lets the open go out
    c.chunk(silence(10));
    c.tick();
    env.reply("voice/call", 201, {"call" => "c1"});
    return c;
}

function silence(n as Number) as ByteArray {
    var b = new [0]b;
    for (var i = 0; i < n; i++) {
        b.add(i % 200);
    }
    return b;
}
}

(:test)
function aCutLeavesRoomForTheNextAnswer(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    // the first turn is sent, then an answer of five pieces comes
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    env.settle();
    var events = [{"i" => 1, "state" => "generating"}];
    for (var n = 0; n < 5; n++) {
        events.add({"i" => 2 + n, "piece" => n, "ms" => 2000});
    }
    env.reply("/events", 200, {"cursor" => 6, "events" => events});
    for (var n = 0; n < 2; n++) {
        env.reply("/piece/" + n, 200, Kit.silence(30000));
    }
    var heldBack = !env.asked("/piece/2");
    // the answer is cut while two pieces are fetched and none has played
    c.press();
    c.chunk(Kit.silence(200));
    c.press();
    c.captureEnded();
    // the events request in flight brings the next answer's piece
    env.reply("/events", 200, {"cursor" => 8, "events" => [{"i" => 7, "state" => "generating"}, {"i" => 8, "piece" => 5, "ms" => 1000}]});
    env.settle();
    return heldBack && env.asked("/piece/5") && io.played.size() == 2;
}

(:test)
function aSlowAnswerNeverRestartsTheRecording(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    var recording = c.recording && io.captures == 1;
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    env.settle();
    // the press is taken, and nothing answers for twenty seconds
    for (var s = 1; s <= 20; s++) {
        env.clock = s * 1000;
        c.tick();
        env.settle();
    }
    return recording && io.captures == 1 && !c.recording;
}

(:test)
function aFailedMicrophoneStartIsTriedAgainWithStart(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    io.startResult = 2;
    var c = Kit.opened(env, io);
    var failed = !c.recording && c.stalled == null;
    io.startResult = 0;
    var pressed = c.press();
    return failed && pressed && c.recording && io.captures == 1;
}

(:test)
function theGoToneSoundsWhenTheMicrophoneDeliversInEveryTurn(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    // turn 1: the microphone delivered, the tone sounded then and not before
    var first = io.cues.size() == 1 && io.cues[0] == CallLogic.CUE_YOUR_TURN && c.micLive;
    c.chunk(Kit.silence(300));
    var once = io.cues.size() == 1;
    c.press();
    c.captureEnded();
    env.settle();
    // a one-piece answer; the player never says it stopped
    env.reply("/events", 200, {"cursor" => 3, "events" => [{"i" => 1, "state" => "generating"}, {"i" => 2, "piece" => 0, "ms" => 1500}, {"i" => 3, "state" => "listening"}]});
    env.reply("/piece/0", 200, Kit.silence(5000));
    var sentOnly = io.cues.size() == 2 && io.cues[1] == CallLogic.CUE_SENT;
    env.clock = 2500;
    c.tick();
    env.clock = 3000;
    c.tick();
    env.clock = 3600;
    c.tick();
    // turn 2: the microphone is on, but no tone and no "Speak" until it delivers
    var waiting = io.captures == 2 && c.recording && !c.micLive && io.cues.size() == 2;
    c.chunk(Kit.silence(100));
    var second = io.cues.size() == 3 && io.cues[2] == CallLogic.CUE_YOUR_TURN && c.micLive;
    return first && once && sentOnly && waiting && second;
}

(:test)
function theOpenWaitsForTheFirstMicrophoneDataButNotForever(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    Trace.lines = [];
    var c = new CallClient(io.io(), env);
    io.client = c;
    c.start();
    c.tick();
    env.clock = 2000;
    c.tick();
    var held = !env.asked("voice/call");
    env.clock = 2600;
    c.tick();
    var late = env.asked("voice/call");
    // and with data the open goes at once
    var env2 = new FakeEnv();
    var io2 = new FakeIo();
    var c2 = new CallClient(io2.io(), env2);
    io2.client = c2;
    c2.start();
    c2.chunk(Kit.silence(50));
    c2.tick();
    return held && late && env2.asked("voice/call");
}

(:test)
function piecesAreFetchedBeforePlayedReports(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    env.settle();
    env.reply("/events", 200, {"cursor" => 4, "events" => [{"i" => 1, "state" => "generating"}, {"i" => 2, "piece" => 0, "ms" => 500}, {"i" => 3, "piece" => 1, "ms" => 500}]});
    // a played report is waiting when piece 0 arrives and piece 1 is wanted
    c.piecePlayed(99);
    env.reply("/piece/0", 200, Kit.silence(3000));
    // the next request is the piece, not the report
    var next = env.onlyOpen();
    return next.find("/piece/1") != null;
}

(:test)
function listeningBeginsBeforeTheCallExistsAndItsAudioFollows(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    Trace.lines = [];
    var c = new CallClient(io.io(), env);
    io.client = c;
    c.start();
    // recording began at once, with no request answered
    var listening = c.recording && io.captures == 1 && !env.asked("/events");
    c.chunk(Kit.silence(100));
    c.tick();
    env.reply("voice/call", 201, {"call" => "c1"});
    var first = env.onlyOpen().find("/audio?turn=1&seq=0") != null;
    var firstBody = env.bodyOf("/audio");
    c.chunk(Kit.silence(50));
    env.replyOnly(200, {});
    var second = env.onlyOpen().find("seq=1") != null;
    var secondBody = env.bodyOf("/audio");
    return listening && first && firstBody != null && firstBody.size() == 100 && second && secondBody != null && secondBody.size() == 50;
}

(:test)
function aHangUpIsHeardByTheServerBeforeTheScreenLeaves(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.settle();
    env.clock = 1000;
    c.hangUp();
    // the events request that was in flight is forgotten; the hang-up is the only one now
    env.reply("/events", 200, {});
    var open = env.onlyOpen();
    var hangUp = open.length() > 0 && env.indexEnding("/c1") >= 0 && open.find("/events") == null;
    env.replyOnly(200, {});
    env.clock = 1100;
    c.tick();
    env.settle();
    env.clock = 1200;
    c.tick();
    return hangUp && io.closedCalls == 1 && env.indexOf("/log") > env.indexEnding("/c1");
}

(:test)
function requestsGoOneAtATimeInPriorityOrder(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.settle();
    // a turn that is sent, with the log full and events due, while one request is in flight
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    for (var i = 0; i < 25; i++) {
        Trace.add("x", null);
    }
    var order = [] as Array<String>;
    var shortWait = env.eventsWait() == 1;
    for (var step = 0; step < 4; step++) {
        env.replyOnly(200, {"cursor" => 0, "events" => []});
        var url = env.onlyOpen();
        if (url.find("/audio") != null) {
            order.add("audio");
        } else if (url.find("/command") != null) {
            order.add("command");
        } else if (url.find("/log") != null) {
            order.add("log");
        } else if (url.find("/events") != null) {
            order.add("events");
        } else {
            order.add("?" + url);
        }
    }
    return shortWait && order[0].equals("audio") && order[1].equals("command") && order[2].equals("log") && order[3].equals("events");
}

(:test)
function aPlayerThatIsStillPlayingKeepsTheClockFromEndingTheAnswer(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    env.settle();
    env.reply("/events", 200, {"cursor" => 3, "events" => [{"i" => 1, "state" => "generating"}, {"i" => 2, "piece" => 0, "ms" => 1500}, {"i" => 3, "state" => "listening"}]});
    env.reply("/piece/0", 200, Kit.silence(5000));
    // the piece is late on the watch: long past its length by the clock, the player still plays it
    io.busyNow = true;
    for (var t = 2000; t <= 6000; t += 500) {
        env.clock = t;
        c.tick();
    }
    var held = io.captures == 1 && !c.recording;
    io.busyNow = false;
    env.clock = 6500;
    c.tick();
    env.clock = 7000;
    c.tick();
    return held && io.captures == 2;
}

(:test)
function aPieceThatCannotPlayStopsListeningWithTheErrorCueOnce(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    c.playbackFailed(0);
    c.playbackFailed(0);
    var errors = 0;
    for (var i = 0; i < io.cues.size(); i++) {
        if (io.cues[i] == CallLogic.CUE_ERROR) {
            errors += 1;
        }
    }
    return errors == 1 && c.stalled != null && !c.recording;
}

(:test)
function afterABufferOverflowTheRestOfTheTurnIsDropped(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    Trace.lines = [];
    var c = new CallClient(io.io(), env);
    io.client = c;
    c.start();
    c.chunk(Kit.silence(30000));
    c.chunk(Kit.silence(30000));
    // this one does not fit; what follows would sit behind a hole
    c.chunk(Kit.silence(10000));
    c.chunk(Kit.silence(100));
    c.captureEnded();
    c.tick();
    env.reply("voice/call", 201, {"call" => "c1"});
    env.settle();
    return env.audioBytes == 60000;
}

(:test)
function theLogWaitsForTheLinkToBeIdle(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.settle();
    for (var i = 0; i < 25; i++) {
        Trace.add("x", null);
    }
    // the microphone is recording: audio and events have the link, the log waits
    env.replyOnly(200, {"cursor" => 0, "events" => []});
    env.replyOnly(200, {"cursor" => 0, "events" => []});
    var waited = !env.asked("/log");
    c.chunk(Kit.silence(200));
    c.press();
    c.captureEnded();
    env.settle();
    return waited && env.asked("/log");
}
