import Toybox.Lang;
import Toybox.Test;

// The device the client talks to, replaced by a recorder: requests wait until the test answers them,
// and time moves when the test says so.
(:test)
class FakeEnv extends CallEnv {
    var clock as Number = 0;
    var requests as Array<Dictionary> = [];

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

    function startClock(tick as Method() as Void, ms as Number) as Void {
    }

    function stopClock() as Void {
    }

    (:typecheck(false))
    function request(url as String, params as Object?, options as Dictionary, callback as Method) as Void {
        requests.add({:url => url, :callback => callback, :open => true});
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

    // Answers what the answer's content does not matter for, until nothing of the kind is open.
    function settle() as Void {
        var again = true;
        var rounds = 0;
        while (again && rounds < 30) {
            rounds += 1;
            again = reply("/command", 200, {}) || reply("/audio", 200, {}) || reply("/played", 200, {}) || reply("/log", 200, {});
        }
    }
}

(:test)
class FakeIo {
    var client as CallClient? = null;
    var captures as Number = 0;
    var startResult as Number = 0;
    var played as Array<Number> = [];

    function io() as CallIo {
        return new CallIo(method(:startCapture), method(:stopCapture), method(:play), method(:stopPlayback), method(:changed));
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
    var events = [{"i" => 1, "state" => "listening"}];
    for (var n = 0; n < 5; n++) {
        events.add({"i" => 2 + n, "piece" => n, "ms" => 2000});
    }
    env.reply("/events", 200, {"cursor" => 6, "events" => events});
    for (var n = 0; n < 3; n++) {
        env.reply("/piece/" + n, 200, Kit.silence(64000));
    }
    var heldBack = !env.asked("/piece/3");
    // the answer is cut while three pieces are fetched and none has played
    c.press();
    c.chunk(Kit.silence(200));
    c.press();
    c.captureEnded();
    env.settle();
    // the next answer's piece must be fetched
    env.reply("/events", 200, {"cursor" => 8, "events" => [{"i" => 7, "state" => "generating"}, {"i" => 8, "piece" => 5, "ms" => 1000}]});
    return heldBack && env.asked("/piece/5") && io.played.size() == 3;
}

(:test)
function aSlowAnswerNeverRestartsTheRecording(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.reply("/events", 200, {"cursor" => 1, "events" => [{"i" => 1, "state" => "listening"}]});
    env.clock = 500;
    c.tick();
    var recording = c.recording && io.captures == 1;
    c.chunk(Kit.silence(300));
    c.press();
    c.captureEnded();
    env.settle();
    // the press is taken, and nothing answers for twenty seconds
    for (var s = 1; s <= 20; s++) {
        env.clock = 500 + s * 1000;
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
    env.reply("/events", 200, {"cursor" => 1, "events" => [{"i" => 1, "state" => "listening"}]});
    env.clock = 500;
    c.tick();
    var failed = !c.recording && c.stalled == null;
    io.startResult = 0;
    var pressed = c.press();
    return failed && pressed && c.recording && io.captures == 1;
}
