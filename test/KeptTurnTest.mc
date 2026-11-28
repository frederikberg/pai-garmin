import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.Test;
import Toybox.Time;

// The server's side of a kept turn, as docs/api.md describes it: it stores the parts of a turn by
// id across calls, says where a turn stands, and takes a turn once. It answers the request in
// flight, one per step.
(:test)
class FakeServer {
    var env as FakeEnv;
    // the bytes of every stored part, by turn id, in the order they were stored
    var sizes as Dictionary<String, Array<Number>> = {};
    var states as Dictionary<String, String> = {};
    // how often each turn was handed on
    var taken as Dictionary<String, Number> = {};
    var events as Array<Dictionary> = [];
    var index as Number = 0;
    var calls as Number = 0;
    // a press without "confirm" is held, as one pressed long ago
    var late as Boolean = false;
    // a press is answered "pressed", and the events bring "taken"
    var whole as Boolean = false;
    // this many presses end in an event saying the turn could not be read
    var unread as Number = 0;
    var presses as Array<Dictionary> = [];
    var drops as Array<String> = [];
    // the audio requests as [call's turn number, seq], in the order they came
    var audio as Array<Array<Number>> = [];
    var asks as Number = 0;

    function initialize(env as FakeEnv) {
        self.env = env;
    }

    function param(url as String, name as String) as String? {
        var at = url.find(name + "=");
        if (at == null) {
            return null;
        }
        var rest = url.substring(at + name.length() + 1, url.length()) as String;
        var stop = rest.find("&");
        return stop == null ? rest : rest.substring(0, stop) as String;
    }

    function total(id as String) as Number {
        var list = sizes[id];
        var n = 0;
        if (list != null) {
            for (var i = 0; i < list.size(); i++) {
                n += list[i];
            }
        }
        return n;
    }

    function stateOf(id as String) as String {
        var state = states[id];
        return state != null ? state : "unknown";
    }

    function emit(event as Dictionary) as Void {
        index += 1;
        event["i"] = index;
        events.add(event);
    }

    function press(id as String, confirm as Boolean) as String {
        var state = stateOf(id);
        if (state.equals("taken") || state.equals("dropped")) {
            return state;
        }
        if (late && !confirm) {
            states[id] = "held";
        } else if (unread > 0) {
            unread -= 1;
            states[id] = "pressed";
            emit({"turn" => {"id" => id, "state" => "pressed", "error" => "transcription_failed"}});
        } else if (whole) {
            states[id] = "pressed";
            take(id);
            emit({"turn" => {"id" => id, "state" => "taken"}});
        } else {
            take(id);
        }
        return states[id] as String;
    }

    function take(id as String) as Void {
        var n = taken[id];
        taken[id] = n == null ? 1 : n + 1;
        if (!whole) {
            states[id] = "taken";
        }
    }

