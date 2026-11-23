import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// The audio side of a call, as the client sees it: methods the screen supplies.
class CallIo {
    var startCapture as Method() as Boolean;
    var stopCapture as Method() as Void;
    var play as Method(n as Number, ms as Number, pcm as ByteArray) as Void;
    var stopPlayback as Method() as Void;
    var changed as Method() as Void;

    function initialize(startCapture as Method() as Boolean, stopCapture as Method() as Void,
            play as Method(n as Number, ms as Number, pcm as ByteArray) as Void, stopPlayback as Method() as Void,
            changed as Method() as Void) {
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
// answer's PCM pieces for the screen to play and reports what played. Lanes keep their own retry
// state; a call the server no longer knows (404) is replaced by a new one. Every failure and retry
// goes to the server's log route.
class CallClient {
    const POLL_WAIT_S = 10;
    // requests in flight at once; the link says when it is fewer (BLE_QUEUE_FULL)
    const START_PARALLEL = 3;
    // the wait asked of the long-poll once the link carries one request at a time
    const POLL_WAIT_SINGLE_S = 1;
    // how long a press holds back for the played reports that belong before it
    const PRESS_HOLD_MS = 1500;
    const TICK_MS = 250;
    // the longest chunk body; what the link carries while a request is out is sent in the next one
    const CHUNK_MAX = 6144;
    // pending audio while the link is down: about half a minute of Opus
    const BUFFER_MAX = 65536;
    // fetched but not yet played PCM
    const UNPLAYED_MAX = 160000;
    const PIECE_TRIES = 6;
    // 409s in a row on one turn before it is given up
    const MAX_CONFLICTS = 4;
    const AUTO_RECORD_DELAY_MS = 400;
    const TURN_SENT_MS = 6000;
    const NOTICE_MS = 4000;
    const STOP_WAIT_MS = 1500;
    const LOG_BATCH = 20;
    const LOG_EVERY_MS = 2500;
    const MEM_EVERY_MS = 15000;
    const HANG_GRACE_MS = 4000;

    enum {
        OPEN,
        EVENTS,
        CMD,
        AUDIO,
        PIECE,
        PLAYED,
        LOG,
        HANG
    }

    private var _io as CallIo;
    private var _lanes as Array<Lane> = [
        new Lane("open", 20000), new Lane("events", 30000), new Lane("command", 20000), new Lane("audio", 20000),
        new Lane("piece", 40000), new Lane("played", 20000), new Lane("log", 20000), new Lane("hang", 10000)
    ];
    private var _clock as Timer.Timer = new Timer.Timer();
    private var _inflight as Number = 0;
    private var _parallel as Number = START_PARALLEL;
    private var _closing as Boolean = false;
    private var _closedAt as Number = 0;

    // what the screen shows
    var fatal as String? = null;
    var engine as String = "";
    var heard as String = "";
    var notice as String? = null;
    private var _noticeUntil as Number = 0;
    var endedReason as String? = null;
    var recording as Boolean = false;
    var recordingSince as Number = 0;
    var playbackActive as Boolean = false;

    private var _call as String? = null;
    private var _lastEvent as Number = 0;
    private var _cursor as Number = 0;
    private var _lastPiece as Number = -1;
    private var _pieces as Array<Dictionary<String, Number>> = [];
    private var _pieceTries as Number = 0;
    private var _unplayed as Number = 0;
    private var _sizes as Dictionary<Number, Number> = {};
    private var _playedQueue as Array<Number> = [];

    private var _turn as Number = 0;
    private var _seq as Number = 0;
    private var _turnBytes as Number = 0;
    private var _chunks as Array<ByteArray> = [];
    private var _chunkBytes as Number = 0;
    private var _body as ByteArray? = null;
    private var _endPending as Boolean = false;
    private var _captureOpen as Boolean = false;
    private var _stopAt as Number = 0;
    private var _turnSent as Boolean = false;
    private var _turnSentAt as Number = 0;
    private var _autoAt as Number = 0;

    private var _press as Number = 0;
    // the last press sent before the current turn began; the server holds the turn's audio for it
    private var _afterPress as Number = 0;
    // the turn's chunks that are acknowledged, kept (bounded) in case the server asks for them again
    private var _sentBodies as Array<ByteArray> = [];
    private var _sentBytes as Number = 0;
    private var _sentBase as Number = 0;
    private var _logHold as Boolean = false;
    private var _conflicts as Number = 0;
    private var _restartTurn as Boolean = false;
    // bodies sent before, to go again with their own numbers
    private var _resend as Array<ByteArray> = [];
    private var _holdUntil as Number = 0;
    private var _commands as Array<Dictionary<String, Object>> = [];
    private var _hangId as String? = null;
    private var _closeCall as String? = null;
    private var _logSent as Number = 0;
    private var _lastLog as Number = 0;
    private var _lastMem as Number = 0;

    function initialize(io as CallIo) {
        _io = io;
    }

    // ----- the screen's side

    function start() as Void {
        Trace.add("start", null);
        _clock.start(method(:tick), TICK_MS, true);
        changed();
    }

    // The Start button: send the turn that is being recorded, cut an answer, or begin a new call
    // after the old one ended; false when there was nothing to press for.
    function press() as Boolean {
        if (fatal != null || _closing) {
            return false;
        }
        if (_call == null && endedReason != null) {
            reconnect();
        } else if (recording) {
            endTurn();
        } else if (busyAnswering()) {
            cut();
        } else {
            return false;
        }
        return true;
    }

    // A new call in place of the current one.
    function reconnect() as Void {
        Trace.add("reconnect", null);
        var old = _call;
        resetCall();
        _hangId = old;
        endedReason = null;
        changed();
    }

    function hangUp() as Void {
        if (_closing) {
            return;
        }
        _closing = true;
        _closedAt = System.getTimer();
        Trace.add("hangup", null);
        stopCapture();
        _io.stopPlayback.invoke();
        for (var i = 0; i < _lanes.size(); i++) {
            _lanes[i].token += 1;
            _lanes[i].busy = false;
        }
        _inflight = 0;
        _hangId = _call;
        _closeCall = _call;
        _call = null;
        _lanes[HANG].failures = 0;
        _lanes[LOG].failures = 0;
        _lanes[LOG].notBefore = 0;
        pump();
    }

    // A chunk of the turn's Ogg Opus stream from the capture.
    function chunk(data as ByteArray) as Void {
        if ((!recording && !_captureOpen) || _restartTurn) {
            return;
        }
        if (_chunkBytes + data.size() > BUFFER_MAX) {
            Trace.add("buffer_full", {"bytes" => _chunkBytes});
            if (recording) {
                setNotice("Link too slow");
                endTurn();
            }
            return;
        }
        _chunks.add(data);
        _chunkBytes += data.size();
        _turnBytes += data.size();
        pump();
    }

    function captureEnded() as Void {
        if (_restartTurn) {
            finishRestart();
            return;
        }
        if (_captureOpen) {
            _captureOpen = false;
            pump();
        }
    }

    function captureFailed(code as Number) as Void {
        Trace.add("capture_error", {"code" => code});
        if (recording) {
            recording = false;
            _captureOpen = false;
            setNotice("Microphone error " + code);
            discardTurn();
        }
        changed();
    }

    // The screen's player finished piece n.
    function piecePlayed(n as Number) as Void {
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
        _autoAt = System.getTimer() + AUTO_RECORD_DELAY_MS;
        changed();
    }

    function playbackFailed(code as Number) as Void {
        Trace.add("playback_error", {"code" => code});
        setNotice("Playback error");
        playbackActive = false;
        changed();
    }

    // True while there is still audio to come for the player: pieces waiting, being fetched, or just
    // handed over.
    function moreToPlay() as Boolean {
        return _pieces.size() > 0 || _lanes[PIECE].busy;
    }

    // "link ok" or the failing lane with its count.
    function linkText() as String {
        for (var i = 0; i < _lanes.size(); i++) {
            if (_lanes[i].failures > 0 && i != LOG) {
                return _lanes[i].name + " retry " + _lanes[i].failures;
            }
        }
        return "link ok";
    }

    function hasCall() as Boolean {
        return _call != null;
    }

    // ----- the turn

    private function startTurn() as Void {
        _turn += 1;
        _seq = 0;
        _turnBytes = 0;
        _chunks = [];
        _chunkBytes = 0;
        _body = null;
        _resend = [];
        _sentBodies = [];
        _sentBytes = 0;
        _sentBase = 0;
        _conflicts = 0;
        _afterPress = _press;
        _lanes[AUDIO].token += 1;
        _lanes[AUDIO].busy = false;
        recalcInflight();
        heard = "";
        if (_io.startCapture.invoke()) {
            recording = true;
            _captureOpen = true;
            recordingSince = System.getTimer();
            Trace.add("turn_start", {"turn" => _turn});
        } else {
            recording = false;
            _captureOpen = false;
            notice = "No Opus capture";
            _noticeUntil = 0;
            Trace.add("capture_unavailable", null);
        }
        changed();
    }

    private function endTurn() as Void {
        recording = false;
        _endPending = true;
        _stopAt = System.getTimer() + STOP_WAIT_MS;
        _io.stopCapture.invoke();
        changed();
    }

    private function stopCapture() as Void {
        if (recording || _captureOpen) {
            _io.stopCapture.invoke();
        }
        recording = false;
        _captureOpen = false;
        _endPending = false;
        _restartTurn = false;
    }

    private function discardTurn() as Void {
        _chunks = [];
        _chunkBytes = 0;
        _body = null;
        _resend = [];
        _sentBodies = [];
        _sentBytes = 0;
        _endPending = false;
        _lanes[AUDIO].token += 1;
        _lanes[AUDIO].busy = false;
        recalcInflight();
    }

    // The turn is over for the watch once its audio is acknowledged: the press follows.
    private function sendPressIfDrained() as Void {
        if (!_endPending || _captureOpen || _chunks.size() > 0 || _body != null || _resend.size() > 0 || _lanes[AUDIO].busy) {
            return;
        }
        _endPending = false;
        if (_turnBytes == 0) {
            Trace.add("empty_turn", null);
            setNotice("Heard nothing");
            return;
        }
        queuePress();
        _turnSent = true;
        _turnSentAt = System.getTimer();
        changed();
    }

    private function queuePress() as Void {
        _press += 1;
        _commands.add({"action" => "press", "press" => _press, "turn" => _turn} as Dictionary<String, Object>);
        _holdUntil = System.getTimer() + PRESS_HOLD_MS;
        Trace.add("press", {"press" => _press, "turn" => _turn});
    }

    // The answer is cut: playback stops now, the press goes out, and the next turn is recorded.
    private function cut() as Void {
        _io.stopPlayback.invoke();
        dropPieces();
        _turnSent = false;
        queuePress();
        startTurn();
    }

    private function busyAnswering() as Boolean {
        return _turnSent || engine.equals("generating") || engine.equals("speaking") || playbackActive || moreToPlay();
    }

    private function dropPieces() as Void {
        _pieces = [];
        _lanes[PIECE].token += 1;
        _lanes[PIECE].busy = false;
        _pieceTries = 0;
        recalcInflight();
    }

    // ----- the clock

    function tick() as Void {
        var now = System.getTimer();
        for (var i = 0; i < _lanes.size(); i++) {
            var lane = _lanes[i];
            if (lane.busy && now - lane.sentAt > lane.watchdogMs) {
                lane.token += 1;
                lane.busy = false;
                recalcInflight();
                failed(i, Communications.NETWORK_REQUEST_TIMED_OUT);
            }
        }
        if (_closing) {
            if (now - _closedAt > HANG_GRACE_MS || (!_lanes[HANG].busy && !_lanes[LOG].busy && _hangId == null && (Trace.lines.size() == 0 || _closeCall == null))) {
                _clock.stop();
            }
            pump();
            return;
        }
        if (_restartTurn && now >= _stopAt) {
            finishRestart();
        }
        if (notice != null && _noticeUntil > 0 && now >= _noticeUntil) {
            notice = null;
            changed();
        }
        if (_endPending && _captureOpen && now >= _stopAt) {
            Trace.add("capture_no_complete", null);
            _captureOpen = false;
        }
        if (_turnSent && _commands.size() == 0 && now - _turnSentAt > TURN_SENT_MS) {
            Trace.add("turn_sent_timeout", null);
            _turnSent = false;
        }
        if (now - _lastMem > MEM_EVERY_MS) {
            _lastMem = now;
            Trace.add("mem", {"free" => System.getSystemStats().freeMemory, "chunks" => _chunkBytes, "unplayed" => _unplayed});
        }
        autoRecord(now);
        pump();
        if (recording) {
            changed();
        }
    }

    private function autoRecord(now as Number) as Void {
        if (_call != null && !recording && !_endPending && !_turnSent && engine.equals("listening")
                && !playbackActive && !moreToPlay() && now >= _autoAt && fatal == null && notice != "No Opus capture") {
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

    private function ready(lane as Number) as Boolean {
        var l = _lanes[lane];
        return !l.busy && System.getTimer() >= l.notBefore && _inflight < _parallel;
    }

    function pump() as Void {
        sendPressIfDrained();
        var call = _call;
        if (_closing) {
            var closed = _closeCall;
            var logged = Trace.lines.size() == 0 || closed == null || _lanes[LOG].failures > 0;
            if (closed != null && ready(LOG) && Trace.lines.size() > 0) {
                sendLog(closed);
            }
            if (logged && ready(HANG) && _hangId != null) {
                sendHang();
            }
            return;
        }
        if (_hangId != null && ready(HANG)) {
            sendHang();
        }
        if (call == null) {
            if (fatal == null && endedReason == null && ready(OPEN)) {
                sendOpen();
            }
            return;
        }
        if (ready(EVENTS)) {
            sendEvents(call);
        }
        if (_commands.size() > 0 && ready(CMD) && (_playedQueue.size() == 0 || System.getTimer() >= _holdUntil)) {
            sendCommand(call);
        }
        if (_commands.size() == 0 && (_chunks.size() > 0 || _body != null || _resend.size() > 0) && ready(AUDIO)) {
            sendAudio(call);
        }
        if (_pieces.size() > 0 && !recording && _unplayed < UNPLAYED_MAX && ready(PIECE)) {
            sendPiece(call);
        }
        if (_playedQueue.size() > 0 && ready(PLAYED)) {
            sendPlayed(call);
        }
        var now = System.getTimer();
        if (!_logHold && Trace.lines.size() > 0 && ready(LOG) && (Trace.lines.size() >= LOG_BATCH || now - _lastLog >= LOG_EVERY_MS)) {
            sendLog(call);
        }
    }

    private function url(path as String) as String {
        return ServerConfig.url() + Api.VOICE_CALL + path;
    }

    // Starts the request of a lane, or fails it when it cannot go out (no setup, no phone). The
    // request options are a plain dictionary, which the strict check cannot match to makeWebRequest's.
    (:typecheck(false))
    private function go(lane as Number, verb as Communications.HttpRequestMethod, path as String,
            params as Dictionary<Object, Object>?, options as Dictionary) as Void {
        var l = _lanes[lane];
        if (!ServerConfig.isSet()) {
            fatal = "Set the server in Garmin Connect";
            changed();
            return;
        }
        if (!System.getDeviceSettings().phoneConnected) {
            failed(lane, Communications.BLE_CONNECTION_UNAVAILABLE);
            return;
        }
        l.busy = true;
        l.sentAt = System.getTimer();
        l.token += 1;
        _inflight += 1;
        l.crowd = _inflight;
        options[:method] = verb;
        try {
            Communications.makeWebRequest(url(path) + retryTag(path, l.failures), params, options, new Answer(self, lane, l.token).method(:onResponse));
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
        Trace.add("open", null);
        jsonPost(OPEN, "", {} as Dictionary<Object, Object>);
    }

    private function sendEvents(call as String) as Void {
        var params = {"after" => _cursor, "wait" => _parallel > 1 ? POLL_WAIT_S : POLL_WAIT_SINGLE_S} as Dictionary<Object, Object>;
        go(EVENTS, Communications.HTTP_REQUEST_METHOD_GET, "/" + call + "/events", params, jsonOptions(null));
    }

    private function sendCommand(call as String) as Void {
        jsonPost(CMD, "/" + call + "/command", _commands[0] as Dictionary<Object, Object>);
    }

    private function sendAudio(call as String) as Void {
        if (_body == null && _resend.size() > 0) {
            _body = _resend[0];
            _resend = _resend.slice(1, null) as Array<ByteArray>;
        } else if (_body == null) {
            var body = new [0]b;
            while (_chunks.size() > 0 && (body.size() == 0 || body.size() + _chunks[0].size() <= CHUNK_MAX)) {
                var c = _chunks[0];
                _chunks = _chunks.slice(1, null) as Array<ByteArray>;
                _chunkBytes -= c.size();
                body.addAll(c);
            }
            _body = body;
        }
        var options = jsonOptions("audio/ogg");
        options[:body] = _body as Object;
        go(AUDIO, Communications.HTTP_REQUEST_METHOD_POST, "/" + call + "/audio?turn=" + _turn + "&seq=" + _seq + "&after_press=" + _afterPress, null, options);
    }

    private function sendPiece(call as String) as Void {
        var n = _pieces[0]["n"] as Number;
        var options = {
            :headers => Wire.authorization(),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_OCTET_STREAM
        };
        go(PIECE, Communications.HTTP_REQUEST_METHOD_GET, "/" + call + "/piece/" + n, null, options);
    }

    private function sendPlayed(call as String) as Void {
        jsonPost(PLAYED, "/" + call + "/played", {"n" => _playedQueue[0]} as Dictionary<Object, Object>);
    }

    private function sendLog(call as String) as Void {
        var count = Trace.lines.size() < LOG_BATCH ? Trace.lines.size() : LOG_BATCH;
        _logSent = count;
        _lastLog = System.getTimer();
        jsonPost(LOG, "/" + call + "/log", {"lines" => Trace.batch(LOG_BATCH)} as Dictionary<Object, Object>);
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
        if (code >= 200 && code < 300 || code == -400 && (lane == HANG || lane == PLAYED || lane == CMD || lane == LOG)) {
            l.failures = 0;
            l.notBefore = 0;
            succeeded(lane, code, data);
        } else {
            rejected(lane, code, data);
        }
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
        if (code == 401) {
            fatal = "Watch key rejected";
            Trace.add("key_rejected", {"lane" => _lanes[lane].name});
        } else if (code == 403 && lane == OPEN) {
            fatal = "Computer is only for the owner";
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
            // an ended call answers its other routes with 404 while the events still say so
            Trace.add("route_gone", {"lane" => _lanes[lane].name});
            if (lane == LOG) {
                _logHold = true;
            } else if (lane == AUDIO) {
                abandonTurn("Call ended");
            } else {
                drop(lane);
            }
        } else if (code == 422 && lane == AUDIO) {
            abandonTurn("Lost audio, try again");
        } else if (code == 409 && lane == AUDIO) {
            conflict(data);
        } else if (CallLogic.retryable(code)) {
            failed(lane, code);
        } else {
            // the server refused this one for good: drop it, keep going
            Trace.add("refused", {"lane" => _lanes[lane].name, "code" => code});
            drop(lane);
        }
    }

    private function succeeded(lane as Number, code as Number, data as Dictionary or String or ByteArray or Null) as Void {
        if (lane == OPEN) {
            var id = data instanceof Dictionary ? data["call"] as Object? : null;
            if (id instanceof String) {
                _call = id;
                Trace.add("opened", {"call" => id});
            } else {
                failed(OPEN, 0);
            }
        } else if (lane == EVENTS) {
            handleEvents(data);
        } else if (lane == CMD) {
            if (_commands.size() > 0) {
                _commands = _commands.slice(1, null) as Array<Dictionary<String, Object>>;
            }
            _turnSentAt = System.getTimer();
        } else if (lane == AUDIO) {
            keepSent();
            _seq += 1;
            _conflicts = 0;
        } else if (lane == PIECE) {
            if (data instanceof ByteArray && _pieces.size() > 0) {
                var piece = _pieces[0];
                var n = piece["n"] as Number;
                _unplayed += data.size();
                _sizes[n] = data.size();
                playbackActive = true;
                nextPiece();
                _io.play.invoke(n, piece["ms"] as Number, data);
            } else {
                failed(PIECE, -400);
            }
        } else if (lane == PLAYED) {
            if (_playedQueue.size() > 0) {
                _playedQueue = _playedQueue.slice(1, null) as Array<Number>;
            }
        } else if (lane == LOG) {
            Trace.confirm(_logSent);
        } else if (lane == HANG) {
            _hangId = null;
        }
    }

    // The acknowledged body stays available for a resend, within the buffer's bound.
    private function keepSent() as Void {
        var body = _body;
        _body = null;
        if (body == null) {
            return;
        }
        _sentBodies.add(body);
        _sentBytes += body.size();
        while (_sentBytes > BUFFER_MAX && _sentBodies.size() > 0) {
            _sentBytes -= _sentBodies[0].size();
            _sentBodies = _sentBodies.slice(1, null) as Array<ByteArray>;
            _sentBase += 1;
        }
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
        l.failures += 1;
        if (code == Communications.BLE_QUEUE_FULL && l.crowd > 1 && l.crowd - 1 < _parallel) {
            _parallel = l.crowd - 1;
            Trace.add("parallel_limit", {"limit" => _parallel});
        }
        l.notBefore = System.getTimer() + CallLogic.backoff(l.failures);
        if (lane != LOG) {
            Trace.add("retry", {"lane" => l.name, "code" => code, "n" => l.failures, "crowd" => l.crowd});
        }
        if (lane == PIECE) {
            _pieceTries += 1;
            if (_pieceTries >= PIECE_TRIES) {
                Trace.add("piece_dropped", {"n" => _pieces.size() > 0 ? _pieces[0]["n"] : -1});
                nextPiece();
            }
        }
    }

    // A request the server will never take is not tried again.
    private function drop(lane as Number) as Void {
        if (lane == CMD && _commands.size() > 0) {
            _commands = _commands.slice(1, null) as Array<Dictionary<String, Object>>;
        } else if (lane == AUDIO) {
            _body = null;
            _seq += 1;
        } else if (lane == PLAYED && _playedQueue.size() > 0) {
            _playedQueue = _playedQueue.slice(1, null) as Array<Number>;
        } else if (lane == LOG) {
            Trace.confirm(_logSent);
        } else if (lane == PIECE) {
            nextPiece();
        } else if (lane == OPEN) {
            failed(OPEN, 0);
        }
    }

    private function conflict(data as Dictionary or String or ByteArray or Null) as Void {
        var field = data instanceof Dictionary ? data["next_seq"] as Object? : null;
        // an error answer may reach the watch without its body: then everything still held goes again
        // from the oldest chunk, which the server skips where it has it
        var next = field instanceof Number ? field : _sentBase;
        _conflicts += 1;
        if (_conflicts > MAX_CONFLICTS) {
            abandonTurn("Lost audio, try again");
            return;
        }
        var verdict = CallLogic.afterConflict(_seq, next, _sentBase);
        Trace.add("seq_conflict", {"sent" => _seq, "expected" => next, "verdict" => verdict, "body" => field instanceof Number});
        if (verdict.equals("acked")) {
            keepSent();
            _seq = next;
        } else if (verdict.equals("rewind")) {
            // the server misses chunks the watch still holds: they go again from the one it expects
            _resend = _sentBodies.slice(next - _sentBase, null) as Array<ByteArray>;
            var held = _body;
            if (held != null) {
                _resend.add(held);
            }
            _sentBodies = _sentBodies.slice(0, next - _sentBase) as Array<ByteArray>;
            _sentBytes = 0;
            for (var i = 0; i < _sentBodies.size(); i++) {
                _sentBytes += _sentBodies[i].size();
            }
            _body = null;
            _seq = next;
        } else {
            abandonTurn("Lost audio, try again");
        }
    }

    // A short message on the screen.
    private function setNotice(text as String) as Void {
        notice = text;
        _noticeUntil = System.getTimer() + NOTICE_MS;
    }

    // The server dropped the open turn (no press for too long): a new turn takes its place, with a
    // new Opus stream, and the watch keeps recording. No press goes out for the old one.
    private function restartTurn() as Void {
        Trace.add("turn_restart", {"turn" => _turn});
        if (!recording) {
            return;
        }
        recording = false;
        _restartTurn = true;
        _stopAt = System.getTimer() + STOP_WAIT_MS;
        _io.stopCapture.invoke();
    }

    private function finishRestart() as Void {
        _restartTurn = false;
        _captureOpen = false;
        discardTurn();
        // the next turn starts by itself a moment after the old capture has fully stopped
        _autoAt = System.getTimer() + AUTO_RECORD_DELAY_MS;
    }

    // The turn cannot be completed: it is dropped without a press and the next one starts by itself.
    private function abandonTurn(text as String) as Void {
        Trace.add("turn_abandoned", {"turn" => _turn});
        recording = false;
        if (_captureOpen) {
            _io.stopCapture.invoke();
        }
        _captureOpen = false;
        discardTurn();
        setNotice(text);
        _turnSent = false;
    }

    // ----- events

    private function handleEvents(data as Dictionary or String or ByteArray or Null) as Void {
        if (!(data instanceof Dictionary)) {
            failed(EVENTS, -400);
            return;
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
            Trace.add("state", {"state" => state});
            if (state.equals("generating") || state.equals("speaking")) {
                _turnSent = false;
            }
        } else if (piece instanceof Number) {
            var ms = e["ms"] as Object?;
            if (piece > _lastPiece) {
                _lastPiece = piece;
                _pieces.add({"n" => piece, "ms" => ms instanceof Number ? ms : 0} as Dictionary<String, Number>);
                Trace.add("piece", {"n" => piece, "ms" => ms, "ref" => e["ref"]});
            }
        } else if (e["clear"] != null) {
            Trace.add("clear", {"dropped" => e["dropped"]});
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
            } else if ("turn_timed_out".equals(code)) {
                restartTurn();
            }
        } else if (e["ended"] != null) {
            var reason = e["ended"];
            endedReason = reason instanceof String ? reason : "ended";
            Trace.add("ended", {"reason" => endedReason});
            resetCall();
        } else if (e["heard"] instanceof String) {
            heard = e["heard"] as String;
        }
        _autoAt = _autoAt > System.getTimer() ? _autoAt : System.getTimer() + AUTO_RECORD_DELAY_MS;
    }

    // ----- a call ends or is lost

    // The server does not know the call any more: a new one takes its place.
    private function newCallAfterLoss() as Void {
        resetCall();
        setNotice("Reconnecting");
    }

    private function resetCall() as Void {
        stopCapture();
        _io.stopPlayback.invoke();
        discardTurn();
        _call = null;
        _cursor = 0;
        _lastEvent = 0;
        _lastPiece = -1;
        _pieces = [];
        _unplayed = 0;
        _sizes = {};
        _playedQueue = [];
        _commands = [];
        _restartTurn = false;
        _logHold = false;
        _press = 0;
        _afterPress = 0;
        _turn = 0;
        _turnSent = false;
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
