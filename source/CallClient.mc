import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;

// What the client takes from the device: the clock, the request queue, the setup and the launch
// gate. The screen uses this one; a test supplies its own.
class CallEnv {
    private var _clock as Timer.Timer = new Timer.Timer();

    function now() as Number {
        return System.getTimer();
    }

    // 0 when requests can go out, 1 when the server is not set up, 2 when there is no phone.
    function check() as Number {
        if (!ServerConfig.isSet()) {
            return 1;
        }
        return System.getDeviceSettings().phoneConnected ? 0 : 2;
    }

    function baseUrl() as String {
        return ServerConfig.url();
    }

    // The "debug log" setting.
    function debugLog() as Boolean {
        return ServerConfig.debugLog();
    }

    // The check for a ringing alarm at launch counts as a request in flight until it is over.
    function gateOpen() as Boolean {
        return Gate.open;
    }

    function startClock(tick as Method() as Void, ms as Number) as Void {
        _clock.start(tick, ms, true);
    }

    function stopClock() as Void {
        _clock.stop();
    }

    // The request options are a plain dictionary, which the strict check cannot match to
    // makeWebRequest's.
    (:typecheck(false))
    function request(url as String, params as Object?, options as Dictionary, callback as Method) as Void {
        Communications.makeWebRequest(url, params, options, callback);
    }

    // Drops the app's requests in flight; their answers never come.
    function cancelRequests() as Void {
        Communications.cancelAllRequests();
    }
}

// The audio side of a call, as the client sees it: methods the screen supplies.
class CallIo {
    // 0 when recording began, 1 when the watch cannot capture Ogg Opus, 2 when it failed to start
    var startCapture as Method() as Number;
    var stopCapture as Method() as Void;
    var play as Method(n as Number, ms as Number, pcm as ByteArray) as Void;
    var stopPlayback as Method() as Void;
    var changed as Method() as Void;
    // plays one of the watch's own cues (CallLogic.CUE_*)
    // (false when it could not play, then it is asked for again)
    var cue as Method(kind as Number) as Boolean;
    // the hang-up is over: the screen may leave
    var closed as Method() as Void;
    // the player is playing a piece: it, not the client's clock, says when the answer is over
    var busy as Method() as Boolean;

    function initialize(startCapture as Method() as Number, stopCapture as Method() as Void,
            play as Method(n as Number, ms as Number, pcm as ByteArray) as Void, stopPlayback as Method() as Void,
            changed as Method() as Void, cue as Method(kind as Number) as Boolean, closed as Method() as Void,
            busy as Method() as Boolean) {
        self.cue = cue;
        self.closed = closed;
        self.busy = busy;
        self.startCapture = startCapture;
        self.stopCapture = stopCapture;
        self.play = play;
        self.stopPlayback = stopPlayback;
        self.changed = changed;
    }
}

// One kind of request. At most one is in flight per lane, and a failed one is tried again after a
// growing wait; a late answer of a request the watchdog gave up on carries an old token and is ignored.
class Lane {
    var name as String;
    var watchdogMs as Number;
    var busy as Boolean = false;
    var failures as Number = 0;
    var notBefore as Number = 0;
    var sentAt as Number = 0;
    var token as Number = 0;
    // requests in flight, itself included, when the last one went out
    var crowd as Number = 0;

    function initialize(name as String, watchdogMs as Number) {
        self.name = name;
        self.watchdogMs = watchdogMs;
    }
}

// A Computer call over plain web requests: it opens the call, streams the Ogg Opus chunks of each
// turn, sends the press that ends a turn or cuts an answer, long-polls the call's events, fetches the
// answer's pieces for the screen to play and reports what played on the next request. Lanes keep their
// own retry state; a call the server no longer knows (404) is replaced by a new one. A turn has an id
// of its own and is kept (Kept) until the server has taken it: no failed request, lost call or ended
// call stops its recording or deletes it, a new call goes on with it where the server's copy ends,
// and one an earlier run left is offered before anything else. Every failure and retry goes to the
// server's log route.
class CallClient {
    // The phone link carries one request at a time, so a long wait would hold up everything behind
    // it: the events are asked for with a short wait, and the rest goes first.
    const POLL_WAIT_S = 1;
    const MAX_PARALLEL = 1;
    // how long a press holds back for the played reports that belong before it
    const PRESS_HOLD_MS = 1500;
    const TICK_MS = 250;
    // a part the server has not confirmed stays in memory this long, then goes to storage
    const HOLD_MS = 3000;
    // with no answer to his press this long after the microphone stopped, the turn counts as kept
    const KEPT_AFTER_MS = 4000;
    // a turn left without a press is kept when he spoke at least this long, and dropped otherwise
    const LEAVE_KEEP_MS = 10000;
    // a press whose turn the server could not turn into text goes again this often, this far apart
    const PRESS_TRIES = 3;
    const PRESS_RETRY_MS = 5000;
    // the last line says how much the watch is keeping once the server is this far behind
    const BEHIND_SHOW_MS = 5000;
    // fetched but not yet played audio: the piece playing and the next ones
    const UNPLAYED_MAX = 60000;
    const PIECE_TRIES = 6;
    // a piece whose answer did not come in time this often is given up
    const PIECE_TIMEOUTS = 2;
    // with no answer from the server for this long while requests fail, a call with no turn of his
    // open stops and says so
    const LINK_LOST_MS = 40000;
    // failed turns in a row before recording stops and the cause is shown
    const MAX_FAILS = 5;
    // a request slower than this is logged with its round trip; of the rest, every 20th
    const SLOW_MS = 3000;
    // the events go ahead of the rest when they have waited this long for the one slot
    const EVENTS_MAX_GAP_MS = 5000;
    // a piece is over this long after its length even if the player never says so
    const PLAY_SLACK_MS = 800;
    const LOSS_WINDOW_MS = 20000;
    const MAX_LOSSES = 5;
    const NOTICE_MS = 4000;
    const STOP_WAIT_MS = 1500;
    const LOG_BATCH = 20;
    const LOG_EVERY_MS = 15000;
    // after a failure the log goes out sooner, but not sooner than this after the last one
    const LOG_URGENT_MS = 5000;
    const MEM_EVERY_MS = 15000;
    // a hang-up waits at most this long for the server to hear it
    const HANG_GRACE_MS = 2000;
    // a turn sent because the app was hidden too long waits at most this long for the server
    const HANG_AFTER_TURN_MS = 20000;
    // the open is tried this often before a call with no turn of his open is given up
    const OPEN_TRIES = 5;
    // while the phone link is missing the open asks for it every PHONE_POLL_MS, and a call with no
    // turn of his open gives up after this long
    const PHONE_WAIT_MS = 60000;
    const PHONE_POLL_MS = 1000;
    // the open waits for the first microphone data, but not longer than this
    const OPEN_WAIT_MS = 2500;
    // audio goes out once this much is waiting, or when the turn is over: about a second of Opus a request
    const AUDIO_MIN = 2048;
    // after the press the rest of the audio waits this long for the capture to hand over its last data,
    // so that one request carries all of it
    const TAIL_WAIT_MS = 400;
    // an answer's first pieces are asked for before the events announce them: this many of them, the
    // first with the longer wait on the server (it is still being made), the others with the shorter
    // one and only once (the piece before plays meanwhile)
    const AHEAD_PIECES = 2;
    const PIECE_WAIT_S = 2;
    const NEXT_WAIT_S = 1;
    // a gap between clock ticks longer than this is traced
    const STALL_MS = 1500;
    // the length of a piece the server did not give one for
    const PIECE_MS_DEFAULT = 8000;

    enum {
        OPEN,
        EVENTS,
        CMD,
        AUDIO,
        PIECE,
        LOG,
        HANG
    }

    private var _io as CallIo;
    private var _env as CallEnv;
    private var _lanes as Array<Lane> = [
        new Lane("open", 20000), new Lane("events", 15000), new Lane("command", 20000), new Lane("audio", 20000),
        new Lane("piece", 12000), new Lane("log", 20000), new Lane("hang", 10000)
    ];
    private var _inflight as Number = 0;
    private var _closing as Boolean = false;
    private var _closedAt as Number = 0;

    // what the screen shows
    var fatal as String? = null;
    var engine as String = "";
    var heard as String = "";
    var notice as String? = null;
    private var _noticeUntil as Number = 0;
    // the sentence of Computer's answer that is playing
    var spoken as String = "";
    // the server ended the call: what still plays finishes, then the watch hangs up
    private var _ending as Boolean = false;
    // why recording stopped for good until Start is pressed
    var stalled as String? = null;
    var recording as Boolean = false;
    // the microphone has delivered data in this turn: from then on the screen says "Speak"
    var micLive as Boolean = false;
    var recordingSince as Number = 0;
    var playbackActive as Boolean = false;

    private var _call as String? = null;
    private var _lastEvent as Number = 0;
    private var _cursor as Number = 0;
    private var _lastPiece as Number = -1;
    private var _pieces as Array<Dictionary<String, Number>> = [];
    private var _pieceTries as Number = 0;
    // the piece whose answers did not come in time, and how often
    private var _timeoutN as Number = -1;
    private var _pieceTimeouts as Number = 0;
    // when requests began to fail without any answer since, -1 while answers come
    private var _failingSince as Number = -1;
    private var _unplayed as Number = 0;
    private var _sizes as Dictionary<Number, Number> = {};
    private var _playedQueue as Array<Number> = [];

