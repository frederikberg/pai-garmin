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

    function initialize(client as CallClient) {
        _client = client;
    }

    function start() as Boolean {
        var format = {
            :containerFormat => Audio.CONTAINER_OGG,
            :codec => Audio.CODEC_OPUS,
            :frequency => Audio.FREQ_16_KHZ,
            :channels => Audio.CHANNEL_MONO
        };
        if (!Capture.isFormatSupported(format)) {
            return false;
        }
        try {
            Capture.initializeAudioCapture(self, {
                :format => format,
                :windowSize => WINDOW_BYTES,
                :windowFilledBehavior => Capture.WINDOW_FILLED_CONTINUE,
                :filters => []
            });
            Capture.start();
        } catch (ex) {
            Trace.add("capture_init", {"error" => ex.getErrorMessage()});
            return false;
        }
        return true;
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

// The pieces of an answer, fed to one streaming source as raw 16 kHz mono PCM behind a WAV header,
// so they play without gaps; position tracking reports each piece once it has played through.
(:typecheck(false))
class PcmSource extends Output.StreamingAudioSource {
    private var _queue as Array<ByteArray> = [];
    private var _offset as Number = 0;
    private var _sealed as Boolean = false;

    function initialize(buffer as Number) {
        Output.StreamingAudioSource.initialize({
            :format => {
                :containerFormat => Audio.CONTAINER_WAV,
                :codec => Audio.CODEC_LPCM,
                :frequency => Audio.FREQ_16_KHZ,
                :channels => Audio.CHANNEL_MONO
            },
            :bufferSize => buffer
        });
        _queue.add(CallLogic.wavHeader(CallLogic.PCM_RATE));
    }

    function push(data as ByteArray) as Void {
        _queue.add(data);
        fill(getBufferSize());
    }

    // No more data for this stream: the player plays what it holds and stops.
    function seal() as Void {
        _sealed = true;
        if (_queue.size() == 0) {
            end();
        }
    }

    function onReadyForData(freeSpace as Number) as Void {
        fill(freeSpace);
    }

    private function fill(free as Number) as Void {
        var room = free;
        while (_queue.size() > 0 && room > 0) {
            var head = _queue[0];
            var left = head.size() - _offset;
            var count = left < room ? left : room;
            var taken = append(head.slice(_offset, _offset + count));
            _offset += taken;
            room -= taken;
            if (_offset >= head.size()) {
                _queue = _queue.slice(1, null) as Array<ByteArray>;
                _offset = 0;
            } else if (taken < count) {
                break;
            }
        }
        if (_sealed && _queue.size() == 0) {
            end();
        }
    }

    function onError(error as Output.Error) as Void {
        Trace.add("source_error", {"error" => error});
    }
}

(:typecheck(false))
class Speaker {
    const BUFFER_BYTES = 16384;
    const PERIOD_MS = 200;
    // the position counts from the header; a piece is done when its end is within this of it
    const SLACK_MS = 40;
    const SEAL_AFTER_MS = 600;

    private var _client as CallClient;
    private var _source as PcmSource? = null;
    private var _ends as Array<Array<Number>> = [];
    private var _fedMs as Number = 0;
    private var _quietSince as Number = 0;
    private var _volume as Number;

    function initialize(client as CallClient, volume as Number) {
        _client = client;
        _volume = volume;
        try {
            Output.setVolume(volume);
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
        var source = _source;
        try {
            if (source == null) {
                source = new PcmSource(BUFFER_BYTES);
                _source = source;
                _ends = [];
                _fedMs = 0;
                Output.registerStateChangeHandler(method(:onState));
                Output.registerPeriodicUpdateHandler(PERIOD_MS, method(:onPosition));
                source.push(pcm);
                Output.play(source, 0);
            } else {
                source.push(pcm);
            }
        } catch (ex) {
            Trace.add("play_error", {"error" => ex.getErrorMessage()});
            _client.playbackFailed(0);
            return;
        }
        var length = ms > 0 ? ms : CallLogic.pcmMs(pcm.size(), CallLogic.PCM_RATE);
        _fedMs += length;
        _ends.add([n, _fedMs]);
        _quietSince = 0;
    }

    // Stops at once; the pieces that played through are reported first.
    function stop() as Void {
        if (_source == null) {
            return;
        }
        reportDone(position());
        release();
        try {
            Output.stop();
        } catch (ex) {
            Trace.add("stop_error", {"error" => ex.getErrorMessage()});
        }
        _client.playbackIdle();
    }

    function onPosition(position as Number) as Void {
        reportDone(position);
        if (_ends.size() == 0 && !_client.moreToPlay()) {
            var now = System.getTimer();
            if (_quietSince == 0) {
                _quietSince = now;
            } else if (now - _quietSince >= SEAL_AFTER_MS) {
                var source = _source;
                if (source != null) {
                    source.seal();
                }
            }
        } else {
            _quietSince = 0;
        }
    }

    function onState(state as Output.PlaybackState) as Void {
        Trace.add("play_state", {"state" => state});
        if (state == Output.PLAYBACK_ERROR) {
            _client.playbackFailed(state);
            release();
        }
        if (state == Output.PLAYBACK_STOPPED && _source != null) {
            reportDone(_fedMs + 1000);
            release();
            _client.playbackIdle();
        }
    }

    private function position() as Number {
        try {
            return Output.getPosition();
        } catch (ex) {
            return 0;
        }
    }

    private function reportDone(position as Number) as Void {
        while (_ends.size() > 0 && _ends[0][1] <= position + SLACK_MS) {
            _client.piecePlayed(_ends[0][0]);
            _ends = _ends.slice(1, null) as Array<Array<Number>>;
        }
    }

    private function release() as Void {
        _source = null;
        _ends = [];
        Output.registerStateChangeHandler(null);
        Output.registerPeriodicUpdateHandler(PERIOD_MS, null);
    }
}
