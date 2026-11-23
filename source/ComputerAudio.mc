import Toybox.Audio;
import Toybox.Audio.Capture;
import Toybox.Audio.Output;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

// The microphone: one Ogg Opus 16 kHz mono stream per turn, delivered in small windows so a turn
// leaves the watch while it is spoken.
// Toybox.Audio exists on some products only; the classes of this file are left out of the strict
// check so the others build (the menu offers the screen where Audio exists).
(:typecheck(false))
class Recorder {
    const WINDOW_BYTES = 1024;
    private var _client as CallClient;
    private var _logged as Boolean = false;

    function initialize(client as CallClient) {
        _client = client;
    }

    // 0 when recording began, 1 when the watch cannot capture Ogg Opus, 2 when starting failed.
    function start() as Number {
        var format = {
            :containerFormat => Audio.CONTAINER_OGG,
            :codec => Audio.CODEC_OPUS,
            :frequency => Audio.FREQ_16_KHZ,
            :channels => Audio.CHANNEL_MONO
        };
        if (!Capture.isFormatSupported(format)) {
            Trace.add("capture_format", {"opus" => false});
            return 1;
        }
        // noise reduction and echo cancellation, where the watch has them: the speaker's tail goes
        // into the microphone when recording restarts after an answer
        var filters = [];
        if (Capture.getSupportedFilters().indexOf(Capture.FILTER_NREC) >= 0) {
            filters = [Capture.FILTER_NREC];
        }
        try {
            var settings = Capture.initializeAudioCapture(self, {
                :format => format,
                :windowSize => WINDOW_BYTES,
                :windowFilledBehavior => Capture.WINDOW_FILLED_CONTINUE,
                :filters => filters
            });
            Capture.start();
            if (!_logged) {
                _logged = true;
                Trace.add("capture_start", {"window" => settings[:windowSize], "filters" => filters});
            }
        } catch (ex) {
            Trace.add("capture_init", {"error" => ex.getErrorMessage()});
            return 2;
        }
        return 0;
    }

    function stop() as Void {
        if (Capture.getState() == Capture.CAPTURE_CAPTURING) {
            Capture.stop();
        }
    }

    function onData(audioData as ByteArray) as Void {
        _client.chunk(audioData);
    }

    function onComplete() as Void {
        _client.captureEnded();
    }

    function onError(error as Capture.Error) as Void {
        _client.captureFailed(error);
    }
}

// The pieces of an answer, each a complete Ogg Opus file (24 kHz mono), played one after the other,
// every one through its own audio source. A piece is over when the player says it stopped or, if it
// never does, a little after its length; either way the next one starts and the client hears that it
// played. The watch's own cues play here too.
(:typecheck(false))
class Speaker {
    const SLACK_MS = 800;
    // a stop this soon after a start is the previous piece's, not this one's
    const STALE_MS = 150;

    private var _client as CallClient;
    private var _volume as Number;
    private var _queue as Array<Array<Object>> = [];
    private var _current as Number = -1;
    private var _startedAt as Number = 0;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _lastEnd as Number = 0;
    private var _starved as Boolean = false;
    private var _cues as Dictionary<Number, ByteArray> = {};

    function initialize(client as CallClient, volume as Number) {
        _client = client;
        _volume = volume;
        try {
            Output.setVolume(volume);
            Output.registerStateChangeHandler(method(:onState));
        } catch (ex) {
            Trace.add("volume_error", {"error" => ex.getErrorMessage()});
        }
    }

    function volume() as Number {
        return _volume;
    }

    function setVolume(volume as Number) as Void {
        _volume = volume < 0 ? 0 : (volume > 100 ? 100 : volume);
        try {
            Output.setVolume(_volume);
        } catch (ex) {
            Trace.add("volume_error", {"error" => ex.getErrorMessage()});
        }
    }

    function play(n as Number, ms as Number, pcm as ByteArray) as Void {
        _queue.add([n, ms, pcm]);
        if (_current < 0) {
            startNext();
        }
    }

    // Stops at once: what is playing and what waits is dropped, and not reported as played.
    function stop() as Void {
        _timer.stop();
        _queue = [];
        _lastEnd = 0;
        _starved = false;
        if (_current >= 0) {
            _current = -1;
            try {
                Output.stop();
            } catch (ex) {
                Trace.add("stop_error", {"error" => ex.getErrorMessage()});
            }
        }
        _client.playbackIdle();
    }