    private var _turn as Number = 0;
    private var _turnBytes as Number = 0;
    // the turn being recorded or on its way, until the server has taken it
    private var _kept as Dictionary<String, Object?>? = null;
    // a kept turn waits for his word: Start sends it, Back drops it
    var asking as Boolean = false;
    // he pressed, and the turn waits on the watch for the link
    var kept as Boolean = false;
    // he said yes to a turn the server holds back as old
    private var _confirm as Boolean = false;
    // the server is asked where the turn stands before any more of it goes, and that question is out
    private var _sync as Boolean = false;
    private var _syncOut as Boolean = false;
    // the turn's press is queued or out as a command
    private var _pressOut as Boolean = false;
    // the dropped turn whose command is queued or out
    private var _dropOut as String? = null;
    // the command in flight
    private var _cmdOut as Dictionary<String, Object>? = null;
    // the server has the whole turn and is turning it into text
    private var _transcribing as Boolean = false;
    private var _pressTries as Number = 0;
    private var _pressNotBefore as Number = 0;
    // while hanging up, the drop of the turn he left was sent to the call once
    private var _dropTried as Boolean = false;
    // when the microphone stopped after his press
    private var _stoppedAt as Number = 0;
    // when the server last had every part cut so far
    private var _caughtUpAt as Number = 0;
    // parts went to storage since then
    private var _behind as Boolean = false;
    private var _chunks as Array<ByteArray> = [];
    private var _chunkBytes as Number = 0;
    private var _body as ByteArray? = null;
    private var _endPending as Boolean = false;
    private var _captureOpen as Boolean = false;
    private var _stopAt as Number = 0;
    private var _turnSent as Boolean = false;
    private var _turnSentPoll as Number = -1;
    private var _pollsSent as Number = 0;
    private var _pollNo as Number = 0;
    private var _lastEventsAt as Number = 0;
    private var _fed as Array<Array<Number>> = [];
    private var _playEnd as Number = 0;
    private var _reported as Dictionary<Number, Boolean> = {};
    private var _logUrgent as Boolean = false;
    private var _openAfter as Number = 0;
    private var _micSeen as Boolean = false;
    private var _goPending as Boolean = false;
    private var _turnStartedAt as Number = 0;
    private var _micMs as Number = -1;
    private var _openSentAt as Number = 0;
    private var _openMs as Number = -1;
    // when the open first found no phone link, -1 while it has one
    private var _noPhoneSince as Number = -1;
    // the app was hidden too long: the turn being spoken goes as a press, then the call hangs up;
    // -1 while not
    private var _hangAfterTurnAt as Number = -1;
    private var _pieceN as Number = 0;
    private var _gapMax as Number = 0;
    private var _starvedN as Number = 0;
    // the turn's times for its summary: the press, then how long after it the capture stopped, the
    // server had the press, the first piece was known, and the first sound played
    private var _pressAt as Number = 0;
    private var _stopMs as Number = -1;
    private var _sentMs as Number = -1;
    private var _pieceMs as Number = -1;
    private var _fetchMs as Number = -1;
    private var _soundMs as Number = -1;
    private var _stored as Boolean = false;
    private var _stopping as Boolean = false;
    // the sentences of Computer's pieces by number, until each one plays
    private var _texts as Dictionary<Number, String> = {};
    // who answers: "computer", or a session's call the call was handed to, with the session's title
    var owner as String = "computer";
    var sessionTitle as String = "";
    // the press that ends the current turn (0 before there is one), and the one riding on the audio
    // request in flight
    private var _endPress as Number = 0;
    private var _bodyEnd as Number = 0;
    // the played report riding on the events request and on the piece request in flight
    private var _riding as Array<Number> = [-1, -1];
    // the answer's first piece is asked for before the events announce it; after a wait that brought
    // none, the events are asked once before the next
    private var _expectPiece as Boolean = false;
    // how many pieces of this answer may still be asked for ahead
    private var _ahead as Number = 0;
    private var _eventsFirst as Boolean = false;
    // the piece being fetched: its number, its length in ms, and whether it was asked for unannounced
    private var _fetchN as Number = -1;
    private var _fetchLen as Number = 0;
    private var _fetchSpec as Boolean = false;
    private var _backs as Number = 0;
    // Back was pressed in a session's call: no turn starts until Computer has the call again
    private var _leaving as Boolean = false;
    // the back command waits until the audio of the turn it ended has gone (0 when none waits)
    private var _backPending as Number = 0;
    // the piece the player started last
    private var _playingN as Number = -1;
    // a route of the call answered 404: nothing records until the events say whether the call ended
    private var _gone as Boolean = false;
    private var _micSaid as Boolean = false;
    private var _lastTick as Number = 0;
    private var _logToCall as Boolean = true;
    private var _orphanHold as Boolean = false;
    private var _cuedSent as Boolean = false;
    private var _closedSaid as Boolean = false;
    private var _logBatch as Number = 0;
    private var _failStreak as Number = 0;
    private var _lossTimes as Array<Number> = [];
    private var _fatalNotSet as Boolean = false;
    private var _requests as Number = 0;
    private var _autoAt as Number = 0;

    private var _press as Number = 0;
    // the last press sent before the current turn began; the server holds the turn's audio for it
    private var _afterPress as Number = 0;
    private var _logHold as Boolean = false;
    private var _holdUntil as Number = 0;
    private var _commands as Array<Dictionary<String, Object>> = [];
    private var _hangId as String? = null;
    private var _logSent as Number = 0;
    private var _lastLog as Number = 0;
    private var _lastMem as Number = 0;

    function initialize(io as CallIo, env as CallEnv) {
        _io = io;
        _env = env;
    }

    // ----- the screen's side

    function start() as Void {
        var device = System.getDeviceSettings();
        Trace.add("device", {"part" => device.partNumber, "fw" => device.firmwareVersion, "audio" => Toybox has :Audio});
        Trace.debugOn = _env.debugLog();
        Trace.active = true;
        Idle.logStale = true;
        _env.startClock(method(:tick), TICK_MS);
        begin();
    }

    // A turn an earlier call left on the watch is offered first: he says whether it goes, and nothing
    // is recorded until then. Otherwise listening begins before the call exists; the audio is kept
    // until it does, and the open goes out once the microphone has delivered.
    private function begin() as Void {
        var waiting = Kept.waiting();
        if (waiting != null) {
            _kept = waiting;
            _turn += 1;
            _afterPress = _press;
            _sync = true;
            _endPending = false;
            _transcribing = false;
            kept = false;
            ask("turn_offered");
            return;
        }
        micFirst();
        startTurn();
    }

    // The kept turn waits for his word, with the buzz that says so.
    private function ask(ev as String) as Void {
        var turn = _kept;
        if (turn == null) {
            return;
        }
        asking = true;
        _endPending = false;
        kept = false;
        Trace.add(ev, {"id" => turn["id"] as String, "age_s" => Time.now().value() - Kept.num(turn, "at"),
            "ms" => Kept.num(turn, "ms"), "unsent" => Kept.unsent(turn)});
        Kept.persist(turn);
        _io.cue.invoke(CallLogic.CUE_KEPT);
        changed();
    }

    // His word on the turn that waits: Start sends it, also when the server holds it back as old;
    // Back drops it, and listening begins.
    function answer(send as Boolean) as Void {
        var turn = _kept;
        if (!asking || turn == null) {
            return;
        }
        asking = false;
        Trace.add("turn_answer", {"id" => turn["id"] as String, "send" => send});
        _io.cue.invoke(CallLogic.CUE_TAKEN);
        if (send) {
            _confirm = true;
            _endPending = true;
            _endPress = 0;
            _pressTries = 0;
            _pressNotBefore = 0;
            _cuedSent = false;
            _pressAt = _env.now();
            _stoppedAt = _pressAt;
            if (!(turn["pressed"] instanceof Number)) {
                turn["pressed"] = Time.now().value();
            }
        } else {
            Kept.drop(turn);
            _kept = null;
            _sync = false;
            begin();
        }
        pump();
        changed();
    }

    // What the screen says about the turn that waits for his word.
    function keptLabel() as String {
        var turn = _kept;
        return turn != null ? Kept.label(turn) : "";
    }

    // How long the watch has been keeping audio the server does not have yet, in seconds; 0 while
    // the server keeps up.
    function keepingS() as Number {
        var turn = _kept;
        if (turn == null || !recording || Kept.unsent(turn) == 0) {
            return 0;
        }
        var ms = _env.now() - _caughtUpAt;
        return ms >= BEHIND_SHOW_MS ? ms / 1000 : 0;
    }

    // The next open waits for the first microphone data (at most OPEN_WAIT_MS).
    private function micFirst() as Void {
        _micSeen = false;
        _openAfter = _env.now() + OPEN_WAIT_MS;
    }

    // The Start button: send the turn that is being recorded, cut an answer, begin a turn that did not
    // begin by itself, try again after a stop, or send a kept turn that waits for his word. Every press
    // it takes buzzes: the tap at once, a send once the server has the turn ("sent") or the watch
    // knows it keeps it ("kept"). False when there was nothing to press for.
    function press() as Boolean {
        if (asking && !_closing) {
            answer(true);
            return true;
        }
        var action = CallLogic.pressAction(fatal != null || _closing || _ending || _leaving, stalled != null, recording,
            busyAnswering(), _kept != null);
        if (action == CallLogic.PRESS_NONE) {
            return false;
        }
        Trace.add("start", {"action" => action});
        if (action == CallLogic.PRESS_RETRY) {
            stalled = null;
            _failStreak = 0;
            _lossTimes = [];
            _lanes[OPEN].notBefore = 0;
            _lanes[OPEN].failures = 0;
            _noPhoneSince = -1;
            _failingSince = -1;
        }
        if (action != CallLogic.PRESS_SEND) {
            // a send buzzes once the server has the turn, or once the watch knows it keeps it
            _io.cue.invoke(CallLogic.CUE_TAKEN);
        }
        if (action == CallLogic.PRESS_SEND) {
            endTurn();
        } else if (action == CallLogic.PRESS_CUT) {
            cut();
        } else if (!recording) {
            _turnSent = false;
            begin();
        }
        return true;
    }

    // The server ended the call, and what still plays is finishing before the hang-up.
    function ending() as Boolean {
        return _ending;
    }

    // Back was pressed in a session's call and Computer does not have the call yet.
    function leaving() as Boolean {
        return _leaving;
    }

    function closed() as Boolean {
        return _closing;
    }

    // True from Start until the server says what it does with the turn: the press is on its way, or
    // taken and not yet answered by a new state.
    function sending() as Boolean {
        return _endPending || _turnSent || _transcribing;
    }

    // A new call in place of the current one. A turn of his that is open goes on in it.
    function reconnect() as Void {
        Trace.add("reconnect", null);
        var old = _call;
        resetCall();
        _hangId = old;
        if (_kept == null) {
            begin();
        }
    }

    // Back in Computer's call: the buzz that says the call is over, and the hang-up.
    function bye() as Void {
        if (!_closing) {
            _io.cue.invoke(CallLogic.CUE_BYE);
        }
        hangUp();
    }

    // The app was hidden for too long: what is being said goes to the server as the turn, and the
    // call hangs up once the server has answered the press (or after HANG_AFTER_TURN_MS, with the
    // turn kept on the watch).
    function endAfterTurn() as Void {
        if (_closing || _hangAfterTurnAt >= 0) {
            return;
        }
        if (recording && _turnBytes > 0) {
            Trace.add("end_after_turn", {"bytes" => _turnBytes});
            _hangAfterTurnAt = _env.now();
            if (!press()) {
                hangUp();
            }
            return;
        }
        hangUp();
    }

    function hangUp() as Void {
        if (_closing) {
            return;
        }
        _closing = true;
        _closedAt = _env.now();
        Trace.add("hangup", null);
        summarize();
        leaveTurn("hangup");
        Trace.persist();
        _io.stopPlayback.invoke();
        clearCommands();
        for (var i = 0; i < _lanes.size(); i++) {
            // an open still on its way is answered later: its call is hung up then
            if (i != OPEN) {
                abandon(i);
            }
        }
        _hangId = _call;
        _call = null;
        _lanes[HANG].failures = 0;
        _lanes[HANG].notBefore = 0;
        _lanes[LOG].failures = 0;
        _lanes[LOG].notBefore = 0;
        pump();
    }

    // The app ends: the turn stays on the watch as it is, for the next start to offer.
    function appStopped() as Void {
        if (!_closing) {
            leaveTurn("exit");
        }
    }

