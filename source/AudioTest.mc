import Toybox.Audio;
import Toybox.Audio.Output;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// A test screen for choosing the answer playback format by ear: the server lists test clips in a few
// formats, each is downloaded and played, and the screen shows what the link and the player did.
// Toybox.Audio exists on some products only; the menu offers this screen where it does (Home), and
// the checker skips the classes so the other products build.

// The list of variants, fetched when the screen opens; selecting one opens its player.
(:typecheck(false))
class AudioTestListView extends WatchUi.View {
    private var _text as String = "Loading...";
    private var _token as Number = 0;
    private var _timer as Timer.Timer = new Timer.Timer();

    function initialize() {
        View.initialize();
    }

    function onShow() as Void {
        if (_token == 0) {
            fetch();
        }
    }

    function onHide() as Void {
        _timer.stop();
    }

    private function fetch() as Void {
        _token += 1;
        _text = "Loading...";
        if (!ServerConfig.isSet()) {
            _text = "Set the server in Garmin Connect";
            return;
        }
        var token = _token;
        Communications.makeWebRequest(ServerConfig.url() + Api.VOICE_TEST, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => Wire.authorization(),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, new TestAnswer(self, token).method(:onResponse));
        _timer.start(method(:onTimeout), 20000, false);
    }

    function onTimeout() as Void {
        _token += 1;
        _text = "No answer";
        WatchUi.requestUpdate();
    }

    function onList(token as Number, code as Number, data as Object?) as Void {
        if (token != _token) {
            return;
        }
        _timer.stop();
        var list = data instanceof Dictionary ? data["variants"] as Object? : null;
        if (code != 200 || !(list instanceof Array) || list.size() == 0) {
            _text = "Error " + code;
            WatchUi.requestUpdate();
            return;
        }
        var menu = new WatchUi.Menu2({:title => "Audio test"});
        var variants = [] as Array<Dictionary>;
        for (var i = 0; i < list.size(); i++) {
            var v = list[i] as Dictionary;
            variants.add(v);
            menu.addItem(new WatchUi.MenuItem(v["label"] as String, null, i, null));
        }
        WatchUi.switchToView(menu, new AudioTestMenuDelegate(variants), WatchUi.SLIDE_IMMEDIATE);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        Draw.title(dc, "Audio test");
        Draw.paragraph(dc, _text, 35, 75);
    }
}

(:typecheck(false))
class AudioTestListDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }
}

(:typecheck(false))
class AudioTestMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _variants as Array<Dictionary>;

    function initialize(variants as Array<Dictionary>) {
        Menu2InputDelegate.initialize();
        _variants = variants;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var view = new AudioTestPlayView(_variants[item.getId() as Number]);
        WatchUi.pushView(view, new AudioTestPlayDelegate(view), WatchUi.SLIDE_LEFT);
    }
}

// The callback of one request: it remembers which request it answers.
(:typecheck(false))
class TestAnswer {
    private var _view as Object;
    private var _token as Number;
    private var _part as Number;

    function initialize(view as Object, token as Number) {
        _view = view;
        _token = token;
        _part = -1;
    }

    function forPart(part as Number) as TestAnswer {
        _part = part;
        return self;
    }

    function onResponse(code as Number, data as Object?) as Void {
        if (_part < 0) {
            _view.onList(_token, code, data);
        } else {
            _view.onPart(_token, _part, code, data);
        }
    }
}

// Downloads the parts of one variant, one request at a time, and plays them in order, each through
// its own source; the next part is fetched while one plays.
(:typecheck(false))
class AudioTestPlayView extends WatchUi.View {
    const START_VOLUME = 70;
    const VOLUME_STEP = 10;
    const STALE_MS = 150;

    private var _variant as Dictionary;
    private var _parts as Number;
    private var _data as Array<ByteArray?> = [];
    private var _dlMs as Array<Number> = [];
    private var _bytes as Array<Number> = [];
    private var _lines as Array<String> = [];
    private var _next as Number = 0;
    private var _playing as Number = -1;
    private var _startedAt as Number = 0;
    private var _stoppedAt as Number = 0;
    private var _requestAt as Number = 0;
    private var _token as Number = 0;
    private var _volume as Number = START_VOLUME;
    private var _status as String = "Downloading";
    private var _deviceVolume as String = "n/a";
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _clock as Timer.Timer = new Timer.Timer();

    function initialize(variant as Dictionary) {
        View.initialize();
        _variant = variant;
        var parts = variant["parts"] as Object?;
        _parts = parts instanceof Number && parts > 0 ? parts : 1;
        for (var i = 0; i < _parts; i++) {
            _data.add(null);
            _dlMs.add(-1);
            _bytes.add(0);
        }
    }

    function onShow() as Void {
        if (_token == 0) {
            try {
                Output.setVolume(_volume);
                Output.registerStateChangeHandler(method(:onState));
            } catch (ex) {
                note("volume error");
            }
            _clock.start(method(:onClock), 1000, true);
            fetchNext();
        }
    }

    function onHide() as Void {
        _token += 1000;
        _timer.stop();
        _clock.stop();
        try {
            Output.registerStateChangeHandler(null);
            Output.stop();
        } catch (ex) {
        }
    }

    function louder() as Void {
        setVolume(_volume + VOLUME_STEP);
    }

    function quieter() as Void {
        setVolume(_volume - VOLUME_STEP);
    }

