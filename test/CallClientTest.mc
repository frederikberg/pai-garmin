import Toybox.Lang;
import Toybox.Test;

// Present in a unit test build only: the app sees it and opens the menu, never a call.
(:test)
module UnderTest {
}

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

    // How many requests are in flight.
    function inFlight() as Number {
        var count = 0;
        for (var i = 0; i < requests.size(); i++) {
            if (requests[i][:open] as Boolean) {
                count += 1;
            }
        }
        return count;
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
    var flushOnStop as ByteArray? = null;

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

    // a microphone that hands over its last data, in two windows, and says it stopped before stop returns
    function stopCapture() as Void {
        var c = client;
        var tail = flushOnStop;
        if (c != null && tail != null) {
            flushOnStop = null;
            c.chunk(tail.slice(0, tail.size() / 2));
            c.chunk(tail.slice(tail.size() / 2, null));
            c.captureEnded();
        }
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
    c.chunk(Kit.silence(2100));
    c.tick();
    env.reply("voice/call", 201, {"call" => "c1"});
    var first = env.onlyOpen().find("/audio?turn=1&seq=0") != null;
    var firstBody = env.bodyOf("/audio");
    c.chunk(Kit.silence(50));
    env.replyOnly(200, {});
    // a little audio waits for more while he speaks, and goes when the turn is over
    var waits = env.inFlight() == 0;
    c.press();
    c.captureEnded();
    var second = env.onlyOpen().find("seq=1") != null;
    var secondBody = env.bodyOf("/audio");
    return listening && first && firstBody != null && firstBody.size() == 2100 && waits && second && secondBody != null && secondBody.size() == 50;
}

(:test)
function aHangUpIsHeardByTheServerAndThenTheScreenLeavesAtOnce(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.clock = 6000;
    c.tick();
    var polling = env.onlyOpen().find("/events") != null;
    Trace.add("x", null);
    c.hangUp();
    // the events request that was in flight is forgotten; the hang-up is the only one now
    env.reply("/events", 200, {});
    var open = env.onlyOpen();
    var hangUp = open.length() > 0 && env.indexEnding("/c1") >= 0 && open.find("/events") == null;
    var waiting = io.closedCalls == 0;
    env.replyOnly(200, {});
    // nothing else is waited for: the log's rest is kept for the exit
    return polling && hangUp && waiting && io.closedCalls == 1 && env.inFlight() == 0 && !env.asked("/log");
}

(:test)
function aHangUpNobodyAnswersLeavesAfterAShortWait(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.clock = 1000;
    c.hangUp();
    env.clock = 2500;
    c.tick();
    var waiting = io.closedCalls == 0;
    env.clock = 3100;
    c.tick();
    return waiting && io.closedCalls == 1;
}

(:test)
function requestsGoOneAtATimeInPriorityOrder(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    // a turn that is sent, with the log full, while one request is in flight
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    for (var i = 0; i < 25; i++) {
        Trace.add("x", null);
    }
    var order = [] as Array<String>;
    for (var step = 0; step < 4; step++) {
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
        env.replyOnly(200, {"cursor" => 0, "events" => []});
    }
    // the answer is waited for with the events, and the log stays behind them
    return order[0].equals("audio") && order[1].equals("command") && order[2].equals("events") && order[3].equals("events")
        && env.eventsWait() == 1;
}

(:test)
function whileHeSpeaksTheEventsAreAskedOnlyNowAndThenAndWithoutAWait(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    var quiet = true;
    for (var t = 250; t <= 4750; t += 250) {
        env.clock = t;
        c.tick();
        quiet = quiet && env.inFlight() == 0;
    }
    env.clock = 5250;
    c.tick();
    var asked = env.onlyOpen().find("/events") != null && env.eventsWait() == 0;
    env.replyOnly(200, {"cursor" => 0, "events" => []});
    return c.recording && quiet && asked && env.inFlight() == 0;
}

(:test)
function theSentCueComesSoonAfterThePressEvenIfTheCaptureNeverSaysItStopped(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    c.chunk(Kit.silence(300));
    env.clock = 1000;
    c.press();
    env.clock = 1100;
    c.tick();
    var notYet = io.cues.indexOf(CallLogic.CUE_SENT) < 0;
    env.clock = 1400;
    c.tick();
    var sent = io.cues.indexOf(CallLogic.CUE_SENT) >= 0;
    var n = io.cues.size();
    c.captureEnded();
    env.clock = 1700;
    c.tick();
    return notYet && sent && io.cues.size() == n;
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
function theLogGoesWhileTheAnswerPlays(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    for (var i = 0; i < 25; i++) {
        Trace.add("x", null);
    }
    c.chunk(Kit.silence(200));
    c.press();
    c.captureEnded();
    env.settleUntilEvents();
    env.reply("/events", 200, {"cursor" => 2, "events" => [{"i" => 1, "state" => "generating"}, {"i" => 2, "state" => "speaking"}]});
    env.reply("/events", 200, {"cursor" => 3, "events" => [{"i" => 3, "piece" => 0, "ms" => 3000}]});
    // his turn, the wait for the answer and the piece on its way all had the link to themselves
    var waited = !env.asked("/log") && env.onlyOpen().find("/piece/0") != null;
    env.replyOnly(200, Kit.silence(3000));
    return waited && io.played.size() == 1 && env.onlyOpen().find("/log") != null;
}

(:test)
function theNextTurnStartsAsSoonAsTheLastPieceEnds(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    env.settle();
    env.clock = 5000;
    env.reply("/events", 200, {"cursor" => 3, "events" => [{"i" => 1, "state" => "generating"}, {"i" => 2, "piece" => 0, "ms" => 1500}, {"i" => 3, "state" => "listening"}]});
    env.reply("/piece/0", 200, Kit.silence(5000));
    var waiting = io.captures == 1 && !c.recording;
    // the player finishes the last piece, and nothing else happens: no tick, no event
    c.piecePlayed(0);
    c.playbackIdle();
    c.answerEnded();
    return waiting && io.captures == 2 && c.recording;
}

(:test)
function aStallOfTheClockIsTraced(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    Trace.lines = [];
    env.clock = 1000;
    c.tick();
    env.clock = 1250;
    c.tick();
    var quiet = Trace.lines.size() == 0;
    env.clock = 5000;
    c.tick();
    var last = Trace.lines.size() > 0 ? Trace.lines[Trace.lines.size() - 1] : null;
    return quiet && last != null && (last["ev"] as String).equals("stall") && (last["gap_ms"] as Number) == 3750;
}

(:test)
function aMicrophoneThatFlushesInsideItsStopSendsTheRestInOneRequest(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    c.chunk(Kit.silence(300));
    io.flushOnStop = Kit.silence(120);
    c.press();
    // nothing went out from inside the stop: one request carries what was waiting and the tail
    var body = env.bodyOf("/audio");
    var whole = env.inFlight() == 1 && body != null && body.size() == 430;
    env.replyOnly(200, {});
    return whole && env.onlyOpen().find("/command") != null;
}

(:test)
function theScreenChangesWithTheCallAndNotWithEveryAnswer(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    Trace.lines = [];
    var c = new CallClient(io.io(), env);
    io.client = c;
    c.start();
    // the microphone is on but has not delivered: he must not speak yet
    var wait = CallScreen.face(c).headline;
    c.chunk(Kit.silence(300));
    c.tick();
    env.reply("voice/call", 201, {"call" => "c1"});
    var speak = CallScreen.face(c);
    c.press();
    c.captureEnded();
    var sending = CallScreen.face(c).headline;
    env.settleUntilEvents();
    env.reply("/events", 200, {"cursor" => 2, "events" => [{"i" => 1, "heard" => "add milk"}, {"i" => 2, "state" => "generating"}]});
    var thinking = CallScreen.face(c);
    // polls that bring nothing leave the picture as it is
    env.reply("/events", 200, {"cursor" => 2, "events" => []});
    env.reply("/events", 200, {"cursor" => 2, "events" => []});
    var same = CallScreen.face(c).key().equals(thinking.key());
    env.reply("/events", 200, {"cursor" => 3, "events" => [{"i" => 3, "state" => "speaking"}]});
    var speaking = CallScreen.face(c);
    // two grey states differ by their word alone
    var a = new Face();
    a.headline = "Wait";
    var b = new Face();
    b.headline = "Connecting";
    if (a.key().equals(b.key())) {
        return false;
    }
    return wait.equals("Wait") && speak.headline.equals("Speak") && sending.equals("Sending")
        && thinking.headline.equals("Thinking") && thinking.body.equals("add milk") && same
        && speaking.headline.equals("Speaking") && !speaking.key().equals(thinking.key())
        && !speak.key().equals(thinking.key());
}