    // The call lets go of the turn. The microphone stops; a turn he pressed for, one that waits for
    // his word and one he spoke for LEAVE_KEEP_MS or longer stay on the watch, and the next start
    // offers them. A shorter one without a press is dropped, as a hang-up always did.
    private function leaveTurn(why as String) as Void {
        if (recording || _captureOpen) {
            stopMic();
        }
        var turn = _kept;
        if (turn != null) {
            cutParts(true);
            var pressed = turn["pressed"] instanceof Number;
            var ms = spokenMs();
            var keep = pressed || asking || ms >= LEAVE_KEEP_MS;
            Trace.add("turn_left", {"id" => turn["id"] as String, "why" => why, "kept" => keep, "ms" => ms,
                "pressed" => pressed, "unsent" => Kept.unsent(turn)});
            if (!keep) {
                Kept.drop(turn);
            } else {
                if (recording) {
                    turn["ms"] = ms;
                }
                Kept.persist(turn);
            }
        }
        _kept = null;
        recording = false;
        _captureOpen = false;
        _endPending = false;
        _transcribing = false;
        asking = false;
        kept = false;
        _sync = false;
        _chunks = [];
        _chunkBytes = 0;
        _body = null;
        _bodyEnd = 0;
        abandon(AUDIO);
    }

    // How long he has spoken in the turn being recorded.
    private function spokenMs() as Number {
        return recording && micLive ? _env.now() - recordingSince : 0;
    }

    // A chunk of the turn's Ogg Opus stream from the capture.
    function chunk(data as ByteArray) as Void {
        if ((!recording && !_captureOpen) || _kept == null) {
            return;
        }
        _micSeen = true;
        if (_goPending && recording) {
            // the microphone delivers: the go tone, and from here the screen says "Speak"
            _goPending = false;
            micLive = true;
            recordingSince = _env.now();
            _micMs = recordingSince - _turnStartedAt;
            Trace.debug("capture_state", {"state" => "data", "ms" => _micMs});
            if (!_micSaid) {
                // the first time after launch: how long from the app's start to "speak"
                _micSaid = true;
                Trace.add("mic_live", {"since_launch_ms" => recordingSince - Trace.bornAt});
            }
            _io.cue.invoke(CallLogic.CUE_YOUR_TURN);
            changed();
        }
        if (_turnBytes == 0) {
            var head = data.size() >= 4 ? data.slice(0, 4) : data;
            Trace.debug("first_chunk", {"size" => data.size(), "ogg" => data.size() >= 4 && data[0] == 0x4F && data[1] == 0x67 && data[2] == 0x67 && data[3] == 0x53, "head" => head.toString()});
        }
        _chunks.add(data);
        _chunkBytes += data.size();
        _turnBytes += data.size();
        cutParts(false);
        pump();
    }

    // The audio the microphone delivered becomes the turn's next parts: a small one as soon as the
    // server has everything before it and the link is free, so a turn leaves the watch while it is
    // spoken; a full one while the server is behind; all that is left once the microphone has stopped.
    // A part cut while the server has been behind for HOLD_MS goes to storage at once.
    private function cutParts(all as Boolean) as Void {
        var turn = _kept;
        if (turn == null) {
            return;
        }
        while (_chunks.size() > 0) {
            var live = _call != null && !_gone && !_sync && !_endPending && Kept.unsent(turn) == 0 && !_lanes[AUDIO].busy;
            if (!all && _chunkBytes < Kept.PART_MAX && !(live && _chunkBytes >= AUDIO_MIN)) {
                break;
            }
            var body = new [0]b;
            while (_chunks.size() > 0 && (body.size() == 0 || body.size() + _chunks[0].size() <= Kept.PART_MAX)) {
                var c = _chunks[0];
                _chunks = _chunks.slice(1, null) as Array<ByteArray>;
                _chunkBytes -= c.size();
                body.addAll(c);
            }
            if (Kept.unsent(turn) == 0) {
                _caughtUpAt = _env.now();
            }
            Kept.add(turn, body);
            if (_env.now() - _caughtUpAt >= HOLD_MS) {
                store(turn);
            }
        }
    }

    // The turn's parts in memory go to storage. When the storage has no room for more, the
    // recording ends there, as his press would end it.
    private function store(turn as Dictionary<String, Object?>) as Void {
        if (!_behind) {
            _behind = true;
            Trace.add("turn_behind", {"id" => turn["id"] as String, "unsent" => Kept.unsent(turn), "call" => _call != null});
        }
        var ok = Kept.persist(turn);
        if ((!ok || !Kept.hasRoom()) && recording) {
            Trace.add("turn_storage_full", {"kept_bytes" => Kept.stored(), "stored" => ok});
            setNotice("Storage full");
            endTurn();
        }
    }

    function captureEnded() as Void {
        if (_captureOpen) {
            _captureOpen = false;
            if (_endPending && _pressAt > 0) {
                _stopMs = _env.now() - _pressAt;
            }
            Trace.debug("capture_state", {"state" => "stopped"});
            micStopped();
            pump();
        }
    }

    // The microphone has stopped after his press (or was given up waiting for): from here a buzz is
    // never in the recording. A turn in which the microphone never delivered gets its tap now; any
    // other buzzes "sent" once the server has it, or "kept" when that does not happen soon.
    private function micStopped() as Void {
        if (_endPending && _stoppedAt == 0) {
            _stoppedAt = _env.now();
            if (_turnBytes == 0 && !_cuedSent) {
                _cuedSent = true;
                _io.cue.invoke(CallLogic.CUE_TAKEN);
            }
        }
    }

    // The server has the turn: the two short buzzes, once a turn.
    private function cueSent() as Void {
        if (!_cuedSent) {
            _cuedSent = true;
            _io.cue.invoke(CallLogic.CUE_SENT);
        }
    }

    // His press is not answered: at once when the watch knows the link is down, else after
    // KEPT_AFTER_MS. The turn goes to storage, the kept buzz says the watch has it, and the screen
    // says so until the server has it.
    private function keepIfUnanswered(now as Number) as Void {
        var turn = _kept;
        if (turn == null || !_endPending || kept || _cuedSent || _captureOpen || _stoppedAt == 0) {
            return;
        }
        if (now - _stoppedAt >= KEPT_AFTER_MS || linkDown()) {
            cutParts(true);
            kept = true;
            Trace.add("turn_kept", {"id" => turn["id"] as String, "unsent" => Kept.unsent(turn), "call" => _call != null,
                "waited_ms" => now - _stoppedAt});
            Kept.persist(turn);
            _io.cue.invoke(CallLogic.CUE_KEPT);
            changed();
        }
    }

    // Nothing can reach the server right now, as far as the watch can tell.
    private function linkDown() as Boolean {
        return _call == null || _gone || _failingSince >= 0 || _lanes[AUDIO].failures > 0 || _lanes[CMD].failures > 0
            || _env.check() != 0;
    }

    // The watch stopped the microphone while the app was hidden, in the middle of a turn: it starts
    // again in the same turn, and its new stream follows the old one (the server reads chained
    // streams). Nothing while the microphone still runs or the turn is over.
    function resumeMic() as Void {
        if (!recording || _captureOpen || _endPending || _closing) {
            return;
        }
        var started = _io.startCapture.invoke();
        if (started == 0) {
            _captureOpen = true;
            Trace.add("mic_resumed", {"turn" => _turn, "bytes" => _turnBytes});
        } else {
            Trace.add("mic_resume_failed", {"code" => started});
        }
        changed();
    }

    function captureFailed(code as Number) as Void {
        Trace.add("capture_error", {"code" => code});
        Trace.debug("capture_state", {"state" => "error", "code" => code});
        if (recording) {
            // what he said up to here stays on the watch
            leaveTurn("capture_error");
            recordFailed("Microphone error " + code);
        }
        changed();
    }

    // The screen's player finished piece n.
    function piecePlayed(n as Number) as Void {
        if (_reported.hasKey(n)) {
            return;
        }
        _reported[n] = true;
        for (var i = 0; i < _fed.size(); i++) {
            if (_fed[i][0] == n) {
                _fed = _fed.slice(0, i).addAll(_fed.slice(i + 1, null)) as Array<Array<Number>>;
                break;
            }
        }
        var size = _sizes[n];
        if (size != null) {
            _unplayed -= size;
            _sizes.remove(n);
        }
        _playedQueue.add(n);
        pump();
    }

    // The player has nothing left to play.
    function playbackIdle() as Void {
        playbackActive = false;
        spoken = "";
        forgetUnplayed();
        changed();
    }

    // The player has played the last piece: the next turn starts now. Nothing is waited for, since the
    // microphone takes a moment of its own to deliver.
    function answerEnded() as Void {
        if (_ending) {
            endCall();
            return;
        }
        autoRecord(_env.now());
        if (inSession() && engine.equals("wake") && !recording && !moreToPlay() && !_closing) {
            // a session that waits records nothing by itself: the signal says Start is his move
            _io.cue.invoke(CallLogic.CUE_YOUR_TURN);
        }
    }

    function playbackFailed(code as Number) as Void {
        Trace.add("playback_error", {"code" => code});
        playbackActive = false;
        forgetUnplayed();
        if (stalled == null && fatal == null && !_closing) {
            // a piece that cannot play ends the call's listening, once, with the error cue
            stopForGood("Playback error " + code, true);
        }
        changed();
    }

    // What the player held when it stopped or failed is gone: it no longer counts against the fetch limit.
    private function forgetUnplayed() as Void {
        _unplayed = 0;
        _sizes = {};
        _fed = [];
        _playEnd = 0;
    }

    // The player may never say that a piece is over: by the clock it is, a little after its length.
    // Pieces then count as played and recording may begin without the player's word.
    private function endPlaybackByTimer(now as Number) as Void {
        if (_io.busy.invoke()) {
            return;
        }
        while (_fed.size() > 0 && _fed[0][1] + PLAY_SLACK_MS <= now) {
            Trace.debug("play_timer", {"n" => _fed[0][0]});
            piecePlayed(_fed[0][0]);
        }
        if (playbackActive && _fed.size() == 0 && !_lanes[PIECE].busy && _pieces.size() == 0 && now >= _playEnd + PLAY_SLACK_MS) {
            playbackActive = false;
            changed();
        }
    }

    // True while there is still audio to come for the player: pieces waiting, being fetched, or just
    // handed over.
    function moreToPlay() as Boolean {
        return _pieces.size() > 0 || _lanes[PIECE].busy;
    }

    // The failing lane with its count; empty while every request gets through.
    function linkTrouble() as String {
        for (var i = 0; i < _lanes.size(); i++) {
            if (_lanes[i].failures > 0 && i != LOG) {
                return _lanes[i].name + " retry " + _lanes[i].failures;
            }
        }
        return "";
    }

    // A short message of the screen's own, shown like the server's notices.
    function say(text as String) as Void {
        setNotice(text);
        changed();
    }

    function hasCall() as Boolean {
        return _call != null;
    }

    // The call is in a session's hands, not Computer's.
    function inSession() as Boolean {
        return !owner.equals("computer");
    }