    // Answers the request in flight; false when none is, or it is one this server does not answer.
    (:typecheck(false))
    function step() as Boolean {
        var requests = env.requests;
        for (var i = 0; i < requests.size(); i++) {
            var r = requests[i];
            if (!(r[:open] as Boolean)) {
                continue;
            }
            var url = r[:url] as String;
            if (url.find("/audio") != null) {
                var id = param(url, "&id") as String;
                var seq = (param(url, "&seq") as String).toNumber();
                audio.add([(param(url, "?turn") as String).toNumber(), seq]);
                var list = sizes[id];
                if (list == null) {
                    list = [];
                    sizes[id] = list;
                    states[id] = "open";
                }
                var state = stateOf(id);
                if (state.equals("taken") || state.equals("dropped")) {
                    answer(r, 409, {"turn" => state});
                } else if (seq > list.size()) {
                    answer(r, 409, {"next_seq" => list.size()});
                } else {
                    if (seq == list.size()) {
                        list.add((r[:body] as ByteArray).size());
                    }
                    if (param(url, "&end") != null) {
                        presses.add({"id" => id, "ago" => (param(url, "&ago") as String).toNumber(), "confirm" => false, "on" => "audio"});
                        answer(r, 200, {"next_seq" => list.size().toFloat(), "turn" => press(id, false)});
                    } else {
                        answer(r, 200, {"next_seq" => list.size().toFloat()});
                    }
                }
            } else if (url.find("/command") != null) {
                var body = r[:params] as Dictionary;
                var action = body["action"] as String;
                var id = body["id"] as String?;
                if (action.equals("turn") && id != null) {
                    asks += 1;
                    var list = sizes[id];
                    answer(r, 200, {"turn" => stateOf(id), "next_seq" => (list == null ? 0 : list.size()).toFloat()});
                } else if (action.equals("drop") && id != null) {
                    drops.add(id);
                    if (!stateOf(id).equals("taken")) {
                        states[id] = "dropped";
                    }
                    answer(r, 200, {"turn" => states[id]});
                } else if (action.equals("press") && id != null) {
                    var list = sizes[id];
                    var have = list == null ? 0 : list.size();
                    if ((body["chunks"] as Number) > have) {
                        answer(r, 409, {"next_seq" => have});
                    } else {
                        var confirm = body["confirm"] instanceof Boolean && body["confirm"];
                        presses.add({"id" => id, "ago" => body["ago"], "confirm" => confirm, "on" => "command"});
                        answer(r, 200, {"turn" => press(id, confirm)});
                    }
                } else {
                    answer(r, 200, {});
                }
            } else if (url.find("/events") != null) {
                var out = events;
                events = [];
                answer(r, 200, {"cursor" => index, "events" => out});
            } else if (url.find("/piece/") != null) {
                return false;
            } else if (url.find("/log") != null) {
                answer(r, 200, {});
            } else if (url.find("voice/call/") != null) {
                // the hang-up
                answer(r, 200, {});
            } else {
                calls += 1;
                answer(r, 201, {"call" => "c" + calls});
            }
            return true;
        }
        return false;
    }

    (:typecheck(false))
    function answer(r as Dictionary, code as Number, data as Object?) as Void {
        r[:open] = false;
        (r[:callback] as Method).invoke(code, data);
    }

    // Answers what is asked until nothing is in flight, or only an events request with nothing new.
    function drain() as Void {
        var idle = false;
        for (var i = 0; i < 400; i++) {
            var url = env.onlyOpen();
            if (url.length() == 0) {
                return;
            }
            var quiet = url.find("/events") != null && events.size() == 0;
            if (quiet && idle) {
                return;
            }
            idle = quiet;
            if (!step()) {
                return;
            }
        }
    }
}

(:test)
module KeptKit {
    // A call that is up, with its server, and the microphone delivering.
    function call(env as FakeEnv, io as FakeIo, server as FakeServer) as CallClient {
        Trace.lines = [];
        Trace.dropped = 0;
        Trace.reported = 0;
        var c = new CallClient(io.io(), env);
        io.client = c;
        c.start();
        c.tick();
        c.chunk(Kit.silence(10));
        c.tick();
        server.drain();
        return c;
    }

    // The next start of the app: what the run held in memory is gone, the storage is what it was.
    function relaunch() as Void {
        Kept.turns = [];
        Kept.held = {};
        Kept.loaded = false;
        Kept.onDisk = false;
    }

    // He speaks for s seconds, bytes a second, the clock ticking four times a second.
    function speak(env as FakeEnv, c as CallClient, s as Number, bytes as Number) as Void {
        for (var i = 0; i < s * 4; i++) {
            env.clock += 250;
            c.chunk(Kit.silence(bytes / 4));
            c.tick();
        }
    }

    // Time passes with nothing said.
    function wait(env as FakeEnv, c as CallClient, ms as Number) as Void {
        for (var t = 0; t < ms; t += 250) {
            env.clock += 250;
            c.tick();
        }
    }

    function cued(cues as Array<Number>, kind as Number) as Number {
        var n = 0;
        for (var i = 0; i < cues.size(); i++) {
            if (cues[i] == kind) {
                n += 1;
            }
        }
        return n;
    }

