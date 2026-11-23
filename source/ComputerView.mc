import Toybox.Application.Storage;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// The Computer screen: opening it starts a call. The watch records each turn by itself, Start sends
// it, or cuts the answer and records again; Up and Down are the volume, Back hangs up. What the
// call is doing, the recording time, the link's health and the transcript lines the server sends are
// on screen.
// Toybox.Audio exists on some products only; the menu offers this screen where it does (Home), and
// the checker skips the class so the other products build.
(:typecheck(false))
class ComputerView extends WatchUi.View {
    const START_VOLUME = 70;
    const VOLUME_STEP = 10;
    // where the volume is kept between openings
    const VOLUME_KEY = "volume";

    private var _client as CallClient;
    private var _speaker as Speaker;
    private var _recorder as Recorder;
    private var _keepCall as Boolean = false;
    private var _volume as Number = START_VOLUME;
    // the screen has been left some way other than the end of the hang-up
    private var _left as Boolean = false;

    function initialize() {
        View.initialize();
        var saved = Storage.getValue(VOLUME_KEY);
        if (saved instanceof Number && saved >= 0 && saved <= 100) {
            _volume = saved;
        }
        _client = build();
        _recorder = new Recorder(_client);
        _client.start();
        // after the start, so that listening begins without waiting for the cues to be built
        _speaker = new Speaker(_client, _volume);
    }

    private function build() as CallClient {
        var io = new CallIo(method(:startCapture), method(:stopCapture), method(:play), method(:stopPlayback), method(:changed),
            method(:cue), method(:leave), method(:busy));
        return new CallClient(io, new CallEnv());
    }

    // Back from something that covered the screen (the hang-up had ended the call): a new call.
    function onShow() as Void {
        _keepCall = false;
        if (_client.closed()) {
            _volume = _speaker.volume();
            _left = false;
            _client = build();
            _recorder = new Recorder(_client);
            _client.start();
            _speaker = new Speaker(_client, _volume);
        }
        WatchUi.requestUpdate();
    }

    // Leaving the screen ends the call, except for the menu opened on top of it.
    function onHide() as Void {
        if (!_keepCall) {
            _left = true;
            _client.hangUp();
        }
    }

    function keepCallWhileMenu() as Void {
        _keepCall = true;
    }

    function hangUp() as Void {
        _client.hangUp();
    }

    // A short buzz tells the press was taken; the server answers it a moment later.
    function press() as Void {
        _client.press();
    }

    function reconnect() as Void {
        _client.reconnect();
    }

    function louder() as Void {
        setVolume(_speaker.volume() + VOLUME_STEP);
    }

    function quieter() as Void {
        setVolume(_speaker.volume() - VOLUME_STEP);
    }

    private function setVolume(volume as Number) as Void {
        _speaker.setVolume(volume);
        Storage.setValue(VOLUME_KEY, _speaker.volume());
        WatchUi.requestUpdate();
    }

    // Back: the hang-up goes to the server first, then the screen leaves; a second Back leaves at once.
    function back() as Boolean {
        if (_client.closed()) {
            _left = true;
            return false;
        }
        _client.hangUp();
        WatchUi.requestUpdate();
        return true;
    }

    // The hang-up is over.
    // Only if the screen is still the one on top: a second Back or an alarm may have left it already.
    function leave() as Void {
        if (!_left) {
            _left = true;
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }

    // A cue; the one for a sent turn comes with a buzz, after the microphone has stopped.
    function cue(kind as Number) as Boolean {
        if (kind == CallLogic.CUE_SENT && Attention has :vibrate) {
            Attention.vibrate([new Attention.VibeProfile(70, 80)]);
        }
        return _speaker.cue(kind);
    }

    function busy() as Boolean {
        return _speaker.busy();
    }

    // the client's audio side
    function startCapture() as Number {
        return _recorder.start();
    }

    function stopCapture() as Void {
        _recorder.stop();
    }

    function play(n as Number, ms as Number, pcm as ByteArray) as Void {
        _speaker.play(n, ms, pcm);
    }

    function stopPlayback() as Void {
        _speaker.stop();
    }

    function changed() as Void {
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        var w = dc.getWidth();
        var h = dc.getHeight();
        var fatal = _client.fatal;
        var ended = _client.endedReason;
        var headline;
        var body = "";
        var color = Graphics.COLOR_WHITE;
        var hint = "";
        if (_client.closed()) {
            headline = "Hanging up";
            color = Graphics.COLOR_LT_GRAY;
        } else if (fatal != null) {
            headline = "Unavailable";
            body = fatal;
        } else if (ended != null) {
            headline = "Call ended";
            body = ended;
            hint = "Start: new call";
        } else if (_client.stalled != null && !_client.recording) {
            headline = "Not listening";
            color = Graphics.COLOR_ORANGE;
            body = _client.stalled as String;
            hint = "Start: try again";
        } else if (_client.recording) {
            headline = "Listening " + elapsed();
            color = Graphics.COLOR_RED;
            hint = "Start: send";
            ring(dc, w, h);
        } else if (!_client.hasCall()) {
            headline = "Connecting";
            color = Graphics.COLOR_LT_GRAY;
        } else if (_client.sending()) {
            headline = "Sending";
            color = Graphics.COLOR_YELLOW;
        } else if (_client.engine.equals("speaking") || _client.playbackActive) {
            headline = "Speaking";
            color = Graphics.COLOR_GREEN;
            hint = "Start: interrupt";
        } else if (_client.engine.equals("generating")) {
            headline = "Thinking";
            color = Graphics.COLOR_YELLOW;
            body = _client.heard;
            hint = "Start: interrupt";
        } else {
            headline = "Your turn";
        }
        var notice = _client.notice;
        if (body.length() == 0 && notice != null) {
            body = notice;
        }
        Draw.title(dc, "Computer");
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 29 / 100, Graphics.FONT_SMALL, headline, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        if (body.length() > 0) {
            Draw.paragraph(dc, body, 38, 72);
        }
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 77 / 100, Graphics.FONT_XTINY, "vol " + _speaker.volume() + "  " + _client.linkText(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        if (hint.length() > 0) {
            Draw.hint(dc, hint);
        }
    }

    private function elapsed() as String {
        var s = (System.getTimer() - _client.recordingSince) / 1000;
        return (s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60);
    }

    // The red ring that shows the microphone is open.
    private function ring(dc as Graphics.Dc, w as Number, h as Number) as Void {
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(6);
        dc.drawCircle(w / 2, h / 2, (w < h ? w : h) / 2 - 3);
        dc.setPenWidth(1);
    }
}

class ComputerDelegate extends WatchUi.BehaviorDelegate {
    private var _view as ComputerView;

    function initialize(view as ComputerView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.press();
        return true;
    }

    // A tap (a sleeve, sweat) is not a press: only the button sends or cuts.
    function onTap(evt as WatchUi.ClickEvent) as Boolean {
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

    // The Up hold: the one thing a call may need, a fresh start.
    function onMenu() as Boolean {
        var menu = new WatchUi.Menu2({:title => "Computer"});
        menu.addItem(new WatchUi.MenuItem("New call", null, :reconnect, null));
        _view.keepCallWhileMenu();
        WatchUi.pushView(menu, new ComputerMenuDelegate(_view), WatchUi.SLIDE_LEFT);
        return true;
    }

    function onBack() as Boolean {
        return _view.back();
    }
}

class ComputerMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as ComputerView;

    function initialize(view as ComputerView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        _view.reconnect();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