    // Back in a session's call: the server is asked to give the call back to Computer, with a buzz
    // that says the press was taken. A turn being recorded is not sent: its microphone stops, its
    // audio goes to the server (which keeps what it heard in the session's draft) and the back command
    // follows it.
    function back() as Void {
        if (_closing || _call == null || _leaving) {
            return;
        }
        _io.cue.invoke(CallLogic.CUE_TAKEN);
        _leaving = true;
        _backs += 1;
        Trace.add("back", {"back" => _backs, "recording" => recording});
        if (recording || _captureOpen) {
            recording = false;
            _endPending = false;
            _backPending = _backs;
            _stopAt = _env.now() + STOP_WAIT_MS;
            stopMic();
        } else {
            queueBack(_backs);
        }
        pump();
        changed();
    }

    private function queueBack(number as Number) as Void {
        _commands.add({"action" => "back", "back" => number} as Dictionary<String, Object>);
    }

    // The back command goes once the turn it ended has left the watch.
    private function sendBackIfDrained() as Void {
        var turn = _kept;
        if (_backPending == 0 || _captureOpen || _chunks.size() > 0 || _sync || _lanes[AUDIO].busy
                || (turn != null && Kept.unsent(turn) > 0)) {
            return;
        }
        queueBack(_backPending);
        _backPending = 0;
        if (turn != null) {
            // the server keeps what it heard in the session's draft; the turn itself is over
            Kept.drop(turn);
            _kept = null;
        }
    }

    // One line for the turn that ended: how long the microphone took to deliver, the bytes sent, how long
    // after the press the capture stopped (stop_ms), the server had the press (sent_ms) and the first
    // sound played (sound_ms), how long the first piece took to be known after that (piece_ms) and to
    // arrive (fetch_ms), and what the answer's pieces did. -1 for a step that did not happen.
    private function summarize() as Void {
        if (_turn == 0) {
            return;
        }
        Trace.add("turn_summary", {"turn" => _turn, "mic_ms" => _micMs, "bytes" => _turnBytes, "stop_ms" => _stopMs,
            "sent_ms" => _sentMs, "piece_ms" => _pieceMs, "fetch_ms" => _fetchMs, "sound_ms" => _soundMs,
            "pieces" => _pieceN, "gap_max_ms" => _gapMax});
        if (_starvedN > 0) {
            Trace.add("starved", {"turn" => _turn, "n" => _starvedN});
        }
        _pieceN = 0;
        _gapMax = 0;
        _starvedN = 0;
        _pressAt = 0;
        _stopMs = -1;
        _sentMs = -1;
        _pieceMs = -1;
        _fetchMs = -1;
        _soundMs = -1;
        _stored = false;
    }

    // The player started piece n: its sentence shows from now (Computer's pieces carry one), and the
    // silence before it and whether the piece before had to wait for it go into the turn's summary.
    function noteGap(n as Number, gapMs as Number, starved as Boolean) as Void {
        _pieceN += 1;
        var text = _texts[n];
        spoken = text != null ? text : "";
        _playingN = n;
        var gone = _texts.keys();
        for (var i = 0; i < gone.size(); i++) {
            if ((gone[i] as Number) <= n) {
                _texts.remove(gone[i]);
            }
        }
        changed();
        if (_soundMs < 0 && _pressAt > 0) {
            _soundMs = _env.now() - _pressAt;
        }
        if (!_stored) {
            // once a turn, while the answer plays and the link has nothing urgent to carry
            _stored = true;
            Trace.persist();
        }
        _gapMax = gapMs > _gapMax ? gapMs : _gapMax;
        if (starved) {
            _starvedN += 1;
        }
    }

    // ----- the turn

    private function startTurn() as Void {
        summarize();
        _turn += 1;
        _micMs = -1;
        micLive = false;
        _goPending = true;
        _turnStartedAt = _env.now();
        _turnBytes = 0;
        _chunks = [];
        _chunkBytes = 0;
        _body = null;
        _endPress = 0;
        _bodyEnd = 0;
        _endPending = false;
        _stoppedAt = 0;
        _cuedSent = false;
        _confirm = false;
        _sync = false;
        _transcribing = false;
        _pressTries = 0;
        _pressNotBefore = 0;
        _behind = false;
        _caughtUpAt = _turnStartedAt;
        kept = false;
        _afterPress = _press;
        abandon(AUDIO);
        heard = "";
        spoken = "";
        var started = _io.startCapture.invoke();
        if (started == 0) {
            recording = true;
            _captureOpen = true;
            recordingSince = _env.now();
            var turn = Kept.open();
            _kept = turn;
            Trace.add("turn_start", {"turn" => _turn, "id" => turn["id"] as String});
            Trace.debug("capture_state", {"state" => "started"});
        } else if (started == 1) {
            recording = false;
            _captureOpen = false;
            _goPending = false;
            stopForGood("This watch cannot capture Opus", true);
            Trace.add("capture_unavailable", null);
        } else {
            recording = false;
            _captureOpen = false;
            _goPending = false;
            recordFailed("Microphone busy");
        }
        changed();
    }

    private function endTurn() as Void {
        var turn = _kept;
        if (turn != null) {
            turn["ms"] = spokenMs();
            turn["pressed"] = Time.now().value();
        }
        recording = false;
        _cuedSent = false;
        _stoppedAt = 0;
        _endPending = true;
        _pressAt = _env.now();
        _stopAt = _pressAt + STOP_WAIT_MS;
        stopMic();
        if (!_captureOpen) {
            micStopped();
        }
        pump();
        changed();
    }

    // Stops the microphone. It may hand over its last data and say it stopped before this returns;
    // nothing is sent from inside that, so the request goes out from here, once.
    private function stopMic() as Void {
        _stopping = true;
        _io.stopCapture.invoke();
        _stopping = false;
    }

    // The commands of the call that is gone or over are not sent; what they were for is asked again
    // from the turn's own state.
    private function clearCommands() as Void {
        _commands = [];
        _cmdOut = null;
        _pressOut = false;
        _syncOut = false;
        _dropOut = null;
        _bodyEnd = 0;
        _endPress = 0;
    }

    // Once the server has every part of the turn he pressed for, the press follows as a command,
    // unless it rode on the last part. A turn in which the microphone delivered nothing is over.
    private function sendPressIfDrained() as Void {
        var turn = _kept;
        if (turn == null || !_endPending || _captureOpen || _chunks.size() > 0 || _closing) {
            return;
        }
        if (Kept.num(turn, "parts") == 0) {
            _endPending = false;
            _kept = null;
            Kept.forget(turn);
            Trace.add("empty_turn", null);
            setNotice("Heard nothing");
            return;
        }
        if (_pressOut || _bodyEnd > 0 || _call == null || _gone || _sync || Kept.unsent(turn) > 0 || _lanes[AUDIO].busy
                || _env.now() < _pressNotBefore) {
            return;
        }
        _pressOut = true;
        var press = {"action" => "press", "press" => endPress(), "turn" => _turn, "id" => turn["id"] as String,
            "chunks" => Kept.num(turn, "parts"), "ago" => ago(turn)} as Dictionary<String, Object>;
        if (_confirm) {
            press["confirm"] = true;
        }
        _commands.add(press);
        _holdUntil = _env.now() + PRESS_HOLD_MS;
        Trace.add("press", {"press" => _endPress, "turn" => _turn, "ago" => press["ago"], "confirm" => _confirm});
    }

    // How many seconds ago he pressed for the turn.
    private function ago(turn as Dictionary<String, Object?>) as Number {
        var pressed = turn["pressed"];
        var s = pressed instanceof Number ? Time.now().value() - pressed : 0;
        return s > 0 ? s : 0;
    }

    // A dropped turn the server has not heard of is told to it, one at a time.
    private function queueDrop() as Void {
        if (_dropOut == null && _call != null && !_gone) {
            var id = Kept.dropId();
            if (id != null) {
                _dropOut = id;
                _commands.add({"action" => "drop", "id" => id} as Dictionary<String, Object>);
            }
        }
    }

    // In a new call, and for a turn an earlier run left, the server says where the turn stands
    // before any more of it goes.
    private function queueSync() as Void {
        var turn = _kept;
        if (turn != null && _sync && !_syncOut && _call != null && !_gone) {
            _syncOut = true;
            _commands.add({"action" => "turn", "id" => turn["id"] as String} as Dictionary<String, Object>);
        }
    }

    // Where the server says the turn stands, from its answer to a press, to the question, or from
    // the call's events.
    private function turnIs(state as String?, error as Object?, via as String) as Void {
        var turn = _kept;
        if (turn == null) {
            return;
        }
        Trace.add("turn_state", {"id" => turn["id"] as String, "state" => state, "via" => via, "error" => error});
        if ("taken".equals(state)) {
            // handed to Computer, once: the turn is over for the watch and the answer is awaited
            var offered = asking;
            cueSent();
            Kept.forget(turn);
            _kept = null;
            _endPending = false;
            _transcribing = false;
            _sync = false;
            asking = false;
            kept = false;
            if (offered) {
                // an earlier run's press had reached the server after all
                setNotice("Was sent already");
                begin();
                return;
            }
            _turnSent = true;
            _turnSentPoll = -1;
            pressTaken();
        } else if ("dropped".equals(state)) {
            leaveTurn("dropped");
        } else if ("held".equals(state)) {
            // pressed too long ago to run unasked: he says whether it goes
            if (!asking) {
                ask("turn_held");
            }
        } else if ("pressed".equals(state) && error != null) {
            // the server could not turn it into text: the press goes again, then he is asked
            _transcribing = false;
            _pressTries += 1;
            setNotice("Server could not read it");
            if (_pressTries >= PRESS_TRIES) {
                _pressTries = 0;
                ask("turn_unread");
            } else {
                _endPending = true;
                _endPress = 0;
                _pressNotBefore = _env.now() + PRESS_RETRY_MS;
            }
        } else if ("pressed".equals(state) && !asking) {
            // the server has all of it and turns it into text; the events say when Computer has it
            cueSent();
            kept = false;
            _endPending = false;
            _transcribing = true;
        }
    }

    // The server's answer to a press for the turn. One without a state is a server that knows no
    // kept turns and has taken it.
    private function pressAnswered(data as Dictionary or String or ByteArray or Null) as Void {
        _pressOut = false;
        _endPress = 0;
        // a press that did not finish the turn is not repeated at once
        _pressNotBefore = _env.now() + PRESS_RETRY_MS;
        var state = data instanceof Dictionary ? data["turn"] as Object? : null;
        turnIs(state instanceof String ? state : "taken", null, "press");
        if (_hangAfterTurnAt >= 0) {
            hangUp();
        }
    }

    // The server's answer to where the turn stands: the watch goes on from the part it names. A
    // count below what the server confirmed before, or a part the storage no longer has, cannot be
    // repaired.
    private function synced(data as Dictionary or String or ByteArray or Null) as Void {
        var turn = _kept;
        _syncOut = false;
        if (turn == null) {
            return;
        }
        _sync = false;
        var state = data instanceof Dictionary ? data["turn"] as Object? : null;
        var count = Outcome.number(data instanceof Dictionary ? data["next_seq"] as Object? : null);
        var next = count != null ? count : 0;
        Trace.add("turn_sync", {"id" => turn["id"] as String, "state" => state, "next" => next,
            "sent" => Kept.num(turn, "sent"), "parts" => Kept.num(turn, "parts")});
        if ("taken".equals(state) || "dropped".equals(state) || "held".equals(state)) {
            turnIs(state as String, null, "sync");
        } else if (next < Kept.num(turn, "sent")) {
            lostTurn("server");
        } else {
            Kept.confirm(turn, next);
            caughtUp(turn);
        }
    }