    function confirmed(press as Dictionary) as Boolean {
        var confirm = press["confirm"] as Object?;
        return confirm instanceof Boolean && confirm;
    }

    // The only turn the server knows.
    function onlyId(server as FakeServer) as String {
        var ids = server.sizes.keys();
        return ids.size() == 1 ? ids[0] as String : "";
    }

    // The audio requests came with consecutive numbers, a repeat allowed, never a gap.
    function inOrder(server as FakeServer) as Boolean {
        var next = 0;
        for (var i = 0; i < server.audio.size(); i++) {
            var seq = server.audio[i][1];
            if (seq > next) {
                return false;
            }
            next = seq == next ? next + 1 : next;
        }
        return true;
    }
}

(:test)
function aLinkThatAnswersNothingNeverStopsTheMicrophoneAndTheTurnFollowsOnce(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    // seventy seconds of speech at the watch's rate, and no request is answered
    KeptKit.speak(env, c, 70, 3660);
    var turn = Kept.waiting();
    var stored = turn != null ? Kept.num(turn, "stored") - Kept.num(turn, "sent") : 0;
    var face = CallScreen.face(c);
    var listening = c.recording && c.stalled == null && io.captures == 1 && face.headline.equals("Speak")
        && face.foot.find("keeping") != null;
    logger.debug("stored parts " + stored + ", in memory " + Kept.held.size() + ", foot " + face.foot);
    // the link is back: everything follows in order while he goes on, and his press ends it
    for (var i = 0; i < 20; i++) {
        server.drain();
        KeptKit.wait(env, c, 1000);
    }
    KeptKit.speak(env, c, 2, 3660);
    c.press();
    c.captureEnded();
    for (var i = 0; i < 10; i++) {
        server.drain();
        KeptKit.wait(env, c, 1000);
    }
    var id = KeptKit.onlyId(server);
    var all = server.total(id) == 10 + 72 * 3660;
    logger.debug("server has " + server.total(id) + " of " + (10 + 72 * 3660) + ", taken " + server.taken[id]);
    return listening && stored > 30 && Kept.held.size() <= 2 && all && KeptKit.inOrder(server) && server.taken[id] == 1
        && Kept.waiting() == null && KeptKit.cued(io.cues, CallLogic.CUE_SENT) == 1 && KeptKit.cued(io.cues, CallLogic.CUE_ERROR) == 0;
}

(:test)
function aPressWithoutTheLinkBuzzesKeptAndSentOnlyWhenTheServerHasTheTurn(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 2, 3660);
    server.drain();
    // the phone is gone, and he presses
    env.phone = false;
    KeptKit.speak(env, c, 3, 3660);
    c.press();
    c.captureEnded();
    KeptKit.wait(env, c, 500);
    var face = CallScreen.face(c);
    var kept = c.kept && face.headline.equals("Kept") && KeptKit.cued(io.cues, CallLogic.CUE_KEPT) == 1
        && KeptKit.cued(io.cues, CallLogic.CUE_SENT) == 0 && !c.press();
    // it is in storage with his press, whatever happens to the app
    var turn = Kept.waiting();
    var safe = turn != null && turn["pressed"] instanceof Number && Kept.held.size() == 0 && Storage.getValue(Kept.KEY) != null;
    // a minute later the phone is back: the turn goes by itself
    KeptKit.wait(env, c, 60000);
    var still = c.kept && c.stalled == null;
    env.phone = true;
    for (var i = 0; i < 12; i++) {
        KeptKit.wait(env, c, 1000);
        server.drain();
    }
    var id = KeptKit.onlyId(server);
    return kept && safe && still && server.total(id) == 10 + 5 * 3660 && server.taken[id] == 1 && !c.kept
        && KeptKit.cued(io.cues, CallLogic.CUE_SENT) == 1 && Kept.waiting() == null && Storage.getValue(Kept.KEY) == null;
}