    // One of the watch's own cues, at once. The error cue also silences whatever is playing.
    function cue(kind as Number) as Void {
        if (_current >= 0 && kind != CallLogic.CUE_ERROR) {
            return;
        }
        _timer.stop();
        _queue = [];
        _current = -1;
        var wav = _cues[kind];
        if (wav == null) {
            wav = CallLogic.cueWav(kind);
            _cues[kind] = wav;
        }
        try {
            var builder = new Output.DynamicAudioSourceBuilder({:format => {
                :containerFormat => Audio.CONTAINER_WAV,
                :codec => Audio.CODEC_LPCM,
                :frequency => Audio.FREQ_8_KHZ,
                :channels => Audio.CHANNEL_MONO
            }});
            builder.append(wav);
            Output.play(builder.complete(), 0);
            Trace.add("cue", {"kind" => kind, "vol" => _volume});
        } catch (ex) {
            Trace.add("cue_error", {"kind" => kind, "error" => ex.getErrorMessage()});
        }
    }

    private function startNext() as Void {
        if (_queue.size() == 0) {
            finishAnswer();
            return;
        }
        var item = _queue[0];
        _queue = _queue.slice(1, null) as Array<Array<Object>>;
        var n = item[0] as Number;
        var ms = item[1] as Number;
        var data = item[2] as ByteArray;
        try {
            var builder = new Output.DynamicAudioSourceBuilder({:format => {
                :containerFormat => Audio.CONTAINER_OGG,
                :codec => Audio.CODEC_OPUS,
                :frequency => Audio.FREQ_24_KHZ,
                :channels => Audio.CHANNEL_MONO
            }});
            builder.append(data);
            Output.play(builder.complete(), 0);
        } catch (ex) {
            Trace.add("play_error", {"n" => n, "error" => ex.getErrorMessage()});
            fail(n);
            return;
        }
        _current = n;
        _startedAt = System.getTimer();
        _timer.start(method(:onDeadline), ms + SLACK_MS, false);
        // the gap before a piece, and whether the piece before it was left waiting for this one
        Trace.add("piece_start", {"n" => n, "bytes" => data.size(), "ms" => ms,
            "gap_ms" => _lastEnd > 0 ? _startedAt - _lastEnd : 0, "starved" => _starved, "vol" => _volume});
        _lastEnd = 0;
        _starved = false;
    }

    // The last piece is over: the player is stopped in case it still holds the source.
    private function finishAnswer() as Void {
        try {
            Output.stop();
        } catch (ex) {
            Trace.add("stop_error", {"error" => ex.getErrorMessage()});
        }
        _client.playbackIdle();
    }

    private function pieceDone(how as String) as Void {
        _timer.stop();
        var n = _current;
        _current = -1;
        var now = System.getTimer();
        if (n >= 0) {
            Trace.add("piece_end", {"n" => n, "how" => how, "played_ms" => now - _startedAt});
            _client.piecePlayed(n);
        }
        _lastEnd = now;
        // nothing queued while more is on its way: the next piece is late
        _starved = _queue.size() == 0 && _client.moreToPlay();
        startNext();
    }

    // The player never said the piece stopped.
    function onDeadline() as Void {
        if (_current >= 0) {
            pieceDone("timer");
        }
    }

    function onState(state as Output.PlaybackState) as Void {
        Trace.add("play_state", {"state" => state, "n" => _current});
        if (_current < 0) {
            return;
        }
        if (state == Output.PLAYBACK_ERROR) {
            fail(_current);
        } else if (state == Output.PLAYBACK_STOPPED && System.getTimer() - _startedAt >= STALE_MS) {
            pieceDone("stopped");
        }
    }

    // A piece that cannot play counts as played, as does everything behind it, so the server's picture
    // keeps its rhythm.
    private function fail(n as Number) as Void {
        _timer.stop();
        _current = -1;
        _client.piecePlayed(n);
        for (var i = 0; i < _queue.size(); i++) {
            _client.piecePlayed(_queue[i][0] as Number);
        }
        _queue = [];
        _client.playbackFailed(0);
    }
}