    // The turn cannot be completed any more: he hears and sees it, and the turn goes.
    private function lostTurn(why as String) as Void {
        var turn = _kept;
        if (turn == null) {
            return;
        }
        Trace.add("turn_lost", {"id" => turn["id"] as String, "why" => why, "sent" => Kept.num(turn, "sent"),
            "parts" => Kept.num(turn, "parts")});
        Kept.drop(turn);
        _kept = null;
        leaveTurn(why);
        setNotice("Lost audio, say it again");
        _io.cue.invoke(CallLogic.CUE_ERROR);
    }

    // The server has every part cut so far.
    private function caughtUp(turn as Dictionary<String, Object?>) as Void {
        if (Kept.unsent(turn) > 0) {
            return;
        }
        if (_behind) {
            _behind = false;
            Trace.add("turn_caught_up", {"id" => turn["id"] as String, "behind_ms" => _env.now() - _caughtUpAt,
                "parts" => Kept.num(turn, "parts")});
        }
        _caughtUpAt = _env.now();
    }

    // The number of the press that ends the current turn: the same one however often it is sent, on
    // the last audio request or as a command.
    private function endPress() as Number {
        if (_endPress == 0) {
            _press += 1;
            _endPress = _press;
        }
        return _endPress;
    }

    // The press that cuts an answer.
    private function queuePress(number as Number) as Void {
        _commands.add({"action" => "press", "press" => number, "turn" => _turn} as Dictionary<String, Object>);
        _holdUntil = _env.now() + PRESS_HOLD_MS;
        Trace.add("press", {"press" => number, "turn" => _turn});
    }

    // The server has the press that ended the turn: from here the answer is waited for.
    private function pressTaken() as Void {
        if (_turnSentPoll < 0) {
            _turnSentPoll = _pollsSent;
            _sentMs = _env.now() - _pressAt;
        }
        _failStreak = 0;
    }

    // The answer is cut: playback stops now, the press goes out, and the next turn is recorded.
    private function cut() as Void {
        _io.stopPlayback.invoke();
        dropPieces();
        _turnSent = false;
        _turnSentPoll = -1;
        _expectPiece = false;
        _press += 1;
        queuePress(_press);
        startTurn();
    }

    private function busyAnswering() as Boolean {
        if (inSession()) {
            // a session answers whenever it does: only what plays can be cut
            return playbackActive || moreToPlay();
        }
        return _turnSent || engine.equals("generating") || engine.equals("speaking") || playbackActive || moreToPlay();
    }

    private function dropPieces() as Void {
        forgetUnplayed();
        _pieces = [];
        abandon(PIECE);
        _pieceTries = 0;
        _timeoutN = -1;
        _pieceTimeouts = 0;
    }

    // ----- the clock

    function tick() as Void {
        var now = _env.now();
        // the clock ticks every TICK_MS: a much longer gap is a stall of the watch's own loop
        if (_lastTick > 0 && now - _lastTick > STALL_MS) {
            Trace.add("stall", {"gap_ms" => now - _lastTick});
        }
        _lastTick = now;
        if (_hangAfterTurnAt >= 0 && !_closing && now - _hangAfterTurnAt > HANG_AFTER_TURN_MS) {
            hangUp();
        }
        for (var i = 0; i < _lanes.size(); i++) {
            var lane = _lanes[i];
            if (lane.busy && now - lane.sentAt > lane.watchdogMs) {
                abandon(i);
                failed(i, Communications.NETWORK_REQUEST_TIMED_OUT);
            }
        }
        if (_closing) {
            pump();
            finishClosing(now);
            return;
        }
        if (_ending && !_io.busy.invoke()) {
            endCall();
            return;
        }
        if (notice != null && _noticeUntil > 0 && now >= _noticeUntil) {
            notice = null;
            changed();
        }
        if ((_endPending || _backPending > 0) && _captureOpen && now >= _stopAt) {
            Trace.add("capture_no_complete", null);
            _captureOpen = false;
            micStopped();
        }
        keepIfUnanswered(now);
        var turn = _kept;
        if (turn != null && Kept.held.size() > 0 && Kept.unsent(turn) > 0 && now - _caughtUpAt >= HOLD_MS) {
            // the server has been behind for a while: what waits in memory goes to storage
            store(turn);
        }
        if (keepingS() > 0) {
            changed();
        }
        if (_failingSince >= 0 && now - _failingSince >= LINK_LOST_MS && _call != null && stalled == null && fatal == null
                && _kept == null) {
            // nothing gets through any more: the call says so instead of repeating requests unseen
            Trace.add("link_lost", {"ms" => now - _failingSince});
            stopForGood("Phone link lost", true);
        }
        if (_fatalNotSet && _env.check() != 1) {
            fatal = null;
            _fatalNotSet = false;
            begin();
        }
        endPlaybackByTimer(now);
        if (now - _lastMem > MEM_EVERY_MS) {
            _lastMem = now;
            Trace.debug("mem", {"free" => System.getSystemStats().freeMemory, "chunks" => _chunkBytes, "unplayed" => _unplayed});
        }
        autoRecord(now);
        pump();
    }

    // The hang-up is over when the server has heard it, or when it has had its time: then the screen
    // may leave and the clock stops. What is left of the log stays for the app's exit to store.
    private function finishClosing(now as Number) as Void {
        if (_closedSaid) {
            return;
        }
        var heard = _hangId == null && !_lanes[HANG].busy && !_lanes[OPEN].busy;
        if (heard || now - _closedAt > HANG_GRACE_MS) {
            _closedSaid = true;
            Trace.active = false;
            // a self-report or log lines waiting go now that the call is over
            Idle.poke(Idle.DELAY_MS);
            _env.stopClock();
            Trace.add("hangup_done", {"heard" => heard});
            _io.closed.invoke();
        }
    }

    private function autoRecord(now as Number) as Void {
        // Computer listens after every answer; a session's call records only in its recording phase
        if (!_closing && !_ending && !_gone && _call != null && !recording && _kept == null && !_turnSent && !_leaving
                && (engine.equals("listening") || engine.equals("recording"))
                && !playbackActive && !moreToPlay() && now >= _autoAt && fatal == null && stalled == null
                && !_io.busy.invoke()) {
            startTurn();
        }
    }

    // ----- the lanes

    private function recalcInflight() as Void {
        var n = 0;
        for (var i = 0; i < _lanes.size(); i++) {
            if (_lanes[i].busy) {
                n += 1;
            }
        }
        _inflight = n;
    }

    // Gives up the lane's request. One still in flight is cancelled too: an answer that never comes
    // would keep holding one of the few requests the platform lets the app have open, and once those
    // are all held every new request fails on the watch without reaching the phone. One request at
    // a time (MAX_PARALLEL) makes it the only one cancelled.
    private function abandon(lane as Number) as Void {
        var l = _lanes[lane];
        l.token += 1;
        if (l.busy) {
            l.busy = false;
            _env.cancelRequests();
        }
        recalcInflight();
    }

    private function ready(lane as Number) as Boolean {
        var l = _lanes[lane];
        return !l.busy && _env.now() >= l.notBefore && _inflight < MAX_PARALLEL;
    }

    function pump() as Void {
        if (_stopping) {
            return;
        }
        // after his press the capture has TAIL_WAIT_MS to hand over its last data, so that one
        // request carries all of it
        cutParts((!recording && !_captureOpen) || (_endPending && _env.now() - _pressAt >= TAIL_WAIT_MS));
        sendPressIfDrained();
        sendBackIfDrained();
        var call = _call;
        if (_closing || _ending) {
            var hang = _hangId;
            if (hang != null && _dropOut == null && !_dropTried && Kept.dropId() != null && ready(CMD)) {
                // the turn he left without a press: the server hears that it is dropped, once, before
                // the hang-up; without an answer the next call tells it
                _dropTried = true;
                queueDropTo(hang);
            }
            if (_hangId != null && ready(HANG)) {
                sendHang();
            }
            return;
        }
        queueSync();
        queueDrop();
        if (_hangId != null && ready(HANG)) {
            sendHang();
        }
        var now = _env.now();
        // the log goes out when the link has nothing else to carry and no answer is being waited for:
        // while the answer plays, or between calls
        var idle = !turnOpen() && _playedQueue.size() == 0 && _pieces.size() == 0 && !_lanes[PIECE].busy
            && !_turnSent && (playbackActive || !(engine.equals("generating") || engine.equals("speaking")));
        var logDue = !_logHold && Trace.lines.size() > 0 && ((idle && (Trace.lines.size() >= batchSize() || now - _lastLog >= LOG_EVERY_MS
            || (_logUrgent && now - _lastLog >= LOG_URGENT_MS))) || Trace.lines.size() >= Trace.MAX_LINES - 10);
        if (call == null) {
            // the open waits for the first microphone data, so that the watch's own loop is not stuck in a
            // request while the microphone starts
            if (fatal == null && stalled == null && _env.gateOpen() && ready(OPEN)
                    && (_micSeen || now >= _openAfter || !recording)) {
                sendOpen();
            } else if (!_orphanHold && logDue && idle && !_lanes[OPEN].busy && ready(LOG)) {
                sendLog(null);
            }
            return;
        }
        // One request at a time, in this order: the press, a played report with no piece left to fetch
        // (on an events request), the audio, the pieces, the log when it is due (which is rarely), the
        // events. The events jump the queue when they have waited too long. While his turn is open nothing is expected from the server, so the
        // events are only asked now and then, without a wait, and never hold up the audio.
        if (_commands.size() > 0 && _playedQueue.size() > 0 && now < _holdUntil && ready(EVENTS)) {
            // a press waits for the played reports before it, and those ride on an events request
            sendEvents(call);
        }
        if (_commands.size() > 0 && ready(CMD) && (_playedQueue.size() == 0 || now >= _holdUntil)) {
            sendCommand(call);
        }
        if ((_gone || now - _lastEventsAt >= EVENTS_MAX_GAP_MS) && ready(EVENTS)) {
            // also at once after a route said the call is gone: the events say whether it ended
            sendEvents(call);
        }
        if (_playedQueue.size() > 0 && _pieces.size() == 0 && !_expectPiece && ready(EVENTS)) {
            // with no piece left to fetch, on whose request it would ride, a played report goes on an
            // events request at once, also while his turn is open (the link is idle while the microphone
            // starts): the press that ends the turn never overtakes it
            sendEvents(call);
        }
        if (_commands.size() == 0 && audioDue() && ready(AUDIO)) {
            sendAudio(call);
        }
        if (_pieces.size() > 0 && !recording && _unplayed < UNPLAYED_MAX && ready(PIECE)) {
            sendPiece(call);
        }
        if (_expectPiece && !_eventsFirst && _pieces.size() == 0 && !recording && ready(PIECE)) {
            // the answer's first piece, asked for before the events announce it
            fetchPiece(call, _lastPiece + 1, 0, true);
        }
        if (logDue && ready(LOG)) {
            sendLog(call);
        }
        if (!turnOpen() && ready(EVENTS)) {
            sendEvents(call);
        }
    }

