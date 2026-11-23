import Toybox.Attention;
import Toybox.Audio;
import Toybox.Audio.Capture;
import Toybox.Audio.Output;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// The Computer screen, a voice prototype: Start records a clip, Start again stops it and sends it
// to the server, the answer plays. Up and Down change the playback volume, an Up hold picks the
// reply format (the `out` of the request). The screen lists the numbers of the last turn: capture
// format, bytes up, HTTP code, bytes down, round trip, free memory.
// Toybox.Audio exists on some products only; the menu offers this screen where it does
// (Home), and the checker skips the class so the other products build.
(:typecheck(false))
class ComputerView extends WatchUi.View {
    // the longest clip: at 16 kHz mono 16-bit a WAV clip is 32 kB per second, and the app has
    // about 760 kB in all
    const MAX_RECORD_S = 10;
    const SEND_TIMEOUT_MS = 40000;
    // how long after stop() the clip waits for onComplete before it goes out anyway
    const STOP_WAIT_MS = 1500;
    const VOLUME_STEP = 10;
    const START_VOLUME = 70;
    const WINDOW_BYTES = 4096;

    enum {
        READY,
        RECORDING,
        SENDING,
        PLAYING
    }

    private var _state as Number = READY;
    private var _status as String = "Start to talk";
    private var _out as String = Voice.OUTS[0];
    private var _volume as Number = START_VOLUME;
    private var _cued as Boolean = false;

    private var _clip as ByteArray = new [0]b;
    private var _capture as String = "-";
    private var _contentType as String = "audio/wav";
    private var _elapsed as Number = 0;
    private var _stopping as Boolean = false;
    private var _waiting as Boolean = false;
    private var _sentAt as Number = 0;

    private var _up as Number? = null;
    private var _code as Number? = null;
    private var _down as Number? = null;
    private var _rtt as Number? = null;

    private var _ticker as Timer.Timer = new Timer.Timer();
    private var _stopTimer as Timer.Timer = new Timer.Timer();
    private var _watchdog as Timer.Timer = new Timer.Timer();

    function initialize() {
        View.initialize();
    }

    function onShow() as Void {
        if (!_cued) {
            _cued = true;
            cue();
            try {
                Output.setVolume(_volume);
            } catch (ex) {
                fail("volume: " + ex.getErrorMessage());
            }
        }
    }

    // Leaving the screen ends whatever is going on: a late answer is ignored.
    function onHide() as Void {
        _ticker.stop();
        _stopTimer.stop();
        _watchdog.stop();
        _stopping = false;
        _waiting = false;
        if (Capture.getState() == Capture.CAPTURE_CAPTURING) {
            Capture.stop();
        }
        Output.registerStateChangeHandler(null);
        Output.stop();
        _state = READY;
        _status = "Start to talk";
        _cued = false;
    }

    // Start: the next step of the turn.
    function toggle() as Void {
        if (_state == RECORDING) {
            stopRecording();
        } else if (_state == READY || _state == PLAYING) {
            startRecording();
        }
    }

    function louder() as Void {
        setVolume(_volume + VOLUME_STEP);
    }

    function quieter() as Void {
        setVolume(_volume - VOLUME_STEP);
    }

    // The Up hold: the next reply format, between turns.
    function cycleOut() as Void {
        if (_state == READY) {
            _out = Voice.nextOut(_out);
            WatchUi.requestUpdate();
        }
    }