(:test)
function aSlowAnswerToThePressBuzzesKeptAfterAFewSeconds(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 2, 3660);
    server.drain();
    c.press();
    c.captureEnded();
    // the request with the press is out, and nothing answers
    KeptKit.wait(env, c, 3500);
    var waiting = !c.kept && CallScreen.face(c).headline.equals("Sending") && io.cues.indexOf(CallLogic.CUE_KEPT) < 0;
    KeptKit.wait(env, c, 1000);
    var kept = c.kept && KeptKit.cued(io.cues, CallLogic.CUE_KEPT) == 1;
    server.drain();
    return waiting && kept && !c.kept && KeptKit.cued(io.cues, CallLogic.CUE_SENT) == 1 && server.taken[KeptKit.onlyId(server)] == 1;
}

(:test)
function aCallTheServerForgotIsReplacedAndTheSameTurnGoesOnInTheNewOne(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    server.whole = true;
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 3, 3660);
    server.drain();
    var id = KeptKit.onlyId(server);
    var before = (server.sizes[id] as Array<Number>).size();
    // the server was replaced: the next events request finds no call
    KeptKit.wait(env, c, 5000);
    env.reply("/events", 404, null);
    var listening = c.recording && io.captures == 1;
    KeptKit.speak(env, c, 3, 3660);
    for (var i = 0; i < 6; i++) {
        server.drain();
        KeptKit.wait(env, c, 500);
    }
    // the new call asked where the turn stands and went on with the next part, as its turn 1
    var last = server.audio[server.audio.size() - 1];
    var resumed = server.calls == 2 && server.asks == 1 && before >= 2 && last[0] == 1 && last[1] >= before && KeptKit.inOrder(server);
    c.press();
    c.captureEnded();
    server.drain();
    server.drain();
    logger.debug("calls " + server.calls + ", asks " + server.asks + ", parts before " + before + ", taken " + server.taken[id]);
    return listening && resumed && KeptKit.onlyId(server).equals(id) && server.total(id) == 10 + 6 * 3660
        && server.taken[id] == 1 && Kept.waiting() == null && KeptKit.cued(io.cues, CallLogic.CUE_SENT) == 1;
}

(:test)
function aRouteThatAnswersNotFoundHoldsTheAudioBackAndTheMicrophoneGoesOn(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    c.chunk(Kit.silence(2500));
    env.reply("/audio", 404, null);
    var held = c.recording && env.onlyOpen().find("/events") != null;
    // the events answer: the call is there, and the part goes again under its number
    server.drain();
    KeptKit.speak(env, c, 1, 3660);
    server.drain();
    c.press();
    c.captureEnded();
    server.drain();
    var id = KeptKit.onlyId(server);
    return held && io.captures == 1 && server.total(id) == 2510 + 3660 && KeptKit.inOrder(server) && server.taken[id] == 1;
}

(:test)
function aTurnTheCallEndedOnIsOfferedAtTheNextStartAndStartSendsItOnce(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 12, 3660);
    // the last parts never reach the server, and then it ends the call
    env.phone = false;
    KeptKit.speak(env, c, 6, 3660);
    env.phone = true;
    server.emit({"ended" => "idle"});
    for (var i = 0; i < 8; i++) {
        KeptKit.wait(env, c, 1000);
        server.drain();
    }
    var id = KeptKit.onlyId(server);
    var ended = c.closed() && !c.recording && server.total(id) < 10 + 18 * 3660 && server.drops.size() == 0;
    // the next start: what the run had in memory is gone
    KeptKit.relaunch();
    var io2 = new FakeIo();
    var c2 = new CallClient(io2.io(), env);
    io2.client = c2;
    c2.start();
    var face = CallScreen.face(c2);
    var offered = c2.asking && !c2.recording && io2.captures == 0 && face.headline.equals("Kept turn")
        && face.body.find("said ") != null && face.body.find(" · 0:1") != null && KeptKit.cued(io2.cues, CallLogic.CUE_KEPT) == 1;
    logger.debug("offer: " + face.body + " | " + face.hint);
    // the call opens and the server says where the turn stands, and nothing of it goes meanwhile
    KeptKit.wait(env, c2, 500);
    server.drain();
    var untouched = server.calls == 2 && server.asks == 1 && server.total(id) < 10 + 18 * 3660 && server.presses.size() == 0;
    // Start: it goes, with his word that it may run
    c2.press();
    for (var i = 0; i < 5; i++) {
        server.drain();
        KeptKit.wait(env, c2, 500);
    }
    var confirmed = server.presses.size() == 1 && KeptKit.confirmed(server.presses[0]);
    return ended && offered && untouched && server.total(id) == 10 + 18 * 3660 && KeptKit.inOrder(server)
        && confirmed && server.taken[id] == 1 && Kept.waiting() == null
        && !c2.asking && KeptKit.cued(io2.cues, CallLogic.CUE_SENT) == 1;
}

