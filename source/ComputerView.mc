import Toybox.Application.Storage;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// The Computer screen: opening it starts a call. The watch records each turn by itself, Start sends
// it, or cuts the answer and records again; Up and Down are the volume, Back hangs up and returns to
// the menu, as does the end of the call by the server. The screen shows what the call is doing as one
// word in a ring of the state's colour (CallScreen), and is drawn again only when that picture changes.
// Toybox.Audio exists on some products only; the menu offers this screen where it does (Home), and
// the checker skips the class so the other products build.
(:typecheck(false))
class ComputerView extends WatchUi.View {
    const START_VOLUME = 70;
    const VOLUME_STEP = 10;
    // where the volume is kept between openings
    const VOLUME_KEY = "volume";
    // the width of the ring that carries the state's colour
    const RING = 10;

    private var _client as CallClient;
    private var _speaker as Speaker;
    private var _recorder as Recorder;
    private var _volume as Number = START_VOLUME;
    // the screen has been left some way other than the end of the hang-up
    private var _left as Boolean = false;
    // the key of the face on screen
    private var _shown as String = "";
    // the watch has the screen on screen (onShow until onHide)
    private var _onScreen as Boolean = false;

    function initialize() {
        View.initialize();
        var t0 = System.getTimer();
        var saved = Storage.getValue(VOLUME_KEY);
        if (saved instanceof Number && saved >= 0 && saved <= 100) {
            _volume = saved;
        }
        _client = build();
        _recorder = new Recorder(_client);
        var t1 = System.getTimer();
        _client.start();
        var t2 = System.getTimer();
        _speaker = new Speaker(_client, _volume);
        var t3 = System.getTimer();
        Home.target = self;
        // how long each piece of the screen's start took: a stall of the watch shows here
        Trace.add("startup", {"setup_ms" => t1 - t0, "client_start_ms" => t2 - t1, "speaker_ms" => t3 - t2});
    }

    private function build() as CallClient {
        var io = new CallIo(method(:startCapture), method(:stopCapture), method(:play), method(:stopPlayback), method(:changed),
            method(:cue), method(:leave), method(:busy));
        return new CallClient(io, new CallEnv());
    }

    // On screen again: after a notification, a short hide or the menu above it the call goes on; a
    // call that ended meanwhile closes the screen now.
    function onShow() as Void {
        _onScreen = true;
        if (!_left) {
            Home.target = self;
        }
        Home.showing(self);
        if (!Home.covered) {
            _client.resumeMic();
        }
        Home.redraw();
    }

    // Back on screen after a short hide: a microphone the watch stopped meanwhile starts again.
    function shownAgain() as Void {
        _client.resumeMic();
    }

    // The watch hides the screen for a notification, the watch face and the menu opened on top
    // alike, and the call goes on through all of them. Only the screen closing (Back, the end of
    // the call, a reset after a long hide) ends it.
    function onHide() as Void {
        _onScreen = false;
        if (_left || Home.resetting) {
            _left = true;
            if (Home.target == self) {
                Home.target = null;
            }
            _client.hangUp();
        }
    }

    // The app has been hidden for Home.KEEP_MS: the call ends, after what is being said went as the turn.
    function hiddenTooLong() as Void {
        _client.endAfterTurn();
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
        _client.say("Volume " + _speaker.volume());
    }

    // Back: the bye buzz, the hang-up goes to the server, then the screen leaves for the menu; a second
    // Back leaves at once. In a session's call it asks for Computer instead.
    function back() as Boolean {
        if (_client.inSession() && !_client.closed() && !_client.ending()) {
            // in a session's call Back returns to Computer; the call goes on
            _client.back();
            return true;
        }
        if (_client.closed()) {
            _left = true;
            return false;
        }
        _client.bye();
        Home.redraw();
        return true;
    }

    // The hang-up is over: the menu shows again.
    // Only if the screen is still the one on top: a second Back or an alarm may have left it already.
    function leave() as Void {
        if (!_left) {
            _left = true;
            Home.close(self, _onScreen);
        }
    }

    // A signal. The turn signals are buzzes only: no sound plays while the microphone runs. The error
    // adds the system's error tone, since the microphone is off then.
    function cue(kind as Number) as Boolean {
        Trace.add("buzz", {"cue" => CallLogic.cueName(kind)});
        if (Home.covered) {
            // a hidden app may not vibrate or sound
            return true;
        }
        if (Attention has :vibrate) {
            var pattern = CallLogic.buzz(kind);
            var profile = [] as Array<Attention.VibeProfile>;
            for (var i = 0; i < pattern.size(); i++) {
                profile.add(new Attention.VibeProfile(pattern[i][0], pattern[i][1]));
            }
            Attention.vibrate(profile);
        }
        if (kind == CallLogic.CUE_ERROR && Attention has :playTone) {
            Attention.playTone(Attention.TONE_ERROR);
        }
        return true;
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

    // The client's state moved: the screen is drawn again when that changes what it shows.
    function changed() as Void {
        if (!CallScreen.face(_client).key().equals(_shown)) {
            Home.redraw();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var face = CallScreen.face(_client);
        _shown = face.key();
        Draw.background(dc);
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(face.color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(RING);
        dc.drawCircle(w / 2, h / 2, (w < h ? w : h) / 2 - RING / 2);
        dc.setPenWidth(1);
        // nothing near the top edge: the watch draws its own microphone sign there while it records
        dc.setColor(face.color, Graphics.COLOR_TRANSPARENT);
        var lower = face.body.length() > 0 ? face.body : face.who;
        var text = lower.length() > 0;
        Draw.fitted(dc, text ? 32 : 45, face.headline, [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]);
        if (text) {
            Draw.paragraph(dc, lower, 44, 76);
        }
        if (face.foot.length() > 0) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 79 / 100, Graphics.FONT_XTINY, face.foot, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        if (face.hint.length() > 0) {
            Draw.hint(dc, face.hint);
        }
    }
}

class ComputerDelegate extends WatchUi.BehaviorDelegate {
    private var _view as ComputerView;
    // the press being handled is the Start button's: a tap on the screen maps to the same select
    private var _startDown as Boolean = false;

    function initialize(view as ComputerView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onKeyPressed(evt as WatchUi.KeyEvent) as Boolean {
        _startDown = evt.getKey() == WatchUi.KEY_ENTER;
        return false;
    }

    function onSelect() as Boolean {
        if (_startDown) {
            _startDown = false;
            _view.press();
        }
        return true;
    }

    // A tap (a sleeve, sweat) is not a press: only the button sends or cuts. It is logged, to tell
    // whether taps keep an app opened from the glance list alive.
    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        _startDown = false;
        Trace.add("tap", {"uptime_ms" => System.getTimer() - Trace.bornAt});
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

    // The Up hold: a fresh start for the call.
    function onMenu() as Boolean {
        var menu = new WatchUi.Menu2({:title => "Computer"});
        menu.addItem(new WatchUi.MenuItem("New call", null, :reconnect, null));
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