    // His turn is on its way to the server: being recorded, or its audio or its press not yet taken.
    private function turnOpen() as Boolean {
        var turn = _kept;
        return recording || _captureOpen || _endPending || _commands.size() > 0 || _chunks.size() > 0
            || (turn != null && !asking && Kept.unsent(turn) > 0);
    }

    // The next part the server lacks goes once the server has said where the turn stands, and he has
    // said that a turn waiting for his word goes.
    private function audioDue() as Boolean {
        var turn = _kept;
        return turn != null && !_sync && !_gone && !asking && Kept.unsent(turn) > 0;
    }

    private function url(path as String) as String {
        // the log outside a call has its own route
        return _env.baseUrl() + (path.find("/api/") == 0 ? "" : Api.VOICE_CALL) + path;
    }

    // Starts the request of a lane, or fails it when it cannot go out (no setup, no phone).
    private function go(lane as Number, verb as Communications.HttpRequestMethod, path as String,
            params as Dictionary<Object, Object>?, options as Dictionary) as Void {
        var l = _lanes[lane];
        var check = _env.check();
        if (check == 1) {
            stopForGood("Set the server in Garmin Connect", false);
            _fatalNotSet = true;
            return;
        }
        if (check == 2) {
            failed(lane, Communications.BLE_CONNECTION_UNAVAILABLE);
            return;
        }
        l.busy = true;
        l.sentAt = _env.now();
        l.token += 1;
        _inflight += 1;
        l.crowd = _inflight;
        options[:method] = verb;
        try {
            _env.request(url(path) + retryTag(path, l.failures), params, options, new Answer(self, lane, l.token).method(:onResponse));
        } catch (ex) {
            l.busy = false;
            _inflight -= 1;
            failed(lane, Communications.BLE_ERROR);
        }
    }

    // A repeated request carries its attempt number: the simulator answers an identical repeat of a
    // failed request from memory without asking the server, and the server ignores the parameter.
    private function retryTag(path as String, failures as Number) as String {
        if (failures == 0) {
            return "";
        }
        return (path.find("?") == null ? "?" : "&") + "try=" + failures;
    }