(:test)
function backOnAnOfferedTurnDropsItAndListeningBegins(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 12, 3660);
    server.drain();
    // the app ends in the middle of the turn
    c.appStopped();
    var id = KeptKit.onlyId(server);
    KeptKit.relaunch();
    var io2 = new FakeIo();
    var c2 = new CallClient(io2.io(), env);
    io2.client = c2;
    c2.start();
    var offered = c2.asking && io2.captures == 0;
    c2.answer(false);
    var listening = !c2.asking && c2.recording && io2.captures == 1;
    c2.chunk(Kit.silence(10));
    c2.tick();
    server.drain();
    return offered && listening && server.drops.size() == 1 && server.drops[0].equals(id) && server.stateOf(id).equals("dropped")
        && server.taken[id] == null && Kept.dropId() == null && Storage.getValue(Outbox.partKey(id, 0)) == null;
}

(:test)
function aHangUpDropsAShortTurnAndKeepsALongOne(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 3, 3660);
    server.drain();
    var id = KeptKit.onlyId(server);
    c.bye();
    // the drop goes to the call before the hang-up
    var first = env.onlyOpen().find("/command") != null;
    server.drain();
    var dropped = first && server.drops.size() == 1 && server.drops[0].equals(id) && Kept.waiting() == null && Kept.dropId() == null
        && io.closedCalls == 1;
    // a long one stays, with everything the server lacks in storage
    var env2 = new FakeEnv();
    var io2 = new FakeIo();
    var server2 = new FakeServer(env2);
    var c2 = KeptKit.call(env2, io2, server2);
    KeptKit.speak(env2, c2, 11, 3660);
    c2.bye();
    server2.drain();
    var turn = Kept.waiting();
    return dropped && server2.drops.size() == 0 && turn != null && Kept.held.size() == 0 && Kept.num(turn, "ms") >= 10000
        && Storage.getValue(Kept.KEY) != null && io2.closedCalls == 1;
}

(:test)
function aTurnTheServerHoldsBackAsOldAsksAndStartConfirmsIt(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    server.late = true;
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 2, 3660);
    c.press();
    c.captureEnded();
    server.drain();
    var face = CallScreen.face(c);
    var asked = c.asking && !c.recording && face.headline.equals("Kept turn") && KeptKit.cued(io.cues, CallLogic.CUE_KEPT) == 1
        && server.taken.size() == 0;
    // nothing runs by itself, however long he waits
    KeptKit.wait(env, c, 30000);
    server.drain();
    var waits = c.asking && server.taken.size() == 0 && io.captures == 1;
    c.press();
    server.drain();
    var id = KeptKit.onlyId(server);
    var last = server.presses[server.presses.size() - 1];
    return asked && waits && !c.asking && KeptKit.confirmed(last) && server.taken[id] == 1 && KeptKit.cued(io.cues, CallLogic.CUE_SENT) == 1;
}