    private function setVolume(volume as Number) as Void {
        _volume = volume < 0 ? 0 : (volume > 100 ? 100 : volume);
        try {
            Output.setVolume(_volume);
        } catch (ex) {
            note("volume error");
        }
        WatchUi.requestUpdate();
    }

    private function note(text as String) as Void {
        _lines.add(text);
        System.println("audiotest " + _variant["id"] + ": " + text);
        WatchUi.requestUpdate();
    }

    private function fetchNext() as Void {
        if (_next >= _parts) {
            return;
        }
        var part = _next;
        _token += 1;
        _requestAt = System.getTimer();
        Communications.makeWebRequest(ServerConfig.url() + Api.VOICE_TEST + "/" + _variant["id"] + "/" + part, null, {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => Wire.authorization(),
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_OCTET_STREAM
        }, new TestAnswer(self, _token).forPart(part).method(:onResponse));
    }

    function onPart(token as Number, part as Number, code as Number, data as Object?) as Void {
        if (token != _token) {
            return;
        }
        var ms = System.getTimer() - _requestAt;
        if (code != 200 || !(data instanceof ByteArray)) {
            _status = "Error " + code;
            note("p" + part + " error " + code + ", " + ms + " ms");
            return;
        }
        _data[part] = data;
        _dlMs[part] = ms;
        _bytes[part] = data.size();
        note("p" + part + " " + data.size() + " B, " + ms + " ms");
        _next = part + 1;
        if (_playing < 0 && part == 0) {
            play(0);
        } else if (_playing < 0 && _stoppedAt > 0) {
            // the player was waiting for this part
            play(part);
        }
        fetchNext();
    }

    private function play(part as Number) as Void {
        var data = _data[part] as ByteArray;
        var ogg = "ogg".equals(_variant["fmt"]);
        var rate = _variant["rate"] as Object?;
        var format = {
            :containerFormat => ogg ? Audio.CONTAINER_OGG : Audio.CONTAINER_WAV,
            :codec => ogg ? Audio.CODEC_OPUS : Audio.CODEC_LPCM,
            :frequency => rate == 24000 ? Audio.FREQ_24_KHZ : Audio.FREQ_16_KHZ,
            :channels => Audio.CHANNEL_MONO
        };
        var now = System.getTimer();
        var gap = _stoppedAt > 0 ? now - _stoppedAt : 0;
        try {
            var builder = new Output.DynamicAudioSourceBuilder({:format => format});
            builder.append(data);
            Output.play(builder.complete(), 0);
        } catch (ex) {
            _status = "Play error";
            note("p" + part + " play error");
            return;
        }
        _data[part] = null;
        _playing = part;
        _startedAt = now;
        _status = "Playing " + (part + 1) + "/" + _parts;
        var volume = "n/a";
        if (Output has :getVolume) {
            volume = Output.getVolume().toString();
        }
        _deviceVolume = volume;
        note("p" + part + " plays" + (part > 0 ? ", gap " + gap + " ms" : "") + ", vol " + volume);
        // the player says when it stops; this covers a stop that never comes
        _timer.start(method(:onDeadline), 12000 / _parts + 3000, false);
    }

    function onState(state as Output.PlaybackState) as Void {
        if (_playing < 0) {
            return;
        }
        if (state == Output.PLAYBACK_ERROR) {
            note("p" + _playing + " playback error");
            _status = "Playback error";
        } else if (state == Output.PLAYBACK_STOPPED && System.getTimer() - _startedAt >= STALE_MS) {
            partOver("stopped");
        }
    }

    function onDeadline() as Void {
        if (_playing >= 0) {
            partOver("timer");
        }
    }

    private function partOver(how as String) as Void {
        _timer.stop();
        var part = _playing;
        _playing = -1;
        _stoppedAt = System.getTimer();
        note("p" + part + " ends " + how + ", " + (_stoppedAt - _startedAt) + " ms");
        if (part + 1 < _parts) {
            if (_data[part + 1] != null) {
                play(part + 1);
            } else {
                note("p" + (part + 1) + " still downloading");
                _status = "Waiting for part " + (part + 2);
            }
        } else {
            _status = "Done";
        }
        WatchUi.requestUpdate();
    }

    // The download times and the size, which scroll out of the log lines.
    private function summary() as String {
        var times = "";
        var total = 0;
        for (var i = 0; i < _parts; i++) {
            times += (i > 0 ? "/" : "") + (_dlMs[i] < 0 ? "-" : _dlMs[i].toString());
            total += _bytes[i];
        }
        return times + " ms, " + total + " B";
    }

    function onClock() as Void {
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        Draw.title(dc, _variant["label"] as String);
        var x = dc.getWidth() / 2;
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, h * 27 / 100, Graphics.FONT_SMALL, _status, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, h * 37 / 100, Graphics.FONT_XTINY, summary(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var first = _lines.size() > 4 ? _lines.size() - 4 : 0;
        for (var i = first; i < _lines.size(); i++) {
            dc.drawText(x, h * (45 + (i - first) * 8) / 100, Graphics.FONT_XTINY, _lines[i], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        Draw.hint(dc, "vol " + _volume + " (dev " + _deviceVolume + ")");
    }
}

(:typecheck(false))
class AudioTestPlayDelegate extends WatchUi.BehaviorDelegate {
    private var _view as AudioTestPlayView;

    function initialize(view as AudioTestPlayView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onPreviousPage() as Boolean {
        _view.louder();
        return true;
    }

    function onNextPage() as Boolean {
        _view.quieter();
        return true;
    }

    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        return true;
    }
}