    // A short signal that the connection is up and the watch listens.
    private function cue() as Void {
        if (Attention has :playTone) {
            Attention.playTone(Attention.TONE_START);
        }
        if (Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(60, 150)]);
        }
    }

    private function setVolume(volume as Number) as Void {
        _volume = volume < 0 ? 0 : (volume > 100 ? 100 : volume);
        try {
            Output.setVolume(_volume);
        } catch (ex) {
            fail("volume: " + ex.getErrorMessage());
            return;
        }
        WatchUi.requestUpdate();
    }

    private function startRecording() as Void {
        Output.stop();
        Output.registerStateChangeHandler(null);
        var opus = {
            :containerFormat => Audio.CONTAINER_OGG,
            :codec => Audio.CODEC_OPUS,
            :frequency => Audio.FREQ_16_KHZ,
            :channels => Audio.CHANNEL_MONO
        };
        var wav = {
            :containerFormat => Audio.CONTAINER_WAV,
            :codec => Audio.CODEC_LPCM,
            :frequency => Audio.FREQ_16_KHZ,
            :channels => Audio.CHANNEL_MONO
        };
        var format = opus;
        if (Capture.isFormatSupported(opus)) {
            _capture = "ogg opus 16k";
            _contentType = "audio/ogg";
        } else if (Capture.isFormatSupported(wav)) {
            format = wav;
            _capture = "wav pcm 16k";
            _contentType = "audio/wav";
        } else {
            _capture = "none";
            fail("no capture format");
            return;
        }
        _clip = new [0]b;
        _up = null;
        _code = null;
        _down = null;
        _rtt = null;
        try {
            Capture.initializeAudioCapture(self, {
                :format => format,
                :windowSize => WINDOW_BYTES,
                :windowFilledBehavior => Capture.WINDOW_FILLED_CONTINUE,
                :filters => []
            });
            Capture.start();
        } catch (ex) {
            fail("capture: " + ex.getErrorMessage());
            return;
        }
        _elapsed = 0;
        _state = RECORDING;
        _status = "Recording 0 s";
        _ticker.start(method(:onTick), 1000, true);
        WatchUi.requestUpdate();
    }

    function onTick() as Void {
        _elapsed += 1;
        _status = "Recording " + _elapsed + " s";
        if (_elapsed >= MAX_RECORD_S) {
            stopRecording();
        }
        WatchUi.requestUpdate();
    }

    private function stopRecording() as Void {
        _ticker.stop();
        _stopping = true;
        _status = "Stopping";
        Capture.stop();
        // normally onComplete sends the clip; this covers a stop that never reports back
        _stopTimer.start(method(:finishCapture), STOP_WAIT_MS, false);
        WatchUi.requestUpdate();
    }

    // Capture callbacks: the encoded chunks arrive in order and make up the clip.
    function onData(audioData as ByteArray) as Void {
        _clip.addAll(audioData);
    }

    function onComplete() as Void {
        finishCapture();
    }

    function onError(error as Capture.Error) as Void {
        if (_state == RECORDING) {
            _ticker.stop();
            _stopTimer.stop();
            _stopping = false;
            fail("capture error " + error);
        }
    }

    function finishCapture() as Void {
        if (!_stopping) {
            return;
        }
        _stopping = false;
        _stopTimer.stop();
        send();
    }

    private function send() as Void {
        _up = _clip.size();
        if (_clip.size() == 0) {
            fail("no audio captured");
        } else if (!ServerConfig.isSet()) {
            fail("not set up");
        } else if (!System.getDeviceSettings().phoneConnected) {
            fail("no phone");
        } else {
            var headers = Wire.authorization();
            headers["Content-Type"] = _contentType;
            var options = {
                :method => Communications.HTTP_REQUEST_METHOD_POST,
                :headers => headers,
                :body => _clip,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_OCTET_STREAM
            };
            _state = SENDING;
            _status = "Sending " + _up + " B";
            _waiting = true;
            _sentAt = System.getTimer();
            _watchdog.start(method(:onTimeout), SEND_TIMEOUT_MS, false);
            try {
                Communications.makeWebRequest(Voice.turnUrl(ServerConfig.url(), _out), null, options, method(:onReply));
            } catch (ex) {
                _waiting = false;
                _watchdog.stop();
                fail("send: " + ex.getErrorMessage());
                return;
            }
        }
        WatchUi.requestUpdate();
    }

    function onTimeout() as Void {
        if (_waiting) {
            _waiting = false;
            _rtt = System.getTimer() - _sentAt;
            fail("no answer");
        }
    }

    function onReply(responseCode as Number, data as ByteArray or Dictionary or String or Null) as Void {
        if (!_waiting) {
            return;
        }
        _waiting = false;
        _watchdog.stop();
        _rtt = System.getTimer() - _sentAt;
        _code = responseCode;
        System.println("Computer: answer " + responseCode + " in " + _rtt + " ms");
        _clip = new [0]b;
        if (responseCode == 200 && data instanceof ByteArray) {
            _down = data.size();
            play(data);
        } else {
            fail(Voice.codeText(responseCode));
        }
    }

    private function play(reply as ByteArray) as Void {
        try {
            var builder = new Output.DynamicAudioSourceBuilder({:format => replyFormat()});
            builder.append(reply);
            Output.registerStateChangeHandler(method(:onPlayState));
            _state = PLAYING;
            _status = "Playing";
            Output.play(builder.complete(), 0);
        } catch (ex) {
            fail("play: " + ex.getErrorMessage());
            return;
        }
        WatchUi.requestUpdate();
    }

    // The format the server's answer to the chosen `out` is in; the Opus answer is left for the
    // player to detect.
    private function replyFormat() as Audio.AudioFormat {
        if (_out.equals("opus")) {
            return null as Audio.AudioFormat;
        }
        return {
            :containerFormat => Audio.CONTAINER_WAV,
            :codec => Audio.CODEC_LPCM,
            :frequency => _out.equals("wav8") ? Audio.FREQ_8_KHZ : Audio.FREQ_16_KHZ,
            :channels => Audio.CHANNEL_MONO
        };
    }

    function onPlayState(state as Output.PlaybackState) as Void {
        System.println("Computer: playback state " + state);
        if (_state != PLAYING) {
            return;
        }
        if (state == Output.PLAYBACK_STOPPED) {
            _state = READY;
            _status = "Start to talk";
        } else if (state == Output.PLAYBACK_ERROR) {
            fail("playback error " + Output.getError());
        }
        WatchUi.requestUpdate();
    }

    private function fail(text as String) as Void {
        _state = READY;
        _status = text;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        Draw.title(dc, "Computer");
        var x = dc.getWidth() / 2;
        var h = dc.getHeight();
        var color = _state == RECORDING ? Graphics.COLOR_RED : (_state == READY ? Graphics.COLOR_WHITE : Graphics.COLOR_GREEN);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, h * 28 / 100, Graphics.FONT_SMALL, _status, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var lines = [
            "cap " + _capture,
            "up " + number(_up) + " B  " + codeLabel(),
            "down " + number(_down) + " B",
            "rtt " + number(_rtt) + " ms",
            "out " + _out + "  vol " + _volume,
            "free " + (System.getSystemStats().freeMemory / 1024) + " kB"
        ];
        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(x, h * (40 + i * 7) / 100, Graphics.FONT_XTINY, lines[i], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        Draw.hint(dc, _state == RECORDING ? "Start: send" : "Start: talk");
    }

    private function number(value as Number?) as String {
        return value == null ? "-" : value.toString();
    }

    private function codeLabel() as String {
        var code = _code;
        return code == null ? "-" : code + " " + Voice.codeText(code);
    }
}

class ComputerDelegate extends WatchUi.BehaviorDelegate {
    private var _view as ComputerView;

    function initialize(view as ComputerView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.toggle();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.louder();
        return true;
    }

    function onNextPage() as Boolean {
        _view.quieter();
        return true;
    }

    // The Up hold.
    function onMenu() as Boolean {
        _view.cycleOut();
        return true;
    }
}