(:test)
function aTurnTheServerCouldNotReadIsPressedAgainAndThenAsked(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    server.unread = 1;
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 2, 3660);
    c.press();
    c.captureEnded();
    server.drain();
    var once = server.presses.size() == 1 && Kept.waiting() != null && !c.asking;
    // the press goes again by itself after a wait, and this time the turn is taken
    KeptKit.wait(env, c, 6000);
    server.drain();
    var id = KeptKit.onlyId(server);
    var again = server.presses.size() == 2 && server.taken[id] == 1 && Kept.waiting() == null;
    // one that keeps failing ends with him being asked
    var env2 = new FakeEnv();
    var io2 = new FakeIo();
    var server2 = new FakeServer(env2);
    server2.unread = 5;
    var c2 = KeptKit.call(env2, io2, server2);
    KeptKit.speak(env2, c2, 2, 3660);
    c2.press();
    c2.captureEnded();
    for (var i = 0; i < 4; i++) {
        server2.drain();
        KeptKit.wait(env2, c2, 6000);
    }
    return once && again && c2.asking && server2.presses.size() == 3 && server2.taken.size() == 0 && Kept.waiting() != null;
}

(:test)
function aMicrophoneErrorKeepsWhatWasSaid(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    KeptKit.speak(env, c, 12, 3660);
    c.captureFailed(3);
    var turn = Kept.waiting();
    return !c.recording && turn != null && Kept.held.size() == 0 && Kept.num(turn, "parts") > 0;
}

(:test)
function aFullStorageEndsTheRecordingAndKeepsTheTurn(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    OutboxKit.clear();
    Outbox.loaded = true;
    // room for a handful of parts only
    Outbox.budget = 3 * Outbox.PART_BYTES + 5 * Kept.PART_MAX;
    var c = KeptKit.call(env, io, server);
    env.phone = false;
    KeptKit.speak(env, c, 30, 3660);
    var turn = Kept.waiting();
    var full = !c.recording && c.kept && turn != null && turn["pressed"] instanceof Number && c.stalled == null;
    Outbox.budget = Outbox.BUDGET_BYTES;
    // with the phone back the turn goes, nothing of what was recorded missing
    env.phone = true;
    for (var i = 0; i < 10; i++) {
        KeptKit.wait(env, c, 1000);
        server.drain();
    }
    var id = KeptKit.onlyId(server);
    OutboxKit.clear();
    return full && server.taken[id] == 1 && server.total(id) > 5 * Kept.PART_MAX && Kept.waiting() == null;
}

(:test)
function aLongHideWithoutTheLinkKeepsTheTurnWithItsPress(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var io = new FakeIo();
    var server = new FakeServer(env);
    var c = KeptKit.call(env, io, server);
    env.phone = false;
    KeptKit.speak(env, c, 4, 3660);
    c.endAfterTurn();
    c.captureEnded();
    KeptKit.wait(env, c, 21000);
    var turn = Kept.waiting();
    return c.closed() && turn != null && turn["pressed"] instanceof Number && Kept.held.size() == 0;
}

(:test)
function aKeptTurnComesBackFromStorageAsItWas(logger as Logger) as Boolean {
    var env = new FakeEnv();
    var turn = Kept.open();
    Kept.add(turn, Kit.silence(100));
    Kept.add(turn, Kit.silence(200));
    Kept.add(turn, Kit.silence(300));
    Kept.confirm(turn, 1);
    var inMemory = Storage.getValue(Kept.KEY) == null && Kept.unsent(turn) == 2;
    turn["pressed"] = 1234;
    var ok = Kept.persist(turn);
    // a part cut afterwards stays in memory and does not come back
    Kept.add(turn, Kit.silence(400));
    var id = turn["id"] as String;
    KeptKit.relaunch();
    var back = Kept.waiting();
    var same = back != null && id.equals(back["id"]) && Kept.num(back, "sent") == 1 && Kept.num(back, "parts") == 3
        && back["pressed"] == 1234;
    var part = back != null ? Kept.partOf(back, 2) : null;
    var parts = part != null && part.size() == 300 && back != null && Kept.partOf(back, 0) == null;
    // the server took the turn: nothing of it stays
    if (back != null) {
        Kept.forget(back);
    }
    OutboxKit.swept();
    return inMemory && ok && same && parts && Kept.waiting() == null && Storage.getValue(Kept.KEY) == null
        && Storage.getValue(Outbox.partKey(id, 1)) == null && Storage.getValue(Outbox.partKey(id, 2)) == null;
}