    // Options for a request answered with JSON; contentType is the body's, when it has one.
    private function jsonOptions(contentType as Object?) as Dictionary {
        var headers = Wire.authorization();
        if (contentType != null) {
            headers["Content-Type"] = contentType;
        }
        return {
            :headers => headers,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
    }

    private function jsonPost(lane as Number, path as String, body as Dictionary<Object, Object>) as Void {
        go(lane, Communications.HTTP_REQUEST_METHOD_POST, path, body, jsonOptions(Communications.REQUEST_CONTENT_TYPE_JSON));
    }

    private function sendOpen() as Void {
        _openSentAt = _env.now();
        if (_noPhoneSince < 0) {
            Trace.add("open", null);
        }
        jsonPost(OPEN, "", {} as Dictionary<Object, Object>);
    }

    private function sendEvents(call as String) as Void {
        _pollsSent += 1;
        _pollNo = _pollsSent;
        _lastEventsAt = _env.now();
        var params = {"after" => _cursor, "wait" => turnOpen() || _expectPiece ? 0 : POLL_WAIT_S} as Dictionary<Object, Object>;
        _riding[0] = -1;
        if (_playedQueue.size() > 0) {
            _riding[0] = _playedQueue[0];
            params["played"] = _riding[0];
        }
        go(EVENTS, Communications.HTTP_REQUEST_METHOD_GET, "/" + call + "/events", params, jsonOptions(null));
    }

    private function sendCommand(call as String) as Void {
        _cmdOut = _commands[0];
        jsonPost(CMD, "/" + call + "/command", _commands[0] as Dictionary<Object, Object>);
    }

    // While the call hangs up: the drop of the turn he left goes to the call that is ending.
    private function queueDropTo(call as String) as Void {
        var id = Kept.dropId();
        if (id != null) {
            _dropOut = id;
            _cmdOut = {"action" => "drop", "id" => id} as Dictionary<String, Object>;
            _lanes[CMD].failures = 0;
            _lanes[CMD].notBefore = 0;
            jsonPost(CMD, "/" + call + "/command", _cmdOut as Dictionary<Object, Object>);
        }
    }

    // The next part the server lacks, under its number in the turn. The press that ends the turn
    // rides on its last part, unless he had to confirm the turn, which only a command can say.
    private function sendAudio(call as String) as Void {
        var turn = _kept;
        if (turn == null) {
            return;
        }
        var n = Kept.num(turn, "sent");
        var body = Kept.partOf(turn, n);
        if (body == null) {
            lostTurn("storage");
            return;
        }
        _body = body;
        if (_bodyEnd == 0 && _endPending && !_captureOpen && _chunks.size() == 0 && !_confirm && !_pressOut
                && n == Kept.num(turn, "parts") - 1 && _env.now() >= _pressNotBefore) {
            // the turn's last audio: the press that ends it rides along
            _bodyEnd = endPress();
            Trace.add("press", {"press" => _bodyEnd, "turn" => _turn, "on" => "audio", "ago" => ago(turn)});
        }
        turn["out"] = true;
        var options = jsonOptions("audio/ogg");
        options[:body] = body as Object;
        go(AUDIO, Communications.HTTP_REQUEST_METHOD_POST, "/" + call + "/audio?turn=" + _turn + "&seq=" + n
            + "&after_press=" + _afterPress + "&id=" + (turn["id"] as String)
            + (_bodyEnd > 0 ? "&end=" + _bodyEnd + "&ago=" + ago(turn) : ""), null, options);
    }

    private function sendPiece(call as String) as Void {
        if (_pieces[0]["n"] == _timeoutN && _pieceTimeouts >= PIECE_TIMEOUTS) {
            // asked for ahead and never brought: the announced piece is not asked again
            nextPiece();
            return;
        }
        fetchPiece(call, _pieces[0]["n"] as Number, _pieces[0]["ms"] as Number, false);
    }

    // Asks for piece n. An announced one is there; one asked for ahead of its announcement (spec) is
    // waited for on the server, which answers without a body when it has not come in time.
    private function fetchPiece(call as String, n as Number, ms as Number, spec as Boolean) as Void {
        if (spec != _fetchSpec) {
            // the tries of a piece asked for ahead do not count against an announced one
            _pieceTries = 0;
        }
        _fetchN = n;
        _fetchLen = ms;
        _fetchSpec = spec;
        var query = spec ? "?wait=" + (_ahead == AHEAD_PIECES ? PIECE_WAIT_S : NEXT_WAIT_S) : "";
        _riding[1] = -1;
        if (_playedQueue.size() > 0) {
            _riding[1] = _playedQueue[0];
            query += (spec ? "&" : "?") + "played=" + _riding[1];
        }
        var options = {
            :headers => Wire.authorization(),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_OCTET_STREAM
        };
        go(PIECE, Communications.HTTP_REQUEST_METHOD_GET, "/" + call + "/piece/" + n + query, null, options);
    }

    // The detailed trace makes more lines, so a batch holds more.
    private function batchSize() as Number {
        return Trace.debugOn ? LOG_BATCH * 2 : LOG_BATCH;
    }

    // The log, to the call's route, or to the one outside a call when there is no call.
    private function sendLog(call as String?) as Void {
        var count = Trace.lines.size() < batchSize() ? Trace.lines.size() : batchSize();
        _logSent = count;
        _logUrgent = false;
        _logToCall = call != null;
        _lastLog = _env.now();
        jsonPost(LOG, call != null ? "/" + call + "/log" : Api.LOG, {"batch" => _logBatch, "sent_t" => _env.now(), "lines" => Trace.batch(count)} as Dictionary<Object, Object>);
    }

    private function sendHang() as Void {
        var id = _hangId;
        if (id != null) {
            go(HANG, Communications.HTTP_REQUEST_METHOD_DELETE, "/" + id, null, jsonOptions(null));
        }
    }

    // ----- answers

    function onHttp(lane as Number, token as Number, code as Number, data as Dictionary or String or ByteArray or Null) as Void {
        var l = _lanes[lane];
        if (token != l.token || !l.busy) {
            return;
        }
        l.busy = false;
        recalcInflight();
        var rtt = _env.now() - l.sentAt;
        if (lane == EVENTS) {
            _lastEventsAt = _env.now();
        }
        _requests += 1;
        var bytes = data instanceof ByteArray ? data.size() : (lane == AUDIO && _body != null ? (_body as ByteArray).size() : 0);
        if (Trace.debugOn) {
            // every request, when it is answered; it went out ms before
            Trace.add("req", {"lane" => l.name, "ms" => rtt, "code" => code, "bytes" => bytes});
        } else if ((lane != EVENTS && rtt > SLOW_MS) || rtt > (POLL_WAIT_S + 6) * 1000) {
            Trace.add("rtt", {"lane" => l.name, "ms" => rtt, "bytes" => bytes, "code" => code});
        }
        var ok = code >= 200 && code < 300;
        if (code >= 0 || code == Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE) {
            // the phone brought an answer: the link works, whatever the server said
            _failingSince = -1;
        }
        if (lane == EVENTS || lane == PIECE) {
            // the report that rode on this request is delivered when the request was
            var slot = lane == EVENTS ? 0 : 1;
            if (ok && _riding[slot] >= 0) {
                _playedQueue.remove(_riding[slot]);
            }
            _riding[slot] = -1;
        }
        if (lane == EVENTS) {
            _eventsFirst = false;
        }
        var empty = !(data instanceof ByteArray) || data.size() == 0;
        if (lane == PIECE && _fetchSpec && !_closing && ((ok && empty) || code == -400)) {
            // the piece asked for ahead has not come yet: the events are asked, then the first piece of
            // an answer is asked for again; a later one is left to the events
            _eventsFirst = true;
            _expectPiece = _ahead == AHEAD_PIECES;
            l.failures = 0;
            l.notBefore = 0;
        } else if (lane == PIECE && _fetchSpec && !_closing && code == 404) {
            // no piece will have that number, or the call is gone: the events, asked next, say which
            _expectPiece = false;
            _lastEventsAt = 0;
        } else if (ok || code == -400 && (lane == HANG || lane == CMD || lane == LOG)) {
            if (succeeded(lane, code, data)) {
                l.failures = 0;
                l.notBefore = 0;
            }
        } else {
            rejected(lane, code, data);
        }
        if (_closing) {
            pump();
            finishClosing(_env.now());
            return;
        }
        autoRecord(_env.now());
        pump();
        changed();
    }

    private function rejected(lane as Number, code as Number, data as Dictionary or String or ByteArray or Null) as Void {
        if (_closing) {
            // hanging up: a call the server already forgot is as good as hung up
            if (code == 404 || !CallLogic.retryable(code)) {
                if (lane == LOG) {
                    Trace.confirm(_logSent);
                } else if (lane == HANG) {
                    _hangId = null;
                }
            } else {
                failed(lane, code);
            }
            return;
        }
        if (code == Communications.SECURE_CONNECTION_REQUIRED || code == Communications.UNSUPPORTED_CONTENT_TYPE_IN_RESPONSE) {
            stopForGood("Request refused, code " + code, false);
            Trace.add("request_refused", {"lane" => _lanes[lane].name, "code" => code});
        } else if (code == 401) {
            stopForGood("Watch key rejected", false);
            Trace.add("key_rejected", {"lane" => _lanes[lane].name});
        } else if (code == 403 && lane == OPEN) {
            stopForGood("Computer is only for the owner", false);
            Trace.add("owner_only", null);
        } else if (code == 404 && lane == PIECE) {
            // cleared or already played
            Trace.add("piece_gone", {"n" => _pieces.size() > 0 ? _pieces[0]["n"] : -1});
            nextPiece();
        } else if (code == 404 && lane == HANG) {
            _hangId = null;
        } else if (code == 404 && lane == EVENTS) {
            Trace.add("call_gone", {"code" => code});
            newCallAfterLoss();
        } else if (code == 404) {
            // an ended call answers its other routes with 404 while its events still say why
            Trace.add("route_gone", {"lane" => _lanes[lane].name});
            if (lane == LOG) {
                if (_logToCall) {
                    _logHold = true;
                } else {
                    _orphanHold = true;
                }
            } else if (lane == AUDIO || lane == CMD) {
                // nothing more goes to this call until the events, asked at once, have said whether
                // it ended; the turn goes on being recorded and kept meanwhile
                _gone = true;
                _body = null;
                clearCommands();
                _turnSent = false;
                _lastEventsAt = 0;
            } else {
                drop(lane);
            }
        } else if (code == 422 && lane == AUDIO) {
            // the call cannot use the part, but the server stored it: the turn goes on, and its press
            // has the server read the stored audio as a whole
            Trace.add("turn_part_unread", {"seq" => _kept != null ? Kept.num(_kept as Dictionary<String, Object?>, "sent") : -1});
            partStored(null);
        } else if (code == 409 && (lane == AUDIO || (lane == CMD && isTurnCommand("press")))) {
            // the server is somewhere else in the turn, or the turn is finished: it is asked, since
            // the body of an error answer may not reach the watch
            Trace.add("turn_conflict", {"lane" => _lanes[lane].name});
            _body = null;
            if (lane == CMD) {
                dropCommand();
            }
            _bodyEnd = 0;
            _endPress = 0;
            _sync = true;
        } else if (code == 413 && lane == AUDIO) {
            capTurn();
        } else if (CallLogic.retryable(code)) {
            failed(lane, code);
        } else {
            // the server refused this one for good: drop it, keep going
            Trace.add("refused", {"lane" => _lanes[lane].name, "code" => code});
            drop(lane);
        }
    }

    // The command in flight is one for a kept turn, of this action.
    private function isTurnCommand(action as String) as Boolean {
        var out = _cmdOut;
        return out != null && action.equals(out["action"]) && out["id"] != null;
    }

    // The command in flight is done with, answered or refused.
    private function dropCommand() as Void {
        var out = _cmdOut;
        _cmdOut = null;
        if (out != null && _commands.size() > 0 && _commands[0] == out) {
            _commands = _commands.slice(1, null) as Array<Dictionary<String, Object>>;
        }
        if (out != null && "press".equals(out["action"]) && out["id"] != null) {
            _pressOut = false;
        } else if (out != null && "turn".equals(out["action"])) {
            _syncOut = false;
        } else if (out != null && "drop".equals(out["action"])) {
            _dropOut = null;
        }
    }

    // The server stored the part in flight. The answer names the next one it needs; a number that
    // does not move the turn on means the two disagree, and the server is asked.
    private function partStored(data as Dictionary or String or ByteArray or Null) as Void {
        var turn = _kept;
        var ended = _bodyEnd;
        _bodyEnd = 0;
        _body = null;
        if (turn == null) {
            return;
        }
        var sent = Kept.num(turn, "sent");
        var count = Outcome.number(data instanceof Dictionary ? data["next_seq"] as Object? : null);
        var next = count != null ? count : sent + 1;
        if (next <= sent) {
            _endPress = 0;
            _sync = true;
            return;
        }
        Kept.confirm(turn, next);
        caughtUp(turn);
        if (ended > 0 && data != null) {
            // the press rode on this request
            pressAnswered(data);
        } else if (ended > 0) {
            _endPress = 0;
        }
    }

    // The turn holds more than the server takes: it ends with what the server has, as his press
    // would end it.
    private function capTurn() as Void {
        var turn = _kept;
        if (turn == null) {
            return;
        }
        Trace.add("turn_capped", {"id" => turn["id"] as String, "sent" => Kept.num(turn, "sent"), "parts" => Kept.num(turn, "parts")});
        setNotice("Turn too long");
        if (recording) {
            endTurn();
        }
        _chunks = [];
        _chunkBytes = 0;
        _body = null;
        _bodyEnd = 0;
        Kept.clear(turn);
    }

    private function succeeded(lane as Number, code as Number, data as Dictionary or String or ByteArray or Null) as Boolean {
        if (lane == OPEN) {
            var id = data instanceof Dictionary ? data["call"] as Object? : null;
            if (id instanceof String && _closing) {
                // the screen has left: the call that just opened is hung up
                _hangId = id;
                return true;
            }
            if (id instanceof String) {
                _call = id;
                _openMs = _env.now() - _openSentAt;
                Trace.add("opened", {"call" => id, "ms" => _openMs});
                if (_noPhoneSince >= 0) {
                    // the phone link came back: one tap says the call is up
                    Trace.add("phone_back", {"waited_ms" => _env.now() - _noPhoneSince});
                    _noPhoneSince = -1;
                    notice = null;
                    _io.cue.invoke(CallLogic.CUE_TAKEN);
                }
            } else {
                failed(OPEN, 0);
                return false;
            }
        } else if (lane == EVENTS) {
            return handleEvents(data);
        } else if (lane == CMD) {
            var out = _cmdOut;
            var action = out != null ? out["action"] as Object? : null;
            var id = out != null ? out["id"] as Object? : null;
            dropCommand();
            if ("turn".equals(action)) {
                synced(data);
            } else if ("drop".equals(action)) {
                var dropped = id instanceof String ? Kept.find(id) : null;
                if (dropped != null) {
                    Kept.forget(dropped);
                }
            } else if ("press".equals(action) && id != null) {
                pressAnswered(data);
            } else if (_turnSent) {
                pressTaken();
            }
            _failStreak = 0;
        } else if (lane == AUDIO) {
            partStored(data instanceof Dictionary ? data : {});
        } else if (lane == PIECE) {
            if (data instanceof ByteArray && _fetchN >= 0 && (_fetchSpec || _pieces.size() > 0)) {
                var n = _fetchN;
                var ms = _fetchLen;
                _fetchN = -1;
                _unplayed += data.size();
                _sizes[n] = data.size();
                playbackActive = true;
                if (_fetchSpec) {
                    // its announcement, with its length, is still to come: until the player says the piece
                    // is over it counts as long as its bytes would last at 16 kbit/s, more than it is
                    _ahead -= 1;
                    _expectPiece = _ahead > 0;
                    _lastPiece = n > _lastPiece ? n : _lastPiece;
                    ms = data.size() / 2;
                    if (_pieceMs < 0 && _sentMs >= 0) {
                        _pieceMs = _env.now() - _pressAt - _sentMs;
                    }
                } else {
                    nextPiece();
                }
                var length = ms > 0 ? ms : PIECE_MS_DEFAULT;
                var started = _lanes[PIECE].sentAt;
                var now = _env.now();
                Trace.debug("piece_fetch", {"n" => n, "bytes" => data.size(), "ms" => now - started});
                if (_fetchMs < 0) {
                    _fetchMs = now - started;
                }
                _playEnd = (_playEnd > now ? _playEnd : now) + length;
                _fed.add([n, _playEnd]);
                _io.play.invoke(n, length, data);
            } else {
                failed(PIECE, -400);
                return false;
            }
        } else if (lane == LOG) {
            Trace.confirm(_logSent);
            _logBatch += 1;
        } else if (lane == HANG) {
            _hangId = null;
        }
        return true;
    }

    private function nextPiece() as Void {
        _pieceTries = 0;
        if (_pieces.size() > 0) {
            _pieces = _pieces.slice(1, null) as Array<Dictionary<String, Number>>;
        }
    }

    // A failed request waits, then goes again.
    private function failed(lane as Number, code as Number) as Void {
        var l = _lanes[lane];
        if (lane == OPEN && _call == null && !_closing && code == Communications.BLE_CONNECTION_UNAVAILABLE && waitForPhone()) {
            return;
        }
        l.failures += 1;
        l.notBefore = _env.now() + CallLogic.backoff(l.failures);
        if (lane == OPEN && _call == null && !_closing && l.failures >= OPEN_TRIES && _kept == null) {
            stopForGood("Cannot connect (" + codeText(code) + ")", true);
            return;
        }
        if (code < 0 && _failingSince < 0) {
            _failingSince = _env.now();
        }
        // the first retries say what went wrong; a long outage then adds a line only now and then
        if (lane != LOG) {
            _logUrgent = true;
        }
        if (lane != LOG && (l.failures <= 3 || l.failures % 10 == 0)) {
            Trace.add("retry", {"lane" => l.name, "code" => code, "n" => l.failures, "crowd" => l.crowd});
        }
        if (lane == PIECE) {
            _pieceTries += 1;
            if (code == Communications.NETWORK_REQUEST_TIMED_OUT) {
                if (_fetchN != _timeoutN) {
                    _timeoutN = _fetchN;
                    _pieceTimeouts = 0;
                }
                _pieceTimeouts += 1;
                if (_pieceTimeouts >= PIECE_TIMEOUTS) {
                    // the link does not bring this piece: the answer goes on without it
                    Trace.add("piece_timeouts", {"n" => _fetchN, "n_timeouts" => _pieceTimeouts});
                    setNotice("Answer lost on the link");
                    _pieceTries = PIECE_TRIES;
                }
            }
            if (_pieceTries >= PIECE_TRIES && _fetchSpec) {
                // asking ahead is given up; the events name the piece
                _expectPiece = false;
                _pieceTries = 0;
            } else if (_pieceTries >= PIECE_TRIES) {
                Trace.add("piece_dropped", {"n" => _pieces.size() > 0 ? _pieces[0]["n"] : -1});
                nextPiece();
            }
        }
    }

    // The open found no phone link: it asks again soon, without counting a failure, until the link
    // is back. The turn keeps recording meanwhile, and while a turn of his is open the wait has no
    // end; with none, it is over after PHONE_WAIT_MS (false), which gives the call up.
    private function waitForPhone() as Boolean {
        var now = _env.now();
        if (_noPhoneSince < 0) {
            _noPhoneSince = now;
            Trace.add("no_phone", {});
        }
        if (now - _noPhoneSince >= PHONE_WAIT_MS && _kept == null) {
            return false;
        }
        _lanes[OPEN].notBefore = now + PHONE_POLL_MS;
        setNotice("No phone, waiting");
        changed();
        return true;
    }

    // What a failed request's code says, for the screen.
    private function codeText(code as Number) as String {
        if (code == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return "no phone";
        } else if (code == Communications.NETWORK_REQUEST_TIMED_OUT) {
            return "no answer";
        } else if (code >= 500) {
            return "server error " + code;
        }
        return "code " + code;
    }

    // A request the server will never take is not tried again.
    private function drop(lane as Number) as Void {
        if (lane == CMD) {
            var out = _cmdOut;
            var action = out != null ? out["action"] as Object? : null;
            var id = out != null ? out["id"] as Object? : null;
            dropCommand();
            if ("turn".equals(action)) {
                // a server that knows no kept turns: the turn goes from where the watch has it
                _sync = false;
            } else if ("drop".equals(action)) {
                var dropped = id instanceof String ? Kept.find(id) : null;
                if (dropped != null) {
                    Kept.forget(dropped);
                }
            } else if ("press".equals(action) && id != null) {
                refusedTurn();
            } else {
                _turnSent = false;
            }
        } else if (lane == AUDIO) {
            _body = null;
            refusedTurn();
        } else if (lane == LOG) {
            Trace.confirm(_logSent);
        } else if (lane == PIECE && _fetchSpec) {
            _expectPiece = false;
        } else if (lane == PIECE) {
            nextPiece();
        } else if (lane == OPEN) {
            failed(OPEN, 0);
        }
    }

    // The server refuses the turn for a reason the watch does not know: it stays on the watch,
    // and he says whether it is tried again or dropped.
    private function refusedTurn() as Void {
        if (recording || _captureOpen) {
            var turn = _kept;
            if (turn != null) {
                turn["ms"] = spokenMs();
            }
            recording = false;
            stopMic();
            _captureOpen = false;
        }
        cutParts(true);
        setNotice("Server refuses the turn");
        ask("turn_refused");
    }

    // A short message on the screen.
    private function setNotice(text as String) as Void {
        notice = text;
        _noticeUntil = _env.now() + NOTICE_MS;
    }

    // The call cannot go on: the microphone and the player stop, the error cue sounds and the reason
    // stays on screen. A fatal reason ends Computer; a stalled one waits for Start.
    private function stopForGood(reason as String, retryable as Boolean) as Void {
        Trace.add("stopped", {"reason" => reason});
        if (retryable) {
            stalled = reason;
        } else {
            fatal = reason;
        }
        leaveTurn("stopped");
        _io.stopPlayback.invoke();
        _io.cue.invoke(CallLogic.CUE_ERROR);
        changed();
    }

    // A recording that failed: the next try waits longer each time, and after a few the cause stays
    // on screen until Start tries again.
    private function recordFailed(cause as String) as Void {
        _failStreak += 1;
        var wait = 2000 * _failStreak;
        _autoAt = _env.now() + (wait > 30000 ? 30000 : wait);
        Trace.add("record_failed", {"cause" => cause, "n" => _failStreak});
        if (_failStreak >= MAX_FAILS) {
            stopForGood(cause, true);
        } else {
            setNotice(cause);
        }
    }

    // ----- events

    private function handleEvents(data as Dictionary or String or ByteArray or Null) as Boolean {
        if (!(data instanceof Dictionary)) {
            failed(EVENTS, -400);
            return false;
        }
        var events = data["events"] as Object?;
        var cursor = data["cursor"] as Object?;
        if (events instanceof Array) {
            for (var i = 0; i < events.size(); i++) {
                var e = events[i] as Object?;
                if (e instanceof Dictionary) {
                    handleEvent(e as Dictionary<String, Object>);
                }
            }
        }
        if (cursor instanceof Number && cursor > _cursor) {
            _cursor = cursor;
        }
        // the call answers its events and did not end: the 404 was that route's alone
        _gone = false;
        return true;
    }

    private function handleEvent(e as Dictionary<String, Object>) as Void {
        var index = e["i"] as Object?;
        if (index instanceof Number) {
            if (index <= _lastEvent) {
                return;
            }
            _lastEvent = index;
        }
        var state = e["state"] as Object?;
        var piece = e["piece"] as Object?;
        if (state instanceof String) {
            engine = state;
            var who = e["owner"] as Object?;
            if (who instanceof String) {
                var title = e["session"] as Object?;
                if (!who.equals(owner)) {
                    Trace.add("owner", {"owner" => who});
                }
                owner = who;
                sessionTitle = title instanceof String ? title : "";
                if (who.equals("computer")) {
                    _leaving = false;
                }
            }
            Trace.debug("state", {"state" => state});
            if (state.equals("generating")) {
                _expectPiece = !inSession() && _pieces.size() == 0;
                _ahead = AHEAD_PIECES;
            } else if (!state.equals("speaking")) {
                _expectPiece = false;
            }
            if (state.equals("generating") || state.equals("speaking")) {
                _turnSent = false;
            } else if (_turnSent && _commands.size() == 0 && _turnSentPoll >= 0
                    && (_pollNo > _turnSentPoll || (inSession() && state.equals("wake")))) {
                // listening again, in an answer to a poll sent after the press was taken: nothing to
                // answer. A session says "wake" the moment it has the press, and never again, so there
                // it counts whichever poll brings it.
                _turnSent = false;
            }
        } else if (piece instanceof Number) {
            var ms = e["ms"] as Object?;
            var text = e["text"] as Object?;
            if (text instanceof String && !inSession()) {
                // also for a piece that was fetched ahead of this event, and may be playing already
                if (piece == _playingN && playbackActive) {
                    spoken = text;
                } else if (piece > _playingN) {
                    _texts[piece] = text;
                }
            }
            if (piece > _lastPiece) {
                _lastPiece = piece;
                _pieces.add({"n" => piece, "ms" => ms instanceof Number ? ms : 0} as Dictionary<String, Number>);
                _expectPiece = false;
                if (_pieceMs < 0 && _sentMs >= 0) {
                    _pieceMs = _env.now() - _pressAt - _sentMs;
                }
                Trace.debug("piece", {"n" => piece, "ms" => ms, "ref" => e["ref"]});
            }
        } else if (e["clear"] != null) {
            Trace.add("clear", {"dropped" => e["dropped"]});
            _expectPiece = false;
            dropPieces();
            _io.stopPlayback.invoke();
        } else if (e["notice"] instanceof Dictionary) {
            var n = e["notice"] as Dictionary<String, Object>;
            var text = n["text"] as Object?;
            var code = n["code"] as Object?;
            Trace.add("notice", {"code" => code});
            setNotice(text instanceof String ? text : "Notice");
            if ("heard_nothing".equals(code)) {
                // the press had nothing to answer: listening goes on
                _turnSent = false;
            }
        } else if (e["ended"] != null) {
            // the server ended the call (no word for a long time, or Computer ended it): nothing more is
            // recorded or fetched, what the player holds finishes, then the bye and the hang-up
            Trace.add("ended", {"reason" => e["ended"]});
            _ending = true;
            leaveTurn("ended");
            clearCommands();
            _pieces = [];
            _expectPiece = false;
            if (!_io.busy.invoke()) {
                endCall();
            }
        } else if (e["heard"] instanceof String) {
            heard = e["heard"] as String;
        } else if (e["turn"] instanceof Dictionary) {
            // where a kept turn stands, once the server has turned it into text
            var t = e["turn"] as Dictionary<String, Object>;
            var turn = _kept;
            var where = t["state"] as Object?;
            if (turn != null && (turn["id"] as String).equals(t["id"]) && where instanceof String) {
                turnIs(where, t["error"] as Object?, "event");
            }
        }
    }

    // ----- a call ends or is lost

    // The end the server announced: the bye, and the hang-up that lets the screen leave.
    private function endCall() as Void {
        if (_closing) {
            return;
        }
        Trace.add("bye", null);
        _io.cue.invoke(CallLogic.CUE_BYE);
        hangUp();
    }

    // The server does not know the call any more: a new one takes its place, sooner or later; losses
    // in quick succession wait longer, and after a few the screen stops and says so.
    private function newCallAfterLoss() as Void {
        var now = _env.now();
        var recent = [] as Array<Number>;
        for (var i = 0; i < _lossTimes.size(); i++) {
            if (now - _lossTimes[i] < LOSS_WINDOW_MS) {
                recent.add(_lossTimes[i]);
            }
        }
        recent.add(now);
        _lossTimes = recent;
        resetCall();
        var n = recent.size();
        if (n >= MAX_LOSSES && _kept == null) {
            Trace.add("calls_lost", {"n" => n});
            stopForGood("The server keeps losing the call", true);
        } else {
            if (n >= 2) {
                var wait = 2000 * (1 << (n - 2));
                _lanes[OPEN].notBefore = now + (wait > 8000 ? 8000 : wait);
            }
            setNotice("Reconnecting");
        }
    }

    // The call is gone. A turn of his that is open stays, goes on being recorded, and is the first
    // turn of the call that follows, which asks the server where it stands.
    private function resetCall() as Void {
        _io.stopPlayback.invoke();
        _body = null;
        clearCommands();
        _sync = _kept != null;
        if (_transcribing) {
            // the call that was to bring the turn's answer is gone: the press goes again in the next
            _transcribing = false;
            _endPending = true;
        }
        _call = null;
        _cursor = 0;
        _lastEvent = 0;
        _lastPiece = -1;
        _pieces = [];
        _unplayed = 0;
        _sizes = {};
        _fed = [];
        _playEnd = 0;
        _reported = {};
        _playedQueue = [];
        _logHold = false;
        _press = 0;
        _afterPress = 0;
        _texts = {};
        _playingN = -1;
        _gone = false;
        spoken = "";
        owner = "computer";
        sessionTitle = "";
        _leaving = false;
        _backs = 0;
        _riding = [-1, -1];
        _expectPiece = false;
        _eventsFirst = false;
        _fetchN = -1;
        _turn = _kept != null ? 1 : 0;
        _turnSent = false;
        _turnSentPoll = -1;
        engine = "";
        heard = "";
        playbackActive = false;
        for (var i = 0; i < _lanes.size(); i++) {
            if (i != LOG && i != HANG) {
                _lanes[i].token += 1;
                _lanes[i].busy = false;
                _lanes[i].failures = 0;
                _lanes[i].notBefore = 0;
            }
        }
        recalcInflight();
    }

    private function changed() as Void {
        _io.changed.invoke();
    }
}

// The callback of one request: it remembers the lane and the token the request went out with.
class Answer {
    private var _client as CallClient;
    private var _lane as Number;
    private var _token as Number;

    function initialize(client as CallClient, lane as Number, token as Number) {
        _client = client;
        _lane = lane;
        _token = token;
    }

    function onResponse(code as Number, data as Dictionary or String or ByteArray or Null) as Void {
        _client.onHttp(_lane, _token, code, data);
    }
}
