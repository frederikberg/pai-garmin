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
        requests.add({:url => url, :params => params, :callback => callback, :open => true});
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
    // the events request in flight brings the next answer's piece
    env.reply("/events", 200, {"cursor" => 8, "events" => [{"i" => 7, "state" => "generating"}, {"i" => 8, "piece" => 5, "ms" => 1000}]});
    env.settle();
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

(:test)
function recordingBeginsEvenWhenThePlayerNeverSaysItStopped(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.reply("/events", 200, {"cursor" => 2, "events" => [{"i" => 1, "state" => "listening"}, {"i" => 2, "piece" => 0, "ms" => 1133}]});
    env.reply("/piece/0", 200, Kit.silence(36322));
    var played = io.played.size() == 1;
    env.clock = 1000;
    c.tick();
    var waiting = io.captures == 0;
    // the piece is over by the clock, then the pause before listening
    env.clock = 2000;
    c.tick();
    env.clock = 2500;
    c.tick();
    env.settle();
    return played && waiting && io.captures == 1 && env.asked("/played");
}

(:test)
function requestsGoOneAtATimeInPriorityOrder(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var c = Kit.opened(env, io);
    env.reply("/events", 200, {"cursor" => 1, "events" => [{"i" => 1, "state" => "listening"}]});
    env.clock = 500;
    c.tick();
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
